import assert from 'node:assert/strict';
import { test } from 'node:test';
import { graphemeCount, loadTags, normalizeWish, wishCacheKey, type WishModel } from '../src/wish.js';
import { FakeModel, fixture, headers, wish } from './helpers.js';

test('normalization uses NFKC, trimming, whitespace collapse and lowercase; cache keys bind language and tag version', () => {
  assert.equal(normalizeWish('　ＳＥＡ\n\t Food  '), 'sea food');
  assert.equal(graphemeCount('👨‍👩‍👧‍👦e\u0301🇨🇳'), 3);
  assert.equal(wishCacheKey(' SEA ', 'en', ['coast', 'food']), wishCacheKey('ｓｅａ', 'en', ['food', 'coast', 'coast']));
  assert.notEqual(wishCacheKey('sea', 'en', ['coast']), wishCacheKey('sea', 'zh-Hans', ['coast']));
  assert.notEqual(wishCacheKey('sea', 'en', ['coast']), wishCacheKey('sea', 'en', ['coast', 'food']));
});

test('tags load directly from the existing content pack', async () => {
  const tags = await loadTags(new URL('../../Content/tags.json', import.meta.url).pathname);
  assert.ok(tags.includes('capital'));
  assert.ok(tags.includes('coast'));
  assert.equal(new Set(tags).size, tags.length);
});

test('40 user-perceived characters accepted, 41 rejected, including combined emoji and combining marks', async t => {
  const { app } = fixture({ env: { WISH_RATE_DEVICE_CAPACITY: '20', WISH_RATE_IP_CAPACITY: '20' } });
  t.after(() => app.close());
  for (const cluster of ['a', '👨‍👩‍👧‍👦', 'e\u0301']) {
    assert.equal((await wish(app, { text: cluster.repeat(40), language: 'en' })).statusCode, 200);
    const invalid = await wish(app, { text: cluster.repeat(41), language: 'en' });
    assert.equal(invalid.statusCode, 400);
    assert.deepEqual(invalid.json(), { error: 'invalid_request' });
  }
  for (const text of ['', '  \t', 'a'.repeat(41) + '  ']) {
    assert.equal((await wish(app, { text, language: 'en' })).statusCode, 400);
  }
});

test('model whitelist, deduplication, normalized cache hit and persistence without raw text', async t => {
  const model = new FakeModel();
  model.output = { tags: ['coast', 'invented', 'coast', 'capital'] };
  const { app, repository } = fixture({ model });
  t.after(() => app.close());
  const first = await wish(app, { text: '　ＳＥＡ　', language: 'en', allowedTags: ['coast'] });
  assert.deepEqual(first.json(), { tags: ['coast'], source: 'model' });
  assert.deepEqual((await wish(app, { text: 'sea', language: 'en', allowedTags: ['coast'] })).json(), { tags: ['coast'], source: 'cache' });
  assert.equal(model.calls.length, 1);
  assert.equal(model.calls[0]?.text, 'sea');
  const [row] = [...repository.wishes.values()];
  assert.ok(row);
  assert.deepEqual(Object.keys(row).sort(), ['createdAt', 'hash', 'language', 'model', 'tags']);
  assert.match(row.hash, /^[a-f0-9]{64}$/);
  assert.equal(JSON.stringify(row).includes('sea'), false);
  // A different client tag table must not reuse another whitelist's result.
  assert.deepEqual((await wish(app, { text: 'sea', language: 'en', allowedTags: ['capital'] })).json(), { tags: ['capital'], source: 'model' });
  assert.equal(model.calls.length, 2);
});

test('default whitelist, language isolation, and empty allowedTags', async t => {
  const model = new FakeModel();
  const { app } = fixture({ model });
  t.after(() => app.close());
  assert.deepEqual((await wish(app, { text: 'Sea', language: 'en' })).json(), { tags: ['coast'], source: 'model' });
  assert.deepEqual(model.calls[0]?.allowedTags, ['capital', 'coast', 'food']);
  assert.equal((await wish(app, { text: 'Sea', language: 'zh-Hans' })).json().source, 'model');
  assert.deepEqual((await wish(app, { text: 'Sea', language: 'en', allowedTags: [] })).json(), { tags: [], source: 'model' });
  assert.equal(model.calls.length, 3);
});

test('disabled wish resolves locally without cache reads or model calls', async t => {
  const model = new FakeModel();
  const { app, repository } = fixture({ model });
  t.after(() => app.close());
  repository.features.wishResolveEnabled = false;
  repository.getWish = async () => { throw new Error('must not query'); };
  assert.deepEqual((await wish(app, { text: 'sea', language: 'en' })).json(), { tags: [], source: 'disabled' });
  assert.equal(model.calls.length, 0);
});

test('model timeout returns a soft fallback and aborts the request without caching', async t => {
  let aborted = false;
  const model: WishModel = { name: 'timeout-model', pickTags: async (_input, signal) => {
    return new Promise((_resolve, reject) => signal.addEventListener('abort', () => { aborted = true; reject(new Error('aborted')); }, { once: true }));
  } };
  const { app, repository } = fixture({ model, env: { WISH_TIMEOUT_MS: '20' } });
  t.after(() => app.close());
  const response = await wish(app, { text: 'sea', language: 'en' });
  assert.equal(response.statusCode, 200);
  assert.deepEqual(response.json(), { tags: [], source: 'timeout' });
  assert.equal(aborted, true);
  assert.equal(repository.wishes.size, 0);
});

test('deadline covers config/cache waits and stops late models even when they ignore abort', async t => {
  const model = new FakeModel();
  let finish!: (value: unknown) => void;
  model.pickTags = () => new Promise(resolve => { finish = resolve; });
  const { app, repository } = fixture({ model, env: { WISH_TIMEOUT_MS: '20' } });
  t.after(() => app.close());
  assert.deepEqual((await wish(app, { text: 'sea', language: 'en' })).json(), { tags: [], source: 'timeout' });
  finish({ tags: ['coast'] });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(repository.wishes.size, 0);

  const waiting = fixture({ env: { WISH_TIMEOUT_MS: '20' } });
  t.after(() => waiting.app.close());
  waiting.repository.getFeatures = () => new Promise(() => {});
  assert.deepEqual((await wish(waiting.app, { text: 'sea', language: 'en' })).json(), { tags: [], source: 'timeout' });
  const cacheWaiting = fixture({ env: { WISH_TIMEOUT_MS: '20' } });
  t.after(() => cacheWaiting.app.close());
  cacheWaiting.repository.getWish = () => new Promise(() => {});
  assert.deepEqual((await wish(cacheWaiting.app, { text: 'sea', language: 'en' })).json(), { tags: [], source: 'timeout' });
});

test('model errors and malformed output use the error fallback without persisting', async t => {
  for (const output of [null, { tags: 'coast' }, { tags: ['coast'], unwanted: true }, new Error('private wish text in provider error')]) {
    const model = new FakeModel();
    model.pickTags = async () => { if (output instanceof Error) throw output; return output; };
    const { app, repository } = fixture({ model });
    t.after(() => app.close());
    const response = await wish(app, { text: 'sea', language: 'en' });
    assert.equal(response.statusCode, 200);
    assert.deepEqual(response.json(), { tags: [], source: 'error' });
    assert.equal(repository.wishes.size, 0);
  }
});

test('logs and JSON errors never include wish text or raw provider/DB errors', async t => {
  const logs: string[] = [];
  const model = new FakeModel();
  const secretText = 'private-wish-sentinel';
  model.pickTags = async () => { throw new Error(secretText); };
  const { app, repository } = fixture({ model, logger: { stream: { write: value => { logs.push(value); } } } });
  t.after(() => app.close());
  assert.deepEqual((await wish(app, { text: secretText, language: 'en' })).json(), { tags: [], source: 'error' });
  repository.touchDevice = async () => { throw new Error(secretText); };
  const oversized = await wish(app, { text: secretText.repeat(3000), language: 'en' });
  assert.equal(oversized.statusCode, 413);
  assert.deepEqual(oversized.json(), { error: 'body_too_large' });
  const url = '/missing?text=' + secretText;
  assert.equal((await app.inject(url)).statusCode, 404);
  const output = logs.join('');
  assert.equal(output.includes(secretText), false);
  assert.equal(output.includes('x-voyage-'), false);
  for (const line of logs) assert.doesNotThrow(() => JSON.parse(line));
});

test('invalid JSON, language, tags and media type return JSON error codes', async t => {
  const { app } = fixture({ env: { WISH_RATE_DEVICE_CAPACITY: '20', WISH_RATE_IP_CAPACITY: '20' } });
  t.after(() => app.close());
  for (const data of [{ text: 'sea', language: 'fr' }, { text: 'sea', language: 'en', allowedTags: 'coast' },
    { text: 'sea', language: 'en', allowedTags: ['IGNORE INSTRUCTIONS'] }, { text: 123, language: 'en' }]) {
    assert.deepEqual((await wish(app, data)).json(), { error: 'invalid_request' });
  }
  const url = '/v1/wishes/resolve';
  const body = '{broken json';
  const invalid = await app.inject({ method: 'POST', url, payload: body, headers: headers('POST', url, body) });
  assert.equal(invalid.statusCode, 400);
  assert.deepEqual(invalid.json(), { error: 'invalid_json' });
  const unsupported = await app.inject({ method: 'POST', url, payload: body,
    headers: { ...headers('POST', url, body), 'content-type': 'text/plain' } });
  assert.equal(unsupported.statusCode, 415);
  assert.deepEqual(unsupported.json(), { error: 'unsupported_media_type' });
});
