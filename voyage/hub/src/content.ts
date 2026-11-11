import { z } from 'zod';
import type { CityContentRow, Repository } from './db/repository.js';

export const SCHEMA_VERSION = 1;
const text = z.string().trim().min(1);
const bilingual = z.looseObject({ 'zh-Hans': text, en: text });
const optionalText = z.string().nullable().optional();
const storySchema = z.looseObject({
  id: text, version: z.number().int().positive(),
  kind: z.enum(['arrival', 'transit', 'fulfill', 'revisit', 'postcard', 'reunion']),
  cityId: text, factIds: z.array(z.string()), tags: z.array(z.string()),
  requires: z.looseObject({
    habit: optionalText, item: optionalText, season: optionalText, tool: optionalText,
    rainySeason: z.boolean().nullable().optional(),
  }),
  fulfills: z.array(z.string()), fulfillsHabit: optionalText,
  lead: bilingual.nullable().optional(), text: bilingual,
  replies: z.array(z.looseObject({ id: text, habit: z.enum(['talkative', 'observant']), text: bilingual })),
  rewards: z.looseObject({
    itemIds: z.array(z.string()), menuIds: z.array(z.string()), dropRarity: optionalText, duplicateClueCityId: optionalText,
  }),
  learned: bilingual.nullable().optional(), memoryLead: bilingual.nullable().optional(),
});
const souvenirSchema = z.looseObject({
  id: text, kind: z.literal('souvenir'), cityId: text,
  rarity: z.enum(['common', 'uncommon', 'rare']), icon: text,
  habit: z.null().optional(), names: bilingual, descriptions: bilingual, source: optionalText,
});

function readItem(row: CityContentRow, cityId: string, sponsorContentEnabled: boolean): unknown | null {
  if (row.schemaVersion !== SCHEMA_VERSION) return null;
  if (!sponsorContentEnabled && row.content !== null && typeof row.content === 'object'
    && Object.hasOwn(row.content, 'sponsor')) return null;
  const parsed = (row.kind === 'souvenir' ? souvenirSchema : storySchema).safeParse(row.content);
  if (!parsed.success || parsed.data.cityId !== cityId || parsed.data.id !== row.id) return null;
  // Preserve bilingual maps and additive fields, including native Story.kind and embedded replies.
  return row.content;
}

export async function readCityContent(repository: Repository, cityId: string, sponsorContentEnabled = false): Promise<unknown[]> {
  const rows = await repository.getApprovedCityContent(cityId);
  return rows.map(row => readItem(row, cityId, sponsorContentEnabled)).filter(item => item !== null);
}
