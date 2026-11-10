import { spawn } from 'node:child_process';
import { resolve } from 'node:path';
import { parseArgs } from 'node:util';
import { isMain, packDirectory, voyageDirectory } from './drafts.js';

export type ValidatorRunner = (pack: string, drafts: string) => Promise<void>;

export const validateDrafts: ValidatorRunner = (pack, drafts) => new Promise((done, reject) => {
  const child = spawn('swift', ['run', 'voyage-content', 'validate', '--pack', resolve(pack), '--drafts', resolve(drafts)], {
    cwd: voyageDirectory, stdio: 'inherit',
  });
  child.once('error', reject);
  child.once('exit', code => code === 0 ? done() : reject(new Error('content_validation_failed')));
});

async function main(): Promise<void> {
  const { values } = parseArgs({ options: { pack: { type: 'string' }, drafts: { type: 'string' } } });
  if (!values.drafts) throw new Error('usage: validate.ts --drafts <dir> [--pack <Content dir>]');
  await validateDrafts(values.pack ?? packDirectory, values.drafts);
}

if (isMain(import.meta.url)) main().catch(error => {
  console.error(error.message);
  process.exitCode = 1;
});
