import { basename, resolve } from 'node:path';
import { parseArgs } from 'node:util';
import { z } from 'zod';
import { loadEnvironment, readDbConfig } from '../src/config.js';
import { SCHEMA_VERSION } from '../src/content.js';
import { cityContentUpsert, createDatabase, MySQLRepository } from '../src/db/mysql.js';
import type { CityContentRow, Repository } from '../src/db/repository.js';
import {
  draftFiles, draftItemSchema, draftStorySchema, generationManifestSchema, isMain, packDirectory, readJSON,
} from './drafts.js';
import { validateDrafts, type ValidatorRunner } from './validate.js';

interface PublishingRepository { repository: Pick<Repository, 'putCityContent'>; close(): Promise<void> }

export async function publishContent(options: { drafts: string; dryRun?: boolean; pack?: string }, dependencies: {
  validate?: ValidatorRunner; openRepository?: () => Promise<PublishingRepository>; log?: (line: string) => void;
} = {}): Promise<number> {
  // Validate before constructing a database pool or writing even one row.
  await (dependencies.validate ?? validateDrafts)(options.pack ?? packDirectory, options.drafts);
  const manifest = generationManifestSchema.parse(await readJSON(resolve(options.drafts, 'generation.json')));
  const rows: CityContentRow[] = [];
  for (const directory of ['stories', 'items'] as const) {
    for (const file of await draftFiles(options.drafts, directory)) {
      const cityId = basename(file, '.json');
      const origin = manifest.cities[cityId];
      if (!origin) throw new Error('missing_generation_source');
      const raw = await readJSON(resolve(options.drafts, directory, file));
      const entries = directory === 'stories' ? z.array(draftStorySchema).parse(raw) : z.array(draftItemSchema).parse(raw);
      for (const content of entries) {
        if (content.cityId !== cityId) throw new Error('draft_city_mismatch');
        rows.push({ id: content.id, cityId, kind: directory === 'stories' ? 'play' : 'souvenir', content,
          schemaVersion: SCHEMA_VERSION, status: 'approved', generatedAt: new Date(origin.generatedAt),
          source: JSON.stringify({ ...origin, draftFile: `${directory}/${file}` }),
        });
      }
    }
  }
  if (!rows.length) throw new Error('no_draft_entries');
  if (options.dryRun) {
    for (const row of rows) (dependencies.log ?? console.info)(JSON.stringify(cityContentUpsert(row)));
    return rows.length;
  }
  const connection = await (dependencies.openRepository ?? (async () => {
    const pool = createDatabase(readDbConfig());
    return { repository: new MySQLRepository(pool), close: () => pool.end() };
  }))();
  try {
    for (const row of rows) await connection.repository.putCityContent(row);
  } finally { await connection.close(); }
  return rows.length;
}

async function main(): Promise<void> {
  const { values } = parseArgs({ options: { drafts: { type: 'string' }, 'dry-run': { type: 'boolean' } } });
  if (!values.drafts) throw new Error('usage: publish.ts --drafts <dir> [--dry-run]');
  loadEnvironment();
  const count = await publishContent({ drafts: resolve(values.drafts), dryRun: values['dry-run'] });
  console.error(JSON.stringify({ event: values['dry-run'] ? 'publish_preview' : 'published', entries: count }));
}

if (isMain(import.meta.url)) main().catch(() => {
  console.error(JSON.stringify({ error: 'publish_failed' }));
  process.exitCode = 1;
});
