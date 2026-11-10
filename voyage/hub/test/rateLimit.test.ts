import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import { test } from 'node:test';
import { TokenBuckets } from '../src/rateLimit.js';
import { FIXED_NOW, fixture, headers, wish } from './helpers.js';

test('token buckets refill exactly, are independent by key, and report Retry-After', () => {
  let now = 0;
  const buckets = new TokenBuckets({ capacity: 2, refillPerSecond: 0.5 }, () => now);
  assert.equal(buckets.take('a'), 0);
  assert.equal(buckets.take('a'), 0);
  assert.equal(buckets.take('a'), 2);
  assert.equal(buckets.take('b'), 0);
  now = 1000;
  assert.equal(buckets.take('a'), 1);
  now = 2000;
  assert.equal(buckets.take('a'), 0);
  now = 100_000;
  assert.equal(buckets.take('a'), 0);
});

test('unsigned config requests are IP limited, while health remains available', async t => {
  const { app } = fixture({ env: { RATE_IP_CAPACITY: '1', RATE_IP_REFILL_PER_SECOND: '0.5' } });
  t.after(() => app.close());
  assert.equal((await app.inject('/v1/config')).statusCode, 200);
  const response = await app.inject('/v1/config');
  assert.equal(response.statusCode, 429);
  assert.equal(response.headers['retry-after'], '2');
  assert.deepEqual(response.json(), { error: 'rate_limited' });
  assert.equal((await app.inject('/healthz')).statusCode, 200);
});

test('device limit spans source IPs, and wish device bucket is stricter than content', async t => {
  const { app } = fixture({ env: { RATE_DEVICE_CAPACITY: '2', WISH_RATE_DEVICE_CAPACITY: '1' } });
  t.after(() => app.close());
  assert.equal((await wish(app, { text: 'sea', language: 'en' })).statusCode, 200);
  assert.equal((await wish(app, { text: 'sea', language: 'en' })).statusCode, 429);
  const url = '/v1/cities/hangzhou/content?lang=en';
  assert.equal((await app.inject({ method: 'GET', url, remoteAddress: '10.0.0.2', headers: headers('GET', url) })).statusCode, 429);
});

test('wish IP bucket spans devices and leaves the general content bucket available', async t => {
  const { app } = fixture({ env: { WISH_RATE_IP_CAPACITY: '1' } });
  t.after(() => app.close());
  assert.equal((await wish(app, { text: 'sea', language: 'en' })).statusCode, 200);
  const body = JSON.stringify({ text: 'mountain', language: 'en' });
  const key = generateKeyPairSync('ed25519').privateKey;
  const response = await app.inject({ method: 'POST', url: '/v1/wishes/resolve', payload: body,
    headers: headers('POST', '/v1/wishes/resolve', body, String(FIXED_NOW / 1000), key) });
  assert.equal(response.statusCode, 429);
  const url = '/v1/cities/hangzhou/content?lang=en';
  assert.equal((await app.inject({ method: 'GET', url, headers: headers('GET', url) })).statusCode, 200);
});

for (const trust of ['false', '127.0.0.1']) test(`X-Forwarded-For obeys TRUST_PROXY=${trust}`, async t => {
  const { app } = fixture({ env: { TRUST_PROXY: trust, RATE_IP_CAPACITY: '1' } });
  t.after(() => app.close());
  const call = (ip: string, remoteAddress = '127.0.0.1') => app.inject({ method: 'GET', url: '/v1/config', remoteAddress,
    headers: { 'x-forwarded-for': ip } });
  assert.equal((await call('192.0.2.1')).statusCode, 200);
  assert.equal((await call('192.0.2.2')).statusCode, trust === 'false' ? 429 : 200);
  assert.equal((await call('192.0.2.3', '10.0.0.2')).statusCode, 200);
  assert.equal((await call('192.0.2.4', '10.0.0.2')).statusCode, 429);
});
