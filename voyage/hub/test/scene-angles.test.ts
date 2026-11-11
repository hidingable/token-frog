import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { z } from 'zod';
import { loadSceneAngles, pickSceneAngles } from '../scripts/generate.js';

const angles = Object.freeze(['sound', 'waiting', 'weather', 'mistake', 'stranger']);

test('scene angle picks are deterministic and do not mutate the list', () => {
  // SHA-256(hangzhou) starts with 7b41fcf2: 2067922162 % 5 = 2.
  const expected = ['weather', 'mistake', 'stranger'];
  assert.deepEqual(pickSceneAngles('hangzhou', 3, angles), expected);
  pickSceneAngles('kyoto', 3, angles);
  assert.deepEqual(pickSceneAngles('hangzhou', 3, angles), expected);
  const picked = pickSceneAngles('hangzhou', 3, angles);
  picked[0] = 'changed';
  assert.deepEqual(pickSceneAngles('hangzhou', 3, angles), expected);
});

test('picks stay distinct through a full list and reject counts that cannot be distinct', () => {
  for (let count = 1; count <= angles.length; count++) {
    const picked = pickSceneAngles('hangzhou', count, angles);
    assert.equal(picked.length, count);
    assert.equal(new Set(picked).size, count);
  }
  for (const count of [0, -1, 1.5, NaN, Infinity, angles.length + 1]) {
    assert.throws(() => pickSceneAngles('hangzhou', count, angles), /invalid_scene_angle_count/);
  }
  assert.throws(() => pickSceneAngles('hangzhou', 1, []), /invalid_scene_angle_count/);
});

test('consecutive angle picks wrap around the end of the list', () => {
  // SHA-256(paris) starts with 1670f2e4: 376500964 % 5 = 4.
  assert.deepEqual(pickSceneAngles('paris', 3, angles), ['stranger', 'sound', 'waiting']);
});

test('the hash prefix is an unsigned big-endian integer even with its high bit set', () => {
  // SHA-256(tokyo) starts with afe04579: 2950710649 % 5 = 4.
  assert.deepEqual(pickSceneAngles('tokyo', 2, angles), ['stranger', 'sound']);
});

test('fixed city IDs spread across different starting indices', () => {
  // SHA-256(kyoto) starts with 10561890: 274077840 % 5 = 0.
  const hangzhou = pickSceneAngles('hangzhou', 2, angles);
  const kyoto = pickSceneAngles('kyoto', 2, angles);
  assert.deepEqual(hangzhou, ['weather', 'mistake']);
  assert.deepEqual(kyoto, ['sound', 'waiting']);
  assert.notDeepEqual(hangzhou, kyoto);
});

test('the bundled scene angles file loads as a nonempty unique list', async () => {
  const bundled = await loadSceneAngles();
  assert.ok(bundled.length > 0);
  assert.equal(new Set(bundled).size, bundled.length);
  assert.ok(bundled.every(angle => typeof angle === 'string' && angle.trim().length > 0));
});

test('invalid scene angles files are rejected with zod validation', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'voyage-scene-angles-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const file = join(directory, 'scene-angles.json');
  for (const value of [[], ['sound', 'sound'], [''], ['   '], ['sound', 1], {}, null]) {
    await writeFile(file, JSON.stringify(value));
    await assert.rejects(loadSceneAngles(file), z.ZodError);
  }
  await writeFile(file, '{invalid-json');
  await assert.rejects(loadSceneAngles(file), SyntaxError);
});
