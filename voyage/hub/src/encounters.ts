import { readFile, readdir, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { z } from 'zod';
import type { HubConfig } from './config.js';
import type { StayRow } from './db/repository.js';

const id = z.string().min(1).max(128).regex(/^[A-Za-z0-9._-]+$/);
export const stayIdSchema = z.uuid().transform(value => value.toLowerCase());
export const stayRequestSchema = z.strictObject({
  stayId: stayIdSchema,
  cityId: id.max(96),
  day: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  endsAt: z.iso.datetime({ offset: true }),
  appearance: z.strictObject({ species: id, stage: z.enum(['hatchling', 'juvenile', 'teen']) }),
});
export const syncRequestSchema = z.strictObject({ collection: z.array(id).max(10_000) });

export interface EncounterWhitelists {
  publishedIds: Set<string>;
  cities: Set<string>;
  pets: Set<string>;
}

export async function loadWhitelists(config: Pick<HubConfig, 'publishedIdsFile' | 'citiesFile' | 'petsFile'> & { itemsFile?: string }): Promise<EncounterWhitelists> {
  const [published, cityIds, petIds, itemIds] = await Promise.all([
    readIdLines(config.publishedIdsFile), readIds(config.citiesFile, false), readIds(config.petsFile, true),
    config.itemsFile ? readItemIds(config.itemsFile) : Promise.resolve([]),
  ]);
  return { publishedIds: new Set([...published, ...itemIds]), cities: new Set(cityIds.filter(city => published.includes(city))), pets: new Set(petIds) };
}

async function readItemIds(path: string): Promise<string[]> {
  if (!(await stat(path)).isDirectory()) return readIdLines(path);
  const files = (await readdir(path)).filter(file => file.endsWith('.json')).sort();
  const items = await Promise.all(files.map(async file => z.array(z.object({ id })).parse(JSON.parse(await readFile(join(path, file), 'utf8')))));
  return items.flat().map(item => item.id);
}

async function readIdLines(file: string): Promise<string[]> {
  return z.array(id).parse((await readFile(file, 'utf8')).split(/\r?\n/).map(value => value.trim()).filter(Boolean));
}

async function readIds(path: string, pets: boolean): Promise<string[]> {
  if (!(await stat(path)).isDirectory()) {
    return pets ? z.array(id).parse(JSON.parse(await readFile(path, 'utf8'))) : readIdLines(path);
  }
  const files = (await readdir(path)).filter(file => file.endsWith('.json')).sort();
  if (!pets) return z.array(id).parse(files.map(file => file.slice(0, -5)));
  return Promise.all(files.map(async file => id.parse(JSON.parse(await readFile(join(path, file), 'utf8')).id)));
}

export function validStay(input: z.infer<typeof stayRequestSchema>, whitelists: EncounterWhitelists, now: number): boolean {
  const day = Date.parse(input.day + 'T00:00:00Z');
  const today = Date.parse(new Date(now).toISOString().slice(0, 10) + 'T00:00:00Z');
  const end = Date.parse(input.endsAt);
  return Number.isFinite(day) && new Date(day).toISOString().slice(0, 10) === input.day
    && Math.abs(day - today) <= 86_400_000 && end > now && end <= now + 6 * 3_600_000
    && whitelists.cities.has(input.cityId) && whitelists.pets.has(input.appearance.species);
}

export function stayResponse(row: StayRow) {
  return row.pairedAt ? {
    status: 'paired' as const, partner: { appearance: row.partnerAppearance! }, pairedAt: row.pairedAt.toISOString(),
  } : { status: 'waiting' as const };
}
