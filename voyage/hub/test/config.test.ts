import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { readConfig } from '../src/config.js';

const environment = {
  DB_HOST: 'unused.invalid', DB_DATABASE: 'unused', DB_USERNAME: 'unused', DB_PASSWORD: 'placeholder-password', OPENAI_MODEL: 'fake-model',
};

test('config defaults and invalid boundaries do not expose environment values', () => {
  const config = readConfig(environment);
  assert.equal(config.db.port, 3306);
  assert.equal(config.wishTimeoutMs, 2500);
  assert.equal(config.trustProxy, false);
  assert.deepEqual(readConfig({ ...environment, TRUST_PROXY: '127.0.0.1, 10.0.0.0/8' }).trustProxy, ['127.0.0.1', '10.0.0.0/8']);
  for (const patch of [{ PORT: '0' }, { WISH_TIMEOUT_MS: '3000' }, { RATE_IP_CAPACITY: '0' },
    { RATE_IP_REFILL_PER_SECOND: 'NaN' }, { TRUST_PROXY: '1' }, { DB_HOST: '' }]) {
    assert.throws(() => readConfig({ ...environment, ...patch }), error => {
      assert.equal(String(error).includes(environment.DB_PASSWORD), false);
      return true;
    });
  }
});

test('explicit HUB_ENV_FILE uses Node parsing for spaces and quotes; process env wins', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'voyage-env-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const file = join(directory, 'fake.env');
  await writeFile(file, 'VOYAGE_FAKE_ENV_QUOTED = "value with spaces"\nVOYAGE_FAKE_ENV_EXISTING = "file-value"\n');
  const source = `import {loadEnvironment} from ${JSON.stringify(new URL('../src/config.ts', import.meta.url).href)};
    loadEnvironment(); console.log(JSON.stringify([process.env.VOYAGE_FAKE_ENV_QUOTED, process.env.VOYAGE_FAKE_ENV_EXISTING]));`;
  const env: NodeJS.ProcessEnv = { ...process.env, HUB_ENV_FILE: file, VOYAGE_FAKE_ENV_EXISTING: 'process-value' };
  delete env.VOYAGE_FAKE_ENV_QUOTED;
  const output = execFileSync(process.execPath, ['--import', 'tsx', '--input-type=module', '-e', source], { env, encoding: 'utf8' });
  assert.deepEqual(JSON.parse(output), ['value with spaces', 'process-value']);
});
