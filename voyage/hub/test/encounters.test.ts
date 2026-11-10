import assert from 'node:assert/strict';
import { generateKeyPairSync, type KeyObject } from 'node:crypto';
import { mkdtemp, readFile, rm, writeFile, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setImmediate } from 'node:timers/promises';
import { test } from 'node:test';
import type { Pool } from 'mysql2/promise';
import { MySQLRepository } from '../src/db/mysql.js';
import type { StayRow } from '../src/db/repository.js';
import { loadWhitelists } from '../src/encounters.js';
import { RETENTION_INTERVAL_MS, STAY_RETENTION_MS } from '../src/retention.js';
import { prepareImageContent } from '../scripts/prepare-image-content.js';
import { DEVICE, FIXED_NOW, fixture, headers, PRIVATE_KEY } from './helpers.js';

let serial = 0;
const uuid = () => `10000000-0000-4000-8000-${String(++serial).padStart(12, '0')}`;
const anotherKey = () => generateKeyPairSync('ed25519').privateKey;
const date = (time = FIXED_NOW) => new Date(time).toISOString();
const stay = (patch: Record<string, unknown> = {}) => ({
  stayId: uuid(), cityId: 'hangzhou', day: date().slice(0, 10), endsAt: date(FIXED_NOW + 3_600_000),
  appearance: { species: 'pigeon', stage: 'juvenile' }, ...patch,
});
function enabledFixture(options: Parameters<typeof fixture>[0] = {}) {
  const value = fixture({ ...options, env: { RATE_IP_CAPACITY: '1000', RATE_DEVICE_CAPACITY: '1000',
    STAY_RATE_IP_CAPACITY: '1000', STAY_RATE_DEVICE_CAPACITY: '1000', ...options.env } });
  value.repository.features.encountersEnabled = true;
  return value;
}
function call(app: ReturnType<typeof fixture>['app'], method: 'GET' | 'POST' | 'PUT' | 'DELETE', url: string,
  data?: unknown, key: KeyObject = PRIVATE_KEY, time = FIXED_NOW) {
  const body = data === undefined ? '' : JSON.stringify(data);
  return app.inject({ method, url, ...(body ? { payload: body } : {}),
    headers: headers(method, url, body, String(Math.floor(time / 1000)), key) });
}
function stored(patch: Partial<StayRow> = {}): StayRow {
  return { stayId: uuid(), publicKey: Buffer.alloc(32, ++serial), cityId: 'hangzhou', day: date().slice(0, 10),
    startedAt: new Date(FIXED_NOW - 60_000), endsAt: new Date(FIXED_NOW + 3_600_000),
    appearance: { species: 'snail', stage: 'teen' }, pairedStayId: null, partnerAppearance: null, pairedAt: null, ...patch };
}

test('all encounter endpoints require a signature; the disabled gate writes no stays or sync', async t => {
  const { app, repository } = fixture();
  t.after(() => app.close());
  for (const [method, url, data] of [
    ['POST', '/v1/stays', stay()], ['GET', `/v1/stays/${uuid()}`, undefined],
    ['PUT', '/v1/sync', { collection: [] }], ['DELETE', '/v1/me', undefined],
  ] as const) {
    assert.equal((await app.inject({ method, url, ...(data ? { payload: JSON.stringify(data) } : {}) })).statusCode, 401);
    const response = await call(app, method, url, data);
    assert.equal(response.statusCode, 200);
    assert.deepEqual(response.json(), method === 'DELETE' ? { ok: true }
      : method === 'PUT' ? { disabled: true } : { status: 'disabled' });
  }
  assert.equal(repository.stays.size, 0);
  assert.equal(repository.sync.size, 0);
});

test('stays validate UUID, real published city, species, actual form, local day and future six-hour end', async t => {
  const { app, repository } = enabledFixture();
  t.after(() => app.close());
  for (const patch of [
    { stayId: 'not-uuid' }, { cityId: 'souvenir.tea' }, { cityId: 'unknown' },
    { appearance: { species: 'unknown', stage: 'teen' } },
    { appearance: { species: 'pigeon', stage: 'traveler' } },
    { appearance: { species: 'pigeon', stage: 'teen', name: 'private' } },
    { day: '2023-11-12' }, { day: '2023-11-16' }, { day: '2023-02-30' },
    { day: '2023-11-14T00:00:00Z' }, { endsAt: date(FIXED_NOW) },
    { endsAt: date(FIXED_NOW + 6 * 3_600_000 + 1) }, { endsAt: 'tomorrow' }, { name: 'private' },
  ]) assert.equal((await call(app, 'POST', '/v1/stays', stay(patch))).statusCode, 400, JSON.stringify(patch));
  assert.equal(repository.stays.size, 0);
  for (const [index, stage] of ['hatchling', 'juvenile', 'teen'].entries()) {
    const body = stay({ appearance: { species: 'pigeon', stage }, endsAt: date(FIXED_NOW + 6 * 3_600_000),
      day: date(FIXED_NOW + (index - 1) * 86_400_000).slice(0, 10) });
    assert.equal((await call(app, 'POST', '/v1/stays', body)).statusCode, 200);
  }
});

test('stay POST is idempotent, including an expired retry; another device cannot reuse its ID', async t => {
  let now = FIXED_NOW;
  const { app, repository } = enabledFixture({ now: () => now });
  t.after(() => app.close());
  const body = stay();
  assert.deepEqual((await call(app, 'POST', '/v1/stays', body)).json(), { status: 'waiting' });
  const original = repository.stays.get(body.stayId)!;
  now += 4 * 3_600_000;
  assert.deepEqual((await call(app, 'POST', '/v1/stays', body, PRIVATE_KEY, now)).json(), { status: 'waiting' });
  assert.equal(repository.stays.size, 1);
  assert.equal(repository.stays.get(body.stayId)!.startedAt, original.startedAt);
  const conflict = await call(app, 'POST', '/v1/stays', body, anotherKey(), now);
  assert.equal(conflict.statusCode, 409);
  assert.deepEqual(conflict.json(), { error: 'stay_id_conflict' });
});

test('a second stay for one device and local day returns daily_limit without replacing the first', async t => {
  const { app, repository } = enabledFixture();
  t.after(() => app.close());
  const first = stay();
  await call(app, 'POST', '/v1/stays', first);
  const response = await call(app, 'POST', '/v1/stays', stay({ cityId: 'suzhou' }));
  assert.equal(response.statusCode, 409);
  assert.deepEqual(response.json(), { error: 'daily_limit' });
  assert.deepEqual([...repository.stays.keys()], [first.stayId]);
});

test('pairing picks the oldest waiting unexpired stay in this city from a different device', async t => {
  const { app, repository } = enabledFixture();
  t.after(() => app.close());
  const later = stored({ startedAt: new Date(FIXED_NOW - 10_000) });
  const oldest = stored({ startedAt: new Date(FIXED_NOW - 20_000) });
  const expired = stored({ startedAt: new Date(FIXED_NOW - 100_000), endsAt: new Date(FIXED_NOW) });
  const sameDevice = stored({ publicKey: Buffer.from(DEVICE, 'base64'), day: '2023-11-13',
    startedAt: new Date(FIXED_NOW - 200_000) });
  const otherCity = stored({ cityId: 'quanzhou', startedAt: new Date(FIXED_NOW - 300_000) });
  for (const row of [later, oldest, expired, sameDevice, otherCity]) repository.stays.set(row.stayId, row);
  const own = stay();
  const response = await call(app, 'POST', '/v1/stays', own);
  assert.deepEqual(response.json(), { status: 'paired', partner: { appearance: oldest.appearance }, pairedAt: date() });
  assert.equal(repository.stays.get(own.stayId)!.pairedStayId, oldest.stayId);
  assert.equal(repository.stays.get(oldest.stayId)!.pairedStayId, own.stayId);
  for (const row of [later, expired, sameDevice, otherCity]) assert.equal(row.pairedAt, null);
  const repeat = await call(app, 'POST', '/v1/stays', own);
  assert.deepEqual(repeat.json(), response.json());
  assert.equal(later.pairedAt, null, 're-POST cannot pair a second time');
  assert.deepEqual(Object.keys(response.json()).sort(), ['pairedAt', 'partner', 'status']);
  assert.deepEqual(Object.keys(response.json().partner), ['appearance']);
});

test('concurrent arrivals and same-ID retries never double-pair or split a pair', async t => {
  const { app, repository } = enabledFixture();
  t.after(() => app.close());
  const inputs = Array.from({ length: 30 }, () => ({ body: stay(), key: anotherKey() }));
  const responses = await Promise.all(inputs.flatMap(({ body, key }) => [
    call(app, 'POST', '/v1/stays', body, key), call(app, 'POST', '/v1/stays', body, key),
  ]));
  assert.ok(responses.every(response => response.statusCode === 200));
  assert.equal(repository.stays.size, 30);
  for (const row of repository.stays.values()) {
    assert.ok(row.pairedStayId);
    const partner = repository.stays.get(row.pairedStayId)!;
    assert.equal(partner.pairedStayId, row.stayId);
    assert.equal(partner.publicKey.equals(row.publicKey), false);
    assert.deepEqual(row.partnerAppearance, partner.appearance);
  }
  assert.equal(new Set([...repository.stays.values()].map(row => row.pairedStayId)).size, 30);
});

test('a racing second stay for the same device/day hits the unique daily limit', async t => {
  const { app, repository } = enabledFixture();
  t.after(() => app.close());
  const responses = await Promise.all(Array.from({ length: 5 }, () => call(app, 'POST', '/v1/stays', stay())));
  assert.equal(responses.filter(response => response.statusCode === 200).length, 1);
  assert.equal(responses.filter(response => response.json().error === 'daily_limit').length, 4);
  assert.equal(repository.stays.size, 1);
});

test('GET is owner-only and exposes the same paired snapshot, never partner identifiers', async t => {
  const { app } = enabledFixture();
  t.after(() => app.close());
  const body = stay();
  await call(app, 'POST', '/v1/stays', body);
  const key = anotherKey();
  const paired = await call(app, 'POST', '/v1/stays', stay({ appearance: { species: 'snail', stage: 'teen' } }), key);
  const own = await call(app, 'GET', `/v1/stays/${body.stayId}`);
  assert.equal(own.json().status, 'paired');
  assert.deepEqual(own.json().partner.appearance, { species: 'snail', stage: 'teen' });
  assert.equal(own.json().pairedAt, paired.json().pairedAt);
  assert.equal((await call(app, 'GET', `/v1/stays/${body.stayId}`, undefined, key)).statusCode, 404);
  assert.equal((await call(app, 'GET', `/v1/stays/${uuid()}`)).statusCode, 404);
  assert.equal((await call(app, 'GET', '/v1/stays/not-uuid')).statusCode, 400);
});

test('sync accepts published and approved IDs, replaces previous data, rejects unknown/draft IDs with 422', async t => {
  const { app, repository } = enabledFixture();
  t.after(() => app.close());
  repository.content = ['approved', 'draft', 'rejected'].map(status => ({ id: `hub.${status}`, cityId: 'hangzhou',
    kind: 'souvenir', content: {}, schemaVersion: 1, status: status as 'approved' | 'draft' | 'rejected', source: null, generatedAt: new Date() }));
  assert.deepEqual((await call(app, 'PUT', '/v1/sync', { collection: ['hangzhou', 'souvenir.tea', 'hub.approved'] })).json(), { ok: true });
  assert.deepEqual(repository.sync.get(DEVICE)!.collection, ['hangzhou', 'souvenir.tea', 'hub.approved']);
  for (const id of ['unknown', 'hub.draft', 'hub.rejected']) {
    const response = await call(app, 'PUT', '/v1/sync', { collection: [id] });
    assert.equal(response.statusCode, 422);
    assert.deepEqual(response.json(), { error: 'unknown_content_id' });
  }
  assert.deepEqual(repository.sync.get(DEVICE)!.collection, ['hangzhou', 'souvenir.tea', 'hub.approved']);
  await call(app, 'PUT', '/v1/sync', { collection: [] });
  assert.deepEqual(repository.sync.get(DEVICE)!.collection, []);
});

test('sync validates shape and the 10,000-ID cap; its larger body budget supports the full cap', async t => {
  const { app, repository } = enabledFixture();
  t.after(() => app.close());
  for (const body of [{ collection: 'hangzhou' }, { collection: [42] }, { collection: ['a/b'] },
    { collection: ['x'.repeat(129)] }, { collection: [], name: 'private' }, { collection: Array(10_001).fill('hangzhou') }]) {
    assert.equal((await call(app, 'PUT', '/v1/sync', body)).statusCode, 400);
  }
  const response = await call(app, 'PUT', '/v1/sync', { collection: Array(10_000).fill('hangzhou') });
  assert.equal(response.statusCode, 200);
  assert.deepEqual(repository.sync.get(DEVICE)!.collection, ['hangzhou']);
});

test('DELETE removes only this device, including while disabled, and the partner keeps its pairing', async t => {
  let now = FIXED_NOW;
  const { app, repository } = enabledFixture({ now: () => now });
  t.after(() => app.close());
  const body = stay();
  await call(app, 'POST', '/v1/stays', body);
  await call(app, 'PUT', '/v1/sync', { collection: ['hangzhou'] });
  const key = anotherKey();
  const partner = stay({ appearance: { species: 'letter', stage: 'hatchling' } });
  await call(app, 'POST', '/v1/stays', partner, key);
  await call(app, 'PUT', '/v1/sync', { collection: ['quanzhou'] }, key);
  repository.features.encountersEnabled = false;
  now += 60_001;
  const response = await call(app, 'DELETE', '/v1/me', undefined, PRIVATE_KEY, now);
  assert.deepEqual(response.json(), { ok: true });
  assert.equal(repository.stays.has(body.stayId), false);
  assert.equal(repository.devices.has(DEVICE), false);
  assert.equal(repository.sync.has(DEVICE), false);
  assert.equal(repository.devices.size, 1);
  assert.equal(repository.sync.size, 1);
  assert.equal(repository.stays.size, 1);
  assert.equal(repository.stays.get(partner.stayId)!.pairedStayId, body.stayId);
  assert.deepEqual(repository.stays.get(partner.stayId)!.partnerAppearance, body.appearance);
  repository.features.encountersEnabled = true;
  now += 60_001;
  const retained = await call(app, 'GET', `/v1/stays/${partner.stayId}`, undefined, key, now);
  assert.equal(retained.json().status, 'paired');
  assert.deepEqual(retained.json().partner.appearance, body.appearance);
  assert.deepEqual((await call(app, 'DELETE', '/v1/me', undefined, PRIVATE_KEY, now)).json(), { ok: true });
});

test('stays and sync share a stricter bucket independent from ordinary signed content', async t => {
  const { app } = enabledFixture({ env: { STAY_RATE_DEVICE_CAPACITY: '1' } });
  t.after(() => app.close());
  assert.equal((await call(app, 'POST', '/v1/stays', stay())).statusCode, 200);
  const limited = await call(app, 'PUT', '/v1/sync', { collection: [] });
  assert.equal(limited.statusCode, 429);
  assert.equal(limited.headers['retry-after'], '300');
  assert.equal((await call(app, 'GET', '/v1/cities/hangzhou/content?lang=en')).statusCode, 200);
  assert.equal((await call(app, 'DELETE', '/v1/me')).statusCode, 200, 'deletion is available after encounter bucket exhaustion');
});

test('the stay/sync IP bucket spans signed devices', async t => {
  const { app } = enabledFixture({ env: { STAY_RATE_IP_CAPACITY: '1' } });
  t.after(() => app.close());
  await call(app, 'POST', '/v1/stays', stay());
  assert.equal((await call(app, 'POST', '/v1/stays', stay(), anotherKey())).statusCode, 429);
});

test('retention runs on start and hourly, removes only stays ended more than seven days ago', async t => {
  t.mock.timers.enable({ apis: ['setInterval'] });
  let now = FIXED_NOW;
  const { app, repository } = enabledFixture({ now: () => now });
  t.after(() => app.close());
  const expired = stored({ endsAt: new Date(now - STAY_RETENTION_MS - 1) });
  const boundary = stored({ endsAt: new Date(now - STAY_RETENTION_MS) });
  const fresh = stored();
  for (const row of [expired, boundary, fresh]) repository.stays.set(row.stayId, row);
  await app.ready();
  assert.equal(repository.stays.has(expired.stayId), false);
  assert.equal(repository.stays.has(boundary.stayId), true);
  assert.equal(repository.stays.has(fresh.stayId), true);
  now += RETENTION_INTERVAL_MS;
  t.mock.timers.tick(RETENTION_INTERVAL_MS);
  await setImmediate();
  assert.equal(repository.stays.has(boundary.stayId), false);
  assert.equal(repository.stays.has(fresh.stayId), true);
});

test('retention failure does not prevent startup or future hourly cleanup', async t => {
  t.mock.timers.enable({ apis: ['setInterval'] });
  const { app, repository } = enabledFixture();
  t.after(() => app.close());
  let calls = 0;
  repository.deleteExpiredStays = async () => { if (++calls === 1) throw new Error('private DB detail'); };
  await app.ready();
  t.mock.timers.tick(RETENTION_INTERVAL_MS);
  await setImmediate();
  assert.equal(calls, 2);
});

test('image whitelist preparation derives published cities and pet IDs from the real pack', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'voyage-image-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const pack = new URL('../../Content/', import.meta.url).pathname;
  await prepareImageContent(pack, directory);
  const original = await loadWhitelists({ publishedIdsFile: join(pack, 'published-ids.txt'), citiesFile: join(pack, 'cities'), petsFile: join(pack, 'pets'), itemsFile: join(pack, 'items') });
  const baked = await loadWhitelists({ publishedIdsFile: join(directory, 'published-ids.txt'), citiesFile: join(directory, 'cities.txt'), petsFile: join(directory, 'pets.json') });
  assert.deepEqual(baked, original);
  assert.ok(baked.cities.has('hangzhou'));
  assert.ok(baked.pets.has('pigeon'));
  for (const id of (await readFile(join(pack, 'published-ids.txt'), 'utf8')).trim().split(/\r?\n/)) assert.ok(baked.publishedIds.has(id));
  const items = JSON.parse(await readFile(join(pack, 'items', 'hangzhou.json'), 'utf8'));
  assert.ok(baked.publishedIds.has(items[0].id));
  await mkdir(join(directory, 'cities'));
  await writeFile(join(directory, 'cities', 'not-published.json'), '{}');
  await writeFile(join(directory, 'cities', 'hangzhou.json'), '{}');
  const subset = await loadWhitelists({ publishedIdsFile: join(directory, 'published-ids.txt'), citiesFile: join(directory, 'cities'), petsFile: join(directory, 'pets.json') });
  assert.deepEqual([...subset.cities], ['hangzhou']);
});

for (const failUpdate of [false, true]) test(`MySQL pairing uses locked FIFO selection and atomic commit/rollback (failure=${failUpdate})`, async () => {
  const partner = stored();
  const own = stored({ startedAt: new Date(FIXED_NOW) });
  const calls: string[] = [];
  let updates = 0;
  const connection = {
    beginTransaction: async () => { calls.push('begin'); },
    commit: async () => { calls.push('commit'); },
    rollback: async () => { calls.push('rollback'); },
    release: () => { calls.push('release'); },
    execute: async (sql: string) => {
      calls.push(sql);
      if (sql.startsWith('UPDATE') && ++updates === 2 && failUpdate) throw new Error('simulated update failure');
      return [sql.includes('SKIP LOCKED') ? [{ stay_id: partner.stayId, public_key: partner.publicKey, city_id: partner.cityId,
        local_day: partner.day, started_at: partner.startedAt, ends_at: partner.endsAt, appearance: partner.appearance,
        paired_stay_id: null, partner_appearance: null, paired_at: null }] : []];
    },
  };
  const repository = new MySQLRepository({ getConnection: async () => connection } as unknown as Pool);
  if (failUpdate) await assert.rejects(repository.registerStay(own), /simulated update failure/);
  else {
    const result = await repository.registerStay(own);
    assert.equal(result.kind, 'ok');
    assert.ok(result.kind === 'ok' && result.stay.pairedStayId === partner.stayId);
  }
  assert.ok(calls.some(sql => /ORDER BY started_at, stay_id LIMIT 1 FOR UPDATE SKIP LOCKED/.test(sql)));
  assert.ok(calls.some(sql => /ends_at > \? AND public_key <> \?/.test(sql)));
  assert.equal(updates, 2);
  assert.deepEqual(calls.slice(-2), [failUpdate ? 'rollback' : 'commit', 'release']);
});
