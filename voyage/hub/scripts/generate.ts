import { randomUUID } from 'node:crypto';
import { mkdir, readdir, readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { parseArgs } from 'node:util';
import OpenAI from 'openai';
import { zodResponseFormat } from 'openai/helpers/zod';
import { z } from 'zod';
import { loadEnvironment } from '../src/config.js';
import {
  generationSchema, isMain, packDirectory, readJSON, type DraftBatch, type GenerationManifest,
} from './drafts.js';
import { validateDrafts, type ValidatorRunner } from './validate.js';

const responseFormat = zodResponseFormat(generationSchema, 'city_content');

const bilingual = z.object({ 'zh-Hans': z.string(), en: z.string() });
const citySchema = z.object({
  id: z.string(), names: bilingual,
  facts: z.array(z.object({ id: z.string(), type: z.string(), names: bilingual, summary: bilingual, sources: z.array(z.string()) })),
});
// Explicit projections: prompts contain only authored public content, never arbitrary file fields or env.
const exampleStories = z.array(z.object({
  id: z.string(), kind: z.string(), cityId: z.string().nullable(), factIds: z.array(z.string()),
  lead: bilingual.nullable().optional(), text: bilingual,
  replies: z.array(z.object({ id: z.string(), habit: z.string(), text: bilingual })),
  rewards: z.object({ itemIds: z.array(z.string()), menuIds: z.array(z.string()) }),
}));
const exampleItems = z.array(z.object({
  id: z.string(), kind: z.string(), cityId: z.string().nullable(), rarity: z.string().nullable(),
  icon: z.string(), habit: z.string().nullable(), names: bilingual, descriptions: bilingual,
}));

export interface GenerationRequest { system: string; prompt: string }
export interface ContentModel {
  readonly name: string;
  generate(request: GenerationRequest): Promise<string>;
}

export class OpenAIContentModel implements ContentModel {
  private client: OpenAI;
  constructor(readonly name: string, apiKey: string, baseURL?: string) {
    this.client = new OpenAI({ apiKey, baseURL, maxRetries: 0, logLevel: 'off', timeout: 120_000 });
  }
  async generate(request: GenerationRequest): Promise<string> {
    const response = await this.client.chat.completions.create({
      model: this.name,
      response_format: responseFormat,
      messages: [{ role: 'system', content: request.system }, { role: 'user', content: request.prompt }],
    });
    return response.choices[0]?.message.content ?? '';
  }
}

async function existing(file: string): Promise<unknown> {
  try { return await readJSON(file); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return [];
    throw error;
  }
}

function checkBatch(batch: DraftBatch, city: z.infer<typeof citySchema>, count: number, prefix: string,
  tags: string[], items: z.infer<typeof exampleItems>): void {
  const ids = [...batch.stories.flatMap(story => [story.id, ...story.replies.map(reply => reply.id)]), ...batch.items.map(item => item.id)];
  const facts = new Set(city.facts.map(fact => fact.id));
  const souvenirs = new Set([...items.filter(item => item.kind === 'souvenir').map(item => item.id), ...batch.items.map(item => item.id)]);
  if (batch.stories.length !== count || batch.items.length !== count || new Set(ids).size !== ids.length
    || ids.some(id => !id.startsWith(prefix))
    || batch.items.some(item => item.cityId !== city.id || !items.some(example => example.icon === item.icon))
    || batch.stories.some(story => story.cityId !== city.id
      || story.factIds.some(id => !facts.has(id)) || story.tags.some(tag => !tags.includes(tag))
      || new Set(story.replies.map(reply => reply.habit)).size !== 2
      || story.rewards.itemIds.some(id => !souvenirs.has(id)))) {
    throw new Error('invalid_city_content');
  }
}

function review(cityId: string, batch: DraftBatch): string {
  const lines = [`## ${cityId}`];
  for (const story of batch.stories) {
    lines.push(`### ${story.id} (${story.kind})`, `Facts: ${story.factIds.join(', ')}`,
      `Rewards: ${story.rewards.itemIds.join(', ') || 'none'}`);
    for (const language of ['zh-Hans', 'en'] as const) {
      lines.push(`**${language}**`, story.lead[language], story.text[language],
        ...story.replies.map(reply => `- ${reply.id} (${reply.habit}): ${reply.text[language]}`));
    }
  }
  for (const item of batch.items) {
    lines.push(`### ${item.id} (${item.rarity}, ${item.icon})`);
    for (const language of ['zh-Hans', 'en'] as const) {
      lines.push(`**${language}: ${item.names[language]}**`, item.descriptions[language]);
    }
  }
  return lines.join('\n\n');
}

export async function generateContent(options: {
  cities: string[]; out: string; count?: number; dryRun?: boolean; noValidate?: boolean; pack?: string;
}, dependencies: {
  model: ContentModel; validate?: ValidatorRunner; now?: () => Date; log?: (line: string) => void;
}): Promise<{ generated: string[]; skipped: string[] }> {
  const count = options.count ?? 2;
  if (!Number.isSafeInteger(count) || count < 1 || options.cities.length === 0
    || options.cities.some(city => !/^[a-z][a-z0-9-]*$/.test(city))) throw new Error('invalid_generation_arguments');
  const pack = options.pack ?? packDirectory;
  await mkdir(options.out, { recursive: true });
  if ((await readdir(options.out)).length) throw new Error('output_directory_must_be_empty');
  const system = await readFile(new URL('./content-prompt.txt', import.meta.url), 'utf8');
  const tags = z.array(z.string()).parse(await readJSON(resolve(pack, 'tags.json')));
  const result = { generated: [] as string[], skipped: [] as string[] };
  const manifest: GenerationManifest = { version: 1, cities: {} };
  const reviews = ['# Human review', 'Check both languages against city facts, originality, rewards and replies. Edit the draft JSON if needed, then validate again before explicitly publishing.'];
  const log = dependencies.log ?? console.info;
  for (const cityId of new Set(options.cities)) {
    const city = citySchema.parse(await readJSON(resolve(pack, 'cities', `${cityId}.json`)));
    const stories = exampleStories.parse(await existing(resolve(pack, 'stories', `${cityId}.json`)));
    const items = exampleItems.parse(await existing(resolve(pack, 'items', `${cityId}.json`)));
    if (city.id !== cityId || city.facts.length === 0 || items.length === 0) {
      result.skipped.push(cityId);
      log(JSON.stringify({ city: cityId, event: 'skipped', reason: 'insufficient_verified_content' }));
      continue;
    }
    const prefix = `hub.${cityId}.${randomUUID()}.`;
    const request = { system, prompt: JSON.stringify({ city, existingStories: stories, existingItems: items,
      allowedTags: tags, count, idPrefix: prefix }) };
    if (options.dryRun) {
      await mkdir(resolve(options.out, 'prompts'), { recursive: true });
      await writeFile(resolve(options.out, 'prompts', `${cityId}.json`), JSON.stringify({
        ...request, responseSchema: responseFormat.json_schema.schema,
      }, null, 2) + '\n');
      log(JSON.stringify({ city: cityId, event: 'prompt_written' }));
      continue;
    }
    let batch: DraftBatch | undefined;
    let reason = 'invalid_json_or_shape';
    for (let attempt = 0; attempt < 2; attempt++) {
      let raw: string;
      try { raw = await dependencies.model.generate(request); }
      catch { reason = 'model_failed'; break; } // Transport errors are not JSON retries.
      try {
        const parsed = generationSchema.parse(JSON.parse(raw));
        checkBatch(parsed, city, count, prefix, tags, items);
        batch = parsed;
        break;
      } catch { /* One retry for invalid JSON, shape or city references; never echo model output. */ }
    }
    if (!batch) {
      result.skipped.push(cityId);
      log(JSON.stringify({ city: cityId, event: 'skipped', reason }));
      continue;
    }
    for (const kind of ['stories', 'items'] as const) {
      await mkdir(resolve(options.out, kind), { recursive: true });
      await writeFile(resolve(options.out, kind, `${cityId}.json`), JSON.stringify(batch[kind], null, 2) + '\n');
    }
    manifest.cities[cityId] = { model: dependencies.model.name, generatedAt: (dependencies.now ?? (() => new Date()))().toISOString() };
    reviews.push(review(cityId, batch));
    result.generated.push(cityId);
  }
  if (!options.dryRun) {
    await writeFile(resolve(options.out, 'generation.json'), JSON.stringify(manifest, null, 2) + '\n');
    await writeFile(resolve(options.out, 'review.md'), reviews.join('\n\n') + '\n');
    if (!options.noValidate) await (dependencies.validate ?? validateDrafts)(pack, options.out);
  }
  return result;
}

async function main(): Promise<void> {
  const { values } = parseArgs({ options: {
    cities: { type: 'string' }, out: { type: 'string' }, count: { type: 'string' },
    'dry-run': { type: 'boolean' }, 'no-validate': { type: 'boolean' },
  } });
  if (!values.cities || !values.out) throw new Error('usage: generate.ts --cities a,b,c --out <dir> [--count N] [--dry-run] [--no-validate]');
  loadEnvironment();
  const name = process.env.OPENAI_MODEL;
  if (!name) throw new Error('OPENAI_MODEL_required');
  const apiKey = process.env.OPENAI_API_KEY;
  if (!values['dry-run'] && !apiKey) throw new Error('OPENAI_API_KEY_required');
  const model: ContentModel = values['dry-run']
    ? { name, generate: async () => { throw new Error('dry_run_model_call'); } }
    : new OpenAIContentModel(name, apiKey!, process.env.OPENAI_BASE_URL);
  const result = await generateContent({ cities: values.cities.split(',').map(city => city.trim()),
    out: resolve(values.out), count: values.count === undefined ? undefined : Number(values.count),
    dryRun: values['dry-run'], noValidate: values['no-validate'],
  }, { model });
  console.info(JSON.stringify(result));
  if (result.skipped.length) process.exitCode = 1;
}

if (isMain(import.meta.url)) main().catch(() => {
  console.error(JSON.stringify({ error: 'generation_failed', hint: 'Check arguments, model configuration and an empty output directory; no draft was published.' }));
  process.exitCode = 1;
});
