import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import { DEFAULT_FEATURES, FeatureCache } from '../src/db/repository.js';
import { MemoryRepository } from '../src/db/memory.js';
import { FIXED_NOW, fixture, headers } from './helpers.js';

test('health returns 200 after DB ping and 503 on DB failure without error details', async t => {
  const { app, repository } = fixture();
  t.after(() => app.close());
  const response = await app.inject('/healthz');
  assert.equal(response.statusCode, 200);
  assert.deepEqual(response.json(), { ok: true });
  repository.ping = async () => { throw new Error('private database details'); };
  const failure = await app.inject('/healthz');
  assert.equal(failure.statusCode, 503);
  assert.deepEqual(failure.json(), { error: 'database_unavailable' });
});

test('unsigned feature config is cached for 60 s and shared with content routes', async t => {
  let time = FIXED_NOW;
  const { app, repository } = fixture({ now: () => time });
  t.after(() => app.close());
  let reads = 0;
  const original = repository.getFeatures.bind(repository);
  repository.getFeatures = async () => { reads++; return original(); };
  assert.deepEqual((await app.inject('/v1/config')).json(), { schemaVersion: 1, ...DEFAULT_FEATURES });
  repository.features.cityContentEnabled = false;
  time += 59_999;
  assert.equal((await app.inject('/v1/config')).json().cityContentEnabled, true);
  time++;
  assert.equal((await app.inject('/v1/config')).json().cityContentEnabled, false);
  const url = '/v1/cities/hangzhou/content?lang=en';
  const content = await app.inject({ url, headers: headers('GET', url, '', String(time / 1000)) });
  assert.deepEqual(content.json(), { schemaVersion: 1, cityId: 'hangzhou', language: 'en', disabled: true, items: [] });
  assert.equal(reads, 2);
});

test('feature cache coalesces reads and retries failures rather than caching them', async () => {
  const repository = new MemoryRepository();
  let reads = 0;
  repository.getFeatures = async () => {
    reads++;
    if (reads === 1) throw new Error('offline');
    return { ...DEFAULT_FEATURES };
  };
  const cache = new FeatureCache(repository);
  await assert.rejects(cache.get());
  assert.deepEqual(await Promise.all([cache.get(), cache.get()]), [DEFAULT_FEATURES, DEFAULT_FEATURES]);
  assert.equal(reads, 2);
});

test('city content returns native bilingual Story/Item shapes, approved only, for both languages', async t => {
  const { app, repository } = fixture();
  t.after(() => app.close());
  const stories = JSON.parse(await readFile(new URL('../../Content/stories/hangzhou.json', import.meta.url), 'utf8'));
  const items = JSON.parse(await readFile(new URL('../../Content/items/hangzhou.json', import.meta.url), 'utf8'));
  const play = stories[0];
  const question = stories[1];
  const souvenir = items.find((item: { kind: string }) => item.kind === 'souvenir');
  const row = { cityId: 'hangzhou', schemaVersion: 1, status: 'approved' as const, source: null, generatedAt: new Date() };
  repository.content = [
    { ...row, id: play.id, kind: 'play', content: { ...play, futureField: 'additive' } },
    { ...row, id: question.id, kind: 'question', content: question },
    { ...row, id: souvenir.id, kind: 'souvenir', content: souvenir },
    { ...row, id: 'draft', kind: 'play', content: play, status: 'draft' },
    { ...row, id: 'rejected', kind: 'play', content: play, status: 'rejected' },
    { ...row, id: 'unsupported', kind: 'play', content: play, schemaVersion: 2 },
    { ...row, id: 'malformed', kind: 'play', content: { text: 'not a Story' } },
    { ...row, id: 'wrong-id', kind: 'play', content: play },
    { ...row, cityId: 'kyoto', id: play.id, kind: 'play', content: play },
    { ...row, id: 'missing-translation', kind: 'souvenir', content: { ...souvenir, names: { en: 'only' } } },
  ];
  for (const lang of ['en', 'zh-Hans']) {
    const url = `/v1/cities/hangzhou/content?lang=${lang}`;
    const response = await app.inject({ url, headers: headers('GET', url) });
    assert.equal(response.statusCode, 200);
    const body = response.json();
    assert.equal(body.schemaVersion, 1);
    assert.equal(body.disabled, false);
    assert.equal(body.language, lang);
    assert.deepEqual(body.items, [{ ...play, futureField: 'additive' }, question, souvenir]);
  }
  const emptyUrl = '/v1/cities/unknown/content?lang=en';
  assert.deepEqual((await app.inject({ url: emptyUrl, headers: headers('GET', emptyUrl) })).json().items, []);
});

test('disabled content does not read content storage', async t => {
  const { app, repository } = fixture();
  t.after(() => app.close());
  repository.features.cityContentEnabled = false;
  repository.getApprovedCityContent = async () => { throw new Error('must not query'); };
  const url = '/v1/cities/hangzhou/content?lang=en';
  const response = await app.inject({ url, headers: headers('GET', url) });
  assert.equal(response.statusCode, 200);
  assert.equal(response.json().disabled, true);
  assert.deepEqual(response.json().items, []);
});

test('city content filters top-level sponsor keys while disabled and preserves entries while enabled', async t => {
  const stories = JSON.parse(await readFile(new URL('../../Content/stories/hangzhou.json', import.meta.url), 'utf8'));
  const items = JSON.parse(await readFile(new URL('../../Content/items/hangzhou.json', import.meta.url), 'utf8'));
  const sponsor = { id: 'paper-shop', label: { 'zh-Hans': '纸铺', en: 'Paper Shop' } };
  const ordinary = { ...stories[0], id: 'remote-a-ordinary', futureField: 'additive' };
  const story = { ...stories[0], id: 'remote-b-story', factIds: [], sponsor };
  const souvenir = { ...items.find((item: { kind: string }) => item.kind === 'souvenir'),
    id: 'remote-c-souvenir', rarity: 'common', sponsor };
  const nullSponsor = { ...stories[0], id: 'remote-d-null', sponsor: null };
  for (const enabled of [false, true]) await t.test(`sponsor_content_enabled=${enabled}`, async t => {
    const { app, repository } = fixture();
    t.after(() => app.close());
    repository.features.sponsorContentEnabled = enabled;
    const row = { cityId: 'hangzhou', schemaVersion: 1, status: 'approved' as const,
      source: null, generatedAt: new Date() };
    repository.content = [
      ...[ordinary, story, nullSponsor].map(content => ({ ...row, id: content.id, kind: 'play' as const, content })),
      { ...row, id: souvenir.id, kind: 'souvenir', content: souvenir },
    ];
    for (const lang of ['zh-Hans', 'en']) {
      const url = `/v1/cities/hangzhou/content?lang=${lang}`;
      const response = await app.inject({ url, headers: headers('GET', url) });
      assert.equal(response.statusCode, 200);
      assert.deepEqual(response.json().items, enabled ? [ordinary, story, souvenir, nullSponsor] : [ordinary]);
    }
    assert.equal(repository.content.length, 4, 'filtering never deletes stored partner entries');
  });
});

test('content query validation, raw-query signing and JSON error envelope', async t => {
  const { app } = fixture();
  t.after(() => app.close());
  for (const suffix of ['', '?lang=fr', '?lang=en&lang=zh-Hans']) {
    const url = '/v1/cities/hangzhou/content' + suffix;
    assert.equal((await app.inject({ url, headers: headers('GET', url) })).statusCode, 400);
  }
  const signedUrl = '/v1/cities/hangzhou/content?lang=en&x=%2f';
  const response = await app.inject({ url: signedUrl.replace('%2f', '%2F'), headers: headers('GET', signedUrl) });
  assert.equal(response.statusCode, 401);
  const getBody = await app.inject({ method: 'GET', url: signedUrl, payload: 'x', headers: headers('GET', signedUrl) });
  assert.equal(getBody.statusCode, 400);
  const missing = await app.inject('/missing');
  assert.equal(missing.statusCode, 404);
  assert.deepEqual(missing.json(), { error: 'not_found' });
});
