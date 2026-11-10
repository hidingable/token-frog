import { readdir, readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { z } from 'zod';

export const voyageDirectory = fileURLToPath(new URL('../../', import.meta.url));
export const packDirectory = resolve(voyageDirectory, 'Content');
const text = z.string().min(1);
const bilingual = z.strictObject({ 'zh-Hans': text, en: text });
const habit = z.enum(['talkative', 'observant']);
const id = text.max(128);

// Required nullable keys also work with the SDK's strict structured-output format.
export const draftStorySchema = z.strictObject({
  id, version: z.number().int().positive(), kind: z.enum(['arrival', 'transit']), cityId: text,
  factIds: z.array(text).min(1), tags: z.array(text),
  requires: z.strictObject({
    habit: habit.nullable(), item: z.null(), season: z.null(), tool: z.null(), rainySeason: z.null(),
  }),
  fulfills: z.array(text).max(0), fulfillsHabit: z.null(), lead: bilingual, text: bilingual,
  replies: z.array(z.strictObject({ id, habit, text: bilingual })).length(2),
  rewards: z.strictObject({ itemIds: z.array(text), menuIds: z.array(text).max(0) }),
});
export const draftItemSchema = z.strictObject({
  id, kind: z.literal('souvenir'), cityId: text, rarity: z.enum(['common', 'uncommon', 'rare']),
  icon: text, habit: z.null(), names: bilingual, descriptions: bilingual,
});
export const generationSchema = z.strictObject({
  stories: z.array(draftStorySchema).min(1), items: z.array(draftItemSchema).min(1),
});
export type DraftBatch = z.infer<typeof generationSchema>;
export const generationManifestSchema = z.strictObject({
  version: z.literal(1), cities: z.record(text, z.strictObject({ model: text, generatedAt: z.iso.datetime() })),
});
export type GenerationManifest = z.infer<typeof generationManifestSchema>;

export async function readJSON(file: string): Promise<unknown> {
  return JSON.parse(await readFile(file, 'utf8'));
}

export async function draftFiles(directory: string, kind: 'stories' | 'items'): Promise<string[]> {
  try { return (await readdir(resolve(directory, kind))).filter(file => file.endsWith('.json')).sort(); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return [];
    throw error;
  }
}

export function isMain(url: string): boolean {
  return !!process.argv[1] && resolve(process.argv[1]) === fileURLToPath(url);
}
