import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { z } from 'zod';
import { loadKeepsakeForms, pickKeepsakeForms, pickSceneAngles } from '../scripts/generate.js';

const forms = Object.freeze(['drawing', 'note', 'bead', 'leaf', 'postcard']);

test('keepsake form picks are deterministic and do not mutate the list', () => {
  // SHA-256(hangzhou:keepsake) starts with 3e68e3dc: 1047061468 % 5 = 3.
  const expected = ['leaf', 'postcard', 'drawing'];
  assert.deepEqual(pickKeepsakeForms('hangzhou', 3, forms), expected);
  pickKeepsakeForms('kyoto', 3, forms);
  assert.deepEqual(pickKeepsakeForms('hangzhou', 3, forms), expected);
  const picked = pickKeepsakeForms('hangzhou', 3, forms);
  picked[0] = 'changed';
  assert.deepEqual(pickKeepsakeForms('hangzhou', 3, forms), expected);
});

test('keepsake form picks stay distinct through a full list and reject invalid counts', () => {
  for (let count = 1; count <= forms.length; count++) {
    const picked = pickKeepsakeForms('hangzhou', count, forms);
    assert.equal(picked.length, count);
    assert.equal(new Set(picked).size, count);
  }
  for (const count of [0, -1, 1.5, NaN, Infinity, forms.length + 1]) {
    assert.throws(() => pickKeepsakeForms('hangzhou', count, forms), /invalid_keepsake_form_count/);
  }
  assert.throws(() => pickKeepsakeForms('hangzhou', 1, []), /invalid_keepsake_form_count/);
});

test('consecutive keepsake form picks wrap around the end of the list', () => {
  assert.deepEqual(pickKeepsakeForms('hangzhou', forms.length, forms), ['leaf', 'postcard', 'drawing', 'note', 'bead']);
});

test('keepsake form rotation uses an unsigned big-endian hash prefix', () => {
  // SHA-256(paris:keepsake) starts with b70c9b7d: 3071056765 % 5 = 0.
  assert.deepEqual(pickKeepsakeForms('paris', 2, forms), ['drawing', 'note']);
});

test('keepsake forms use an independent hash seed from scene angles for the same city', () => {
  const cityId = 'hangzhou';
  const angleStart = createHash('sha256').update(cityId).digest().readUInt32BE(0) % forms.length;
  const formStart = createHash('sha256').update(`${cityId}:keepsake`).digest().readUInt32BE(0) % forms.length;
  assert.equal(angleStart, 2);
  assert.equal(formStart, 3);
  assert.notEqual(formStart, angleStart);
  assert.deepEqual(pickSceneAngles(cityId, 2, forms), [forms[angleStart], forms[(angleStart + 1) % forms.length]]);
  assert.deepEqual(pickKeepsakeForms(cityId, 2, forms), [forms[formStart], forms[(formStart + 1) % forms.length]]);
});

test('the bundled keepsake forms file loads as a nonempty unique list', async () => {
  const bundled = await loadKeepsakeForms();
  assert.ok(bundled.length > 0);
  assert.equal(new Set(bundled).size, bundled.length);
  assert.ok(bundled.every(form => typeof form === 'string' && form.trim().length > 0));
});

test('keepsake forms are trimmed before validation', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'voyage-keepsake-forms-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const file = join(directory, 'keepsake-forms.json');
  await writeFile(file, JSON.stringify([' drawing ', 'note']));
  assert.deepEqual(await loadKeepsakeForms(file), ['drawing', 'note']);
});

test('invalid keepsake forms files are rejected with zod validation', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'voyage-keepsake-forms-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const file = join(directory, 'keepsake-forms.json');
  for (const value of [[], ['drawing', 'drawing'], ['drawing', ' drawing '], [''], ['   '], ['drawing', 1], {}, null]) {
    await writeFile(file, JSON.stringify(value));
    await assert.rejects(loadKeepsakeForms(file), z.ZodError);
  }
  await writeFile(file, '{invalid-json');
  await assert.rejects(loadKeepsakeForms(file), SyntaxError);
});
