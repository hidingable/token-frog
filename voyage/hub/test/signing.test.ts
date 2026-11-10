import assert from 'node:assert/strict';
import { test } from 'node:test';
import { canonicalRequest, verifyRequest } from '../src/signing.js';
import { DEVICE, FIXED_NOW, VECTOR, fixture, headers, wish } from './helpers.js';

test('fixed Ed25519 request vector matches exact canonical string and expected signature', () => {
  assert.equal(DEVICE, '11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=');
  assert.equal(canonicalRequest('POST', '/v1/wishes/resolve', '1700000000', Buffer.from(VECTOR.body)),
    `POST\n/v1/wishes/resolve\n1700000000\n${VECTOR.hash}`);
  const signed = headers('POST', '/v1/wishes/resolve', VECTOR.body);
  assert.equal(signed['x-voyage-signature'], VECTOR.signature);
  assert.equal(verifyRequest({ method: 'POST', pathWithQuery: '/v1/wishes/resolve', body: Buffer.from(VECTOR.body),
    device: DEVICE, timestamp: '1700000000', signature: VECTOR.signature }, FIXED_NOW / 1000)?.toString('base64'), DEVICE);
});

test('signature verification binds body, path, raw query, method and timestamp, with ±300 s inclusive', () => {
  const input = { method: 'POST', pathWithQuery: '/v1/wishes/resolve', body: Buffer.from(VECTOR.body),
    device: DEVICE, timestamp: '1700000000', signature: VECTOR.signature };
  for (const delta of [-300, 300]) assert.ok(verifyRequest(input, FIXED_NOW / 1000 + delta));
  for (const delta of [-301, 301]) assert.equal(verifyRequest(input, FIXED_NOW / 1000 + delta), null);
  for (const patch of [
    { body: Buffer.from(VECTOR.body + ' ') }, { pathWithQuery: '/v1/wishes/resolve?a=1' }, { method: 'GET' },
    { signature: Buffer.alloc(64).toString('base64') }, { signature: VECTOR.signature + '\n' },
    { device: DEVICE.slice(0, -1) }, { timestamp: '01700000000' }, { device: [DEVICE, DEVICE] },
  ]) assert.equal(verifyRequest({ ...input, ...patch }, FIXED_NOW / 1000), null);
});

test('routes accept signed JSON bytes, reject wrong body, unsigned calls, bad signature and skew', async t => {
  const { app } = fixture();
  t.after(() => app.close());
  assert.equal((await wish(app, { text: 'Sea', language: 'en' })).statusCode, 200);
  assert.equal((await wish(app, { text: 'Sea', language: 'en' }, VECTOR.body + ' ')).statusCode, 401);
  const url = '/v1/cities/hangzhou/content?lang=zh-Hans';
  for (const bad of [undefined, { ...headers('GET', url), 'x-voyage-signature': Buffer.alloc(64).toString('base64') },
    headers('GET', url, '', '1699999699')]) {
    const response = await app.inject({ method: 'GET', url, headers: bad });
    assert.equal(response.statusCode, 401);
    assert.deepEqual(response.json(), { error: 'invalid_signature' });
  }
  assert.equal((await app.inject({ method: 'GET', url, headers: headers('GET', url) })).statusCode, 200);
});

test('device first/last seen writes are coalesced and throttled to five minutes', async t => {
  let time = FIXED_NOW;
  const { app, repository } = fixture({ now: () => time });
  t.after(() => app.close());
  let writes = 0;
  const original = repository.touchDevice.bind(repository);
  repository.touchDevice = async (...args) => { writes++; await original(...args); };
  const url = '/v1/cities/hangzhou/content?lang=en';
  const call = () => app.inject({ method: 'GET', url, headers: headers('GET', url, '', String(time / 1000)) });
  await Promise.all([call(), call(), call()]);
  assert.equal(writes, 1);
  time += 299_000;
  await call();
  assert.equal(writes, 1);
  time += 1_000;
  await call();
  assert.equal(writes, 2);
  assert.deepEqual(repository.devices.get(DEVICE), { firstSeen: new Date(FIXED_NOW), lastSeen: new Date(time) });
});
