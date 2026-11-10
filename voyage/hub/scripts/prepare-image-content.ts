import { copyFile, mkdir, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadWhitelists } from '../src/encounters.js';

/** Offline build-context preparation; source-of-truth lists are always derived from the pack. */
export async function prepareImageContent(pack: string, output: string): Promise<void> {
  const content = await loadWhitelists({
    publishedIdsFile: resolve(pack, 'published-ids.txt'), citiesFile: resolve(pack, 'cities'), petsFile: resolve(pack, 'pets'),
    itemsFile: resolve(pack, 'items'),
  });
  await mkdir(output, { recursive: true });
  await copyFile(resolve(pack, 'tags.json'), resolve(output, 'tags.json'));
  await writeFile(resolve(output, 'published-ids.txt'), [...content.publishedIds].sort().join('\n') + '\n');
  await writeFile(resolve(output, 'cities.txt'), [...content.cities].sort().join('\n') + '\n');
  await writeFile(resolve(output, 'pets.json'), JSON.stringify([...content.pets].sort()) + '\n');
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await prepareImageContent(resolve(process.argv[2] ?? '../Content'), resolve(process.argv[3] ?? '.'));
}
