import assert from 'node:assert/strict';
import { cp, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { test, type TestContext } from 'node:test';
import { generationSchema, packDirectory, readJSON } from '../scripts/drafts.js';
import { generateContent, type ContentModel, type GenerationRequest } from '../scripts/generate.js';
import { publishContent } from '../scripts/publish.js';
import { readCityContent } from '../src/content.js';
import { MemoryRepository } from '../src/db/memory.js';

const fixedDate = new Date('2026-11-10T01:02:03.000Z');

function answer(request: GenerationRequest): string {
  const data = JSON.parse(request.prompt);
  return JSON.stringify({
    stories: Array.from({ length: data.count }, (_, n) => ({
      id: `${data.idPrefix}story-${n}`, version: 1, kind: n % 2 ? 'transit' : 'arrival', cityId: data.city.id,
      factIds: [data.city.facts[0].id], tags: [],
      requires: { habit: null, item: null, season: null, tool: null, rainySeason: null },
      fulfills: [], fulfillsHabit: null,
      lead: { 'zh-Hans': '今天画一张小地图。', en: 'A small map today.' },
      text: { 'zh-Hans': '我把纸折起来，留下一道弯线。', en: 'I folded the paper, leaving a winding line.' },
      replies: ['talkative', 'observant'].map(habit => ({ id: `${data.idPrefix}reply-${n}-${habit}`, habit,
        text: { 'zh-Hans': habit === 'talkative' ? '问问旁边的旅人' : '顺着线慢慢看', en: habit === 'talkative' ? 'Ask another traveler' : 'Follow the line' } })),
      rewards: { itemIds: [`${data.idPrefix}item-${n}`], menuIds: [] },
    })),
    items: Array.from({ length: data.count }, (_, n) => ({
      id: `${data.idPrefix}item-${n}`, kind: 'souvenir', cityId: data.city.id, rarity: 'common',
      icon: data.existingItems[0].icon, habit: null,
      names: { 'zh-Hans': '弯线小纸', en: 'Winding Paper' },
      descriptions: { 'zh-Hans': '纸上留了一道弯线。', en: 'A winding line remains on the paper.' },
    })),
  });
}

class FakeContentModel implements ContentModel {
  name = 'fake-content-model';
  calls: GenerationRequest[] = [];
  respond = answer;
  async generate(request: GenerationRequest): Promise<string> {
    this.calls.push(request);
    return this.respond(request);
  }
}

async function temporary(t: TestContext): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), 'voyage-content-pipeline-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  return directory;
}

test('generator writes exact bilingual pack arrays, source and review, then validates automatically', async t => {
  const out = await temporary(t);
  const model = new FakeContentModel();
  const validations: string[][] = [];
  const result = await generateContent({ cities: ['hangzhou'], out, count: 2 }, {
    model, now: () => fixedDate, validate: async (...args) => { validations.push(args); },
  });
  assert.deepEqual(result, { generated: ['hangzhou'], skipped: [] });
  assert.deepEqual(validations, [[packDirectory, out]]);
  const angles: string[] = JSON.parse(await readFile(new URL('../scripts/scene-angles.json', import.meta.url), 'utf8'));
  assert.deepEqual(JSON.parse(model.calls[0]!.prompt).sceneAngles, angles.slice(2, 4));
  const stories = await readJSON(join(out, 'stories/hangzhou.json'));
  const items = await readJSON(join(out, 'items/hangzhou.json'));
  const batch = generationSchema.parse({ stories, items });
  assert.equal(batch.stories.length, 2);
  assert.equal(batch.items.length, 2);
  assert.deepEqual(batch.stories[0]!.replies.map(reply => reply.habit), ['talkative', 'observant']);
  const manifest = await readJSON(join(out, 'generation.json'));
  assert.deepEqual(manifest, { version: 1, cities: { hangzhou: { model: model.name, generatedAt: fixedDate.toISOString() } } });
  const review = await readFile(join(out, 'review.md'), 'utf8');
  for (const entry of batch.stories) {
    for (const language of ['zh-Hans', 'en'] as const) {
      assert.ok(review.includes(entry.text[language]));
      for (const reply of entry.replies) assert.ok(review.includes(reply.text[language]));
    }
    assert.ok(review.includes(entry.id));
  }
  for (const item of batch.items) assert.ok(review.includes(item.names.en));
});

test('generator retries invalid JSON once, then accepts a clean response', async t => {
  const model = new FakeContentModel();
  model.respond = request => model.calls.length === 1 ? '{truncated' : answer(request);
  const out = await temporary(t);
  await generateContent({ cities: ['hangzhou'], out, noValidate: true }, { model });
  assert.equal(model.calls.length, 2);
  assert.equal((await readdir(join(out, 'stories'))).length, 1);
});

test('second invalid response skips the city, reports it, and continues to the next city', async t => {
  const model = new FakeContentModel();
  model.respond = request => JSON.parse(request.prompt).city.id === 'hangzhou' ? 'not json' : answer(request);
  const logs: string[] = [];
  const out = await temporary(t);
  const result = await generateContent({ cities: ['hangzhou', 'kyoto'], out, noValidate: true }, { model, log: line => logs.push(line) });
  assert.deepEqual(result, { generated: ['kyoto'], skipped: ['hangzhou'] });
  assert.equal(model.calls.length, 3);
  assert.deepEqual(await readdir(join(out, 'stories')), ['kyoto.json']);
  assert.equal(JSON.parse(logs[0]!).reason, 'invalid_json_or_shape');
});

test('invalid shape or foreign facts retry once; transport errors skip without retry', async t => {
  for (const failure of ['sponsor', 'foreign-fact', 'transport']) {
    const out = join(await temporary(t), failure);
    const model = new FakeContentModel();
    model.respond = request => {
      if (failure === 'transport') throw new Error('secret-provider-message');
      const batch = JSON.parse(answer(request));
      if (failure === 'sponsor') batch.stories[0].sponsor = null;
      else batch.stories[0].factIds = ['not-a-city-fact'];
      return JSON.stringify(batch);
    };
    const logs: string[] = [];
    const result = await generateContent({ cities: ['hangzhou'], out, noValidate: true }, { model, log: line => logs.push(line) });
    assert.deepEqual(result.skipped, ['hangzhou']);
    assert.equal(model.calls.length, failure === 'transport' ? 1 : 2);
    assert.ok(!logs.join('').includes('secret-provider-message'));
  }
});

test('dry-run writes reviewable prompts and schema, never calls model or validator, excludes env and unrelated fields', async t => {
  const directory = await temporary(t);
  const pack = join(directory, 'Content');
  await cp(packDirectory, pack, { recursive: true });
  const cityFile = join(pack, 'cities/hangzhou.json');
  const city = JSON.parse(await readFile(cityFile, 'utf8'));
  city.usage = 'private-usage'; city.secret = 'private-city-secret';
  await writeFile(cityFile, JSON.stringify(city));
  const previous = process.env.OPENAI_API_KEY;
  process.env.OPENAI_API_KEY = 'private-api-key-sentinel';
  t.after(() => { if (previous === undefined) delete process.env.OPENAI_API_KEY; else process.env.OPENAI_API_KEY = previous; });
  const model = new FakeContentModel();
  const out = join(directory, 'prompts-only');
  await generateContent({ cities: ['hangzhou'], out, dryRun: true, pack }, {
    model, validate: async () => { assert.fail('dry run must not validate nonexistent drafts'); },
  });
  assert.equal(model.calls.length, 0);
  const raw = await readFile(join(out, 'prompts/hangzhou.json'), 'utf8');
  for (const secret of ['private-usage', 'private-city-secret', 'private-api-key-sentinel', directory]) assert.ok(!raw.includes(secret));
  const prompt = JSON.parse(raw);
  assert.ok(prompt.system.includes('verified facts'));
  assert.ok(prompt.responseSchema.properties.stories);
  const reference = JSON.parse(prompt.prompt);
  assert.equal(reference.city.facts[0].id, 'west-lake');
  assert.ok(reference.existingStories.length && reference.existingItems.length);
  const angles: string[] = JSON.parse(await readFile(new URL('../scripts/scene-angles.json', import.meta.url), 'utf8'));
  assert.deepEqual(reference.sceneAngles, angles.slice(2, 4));
  assert.equal(reference.sceneAngles.length, reference.count);
  const paragraphs: string[] = prompt.system.split('\n\n');
  const sceneParagraph = paragraphs.findIndex(paragraph => paragraph.startsWith('Let each scene grow out of'));
  assert.ok(sceneParagraph >= 0);
  assert.equal(paragraphs[sceneParagraph + 1], "The request's sceneAngles list gives one angle per story, in order. Build story N around sceneAngles[N], applied to that story's cited fact. Do not end a story by keeping a napkin, wrapper, receipt or food-stained paper. A photo taken by a passer-by may appear only when the angle involves a stranger.");
  assert.ok(prompt.system.includes('A story need not end with keeping anything.'));
  assert.ok(!prompt.system.includes('Vary the kind of keepsake;'));
  assert.deepEqual(await readdir(out), ['prompts']);
});

test('generator propagates final validation failures and refuses to overwrite any prior output', async t => {
  const out = await temporary(t);
  await assert.rejects(generateContent({ cities: ['hangzhou'], out }, {
    model: new FakeContentModel(), validate: async () => { throw new Error('invalid_overlay'); },
  }), /invalid_overlay/);
  await assert.rejects(generateContent({ cities: ['hangzhou'], out, noValidate: true }, {
    model: new FakeContentModel(),
  }), /output_directory_must_be_empty/);
});

test('publisher validates first, idempotently upserts approved stories and souvenirs, and preserves source and shape', async t => {
  const out = await temporary(t);
  const model = new FakeContentModel();
  await generateContent({ cities: ['hangzhou'], out, count: 1, noValidate: true }, { model, now: () => fixedDate });
  const repository = new MemoryRepository();
  const sequence: string[] = [];
  const dependencies = {
    validate: async () => { sequence.push('validate'); },
    openRepository: async () => {
      sequence.push('connect');
      return { repository, close: async () => { sequence.push('close'); } };
    },
  };
  assert.equal(await publishContent({ drafts: out }, dependencies), 2);
  assert.deepEqual(sequence, ['validate', 'connect', 'close']);
  assert.equal(await publishContent({ drafts: out }, dependencies), 2);
  assert.equal(repository.content.length, 2);
  assert.deepEqual(repository.content.map(row => row.kind), ['play', 'souvenir']);
  for (const row of repository.content) {
    assert.equal(row.status, 'approved');
    assert.equal(row.schemaVersion, 1);
    assert.equal(row.generatedAt.toISOString(), fixedDate.toISOString());
    const source = JSON.parse(row.source!);
    assert.equal(source.model, model.name);
    assert.equal(source.generatedAt, fixedDate.toISOString());
    assert.match(source.draftFile, /^(stories|items)\/hangzhou.json$/);
  }
  const served = await readCityContent(repository, 'hangzhou');
  assert.equal(served.length, 2, '5a can serve the newly published exact pack entries');
  const story = repository.content.find(row => row.kind === 'play')!;
  const edited = (await readJSON(join(out, 'stories/hangzhou.json'))) as { text: { en: string } }[];
  edited[0]!.text.en = 'A reviewed line.';
  await writeFile(join(out, 'stories/hangzhou.json'), JSON.stringify(edited));
  await publishContent({ drafts: out }, dependencies);
  assert.equal(repository.content.length, 2);
  assert.equal((repository.content.find(row => row.id === story.id)!.content as typeof edited[0]).text.en, 'A reviewed line.');
});

test('publisher refuses validation errors before connecting; dry-run prints bound SQL without connecting or changing bundled IDs', async t => {
  let connected = false;
  const openRepository = async () => {
    connected = true;
    return { repository: new MemoryRepository(), close: async () => {} };
  };
  await assert.rejects(publishContent({ drafts: '/nonexistent' }, {
    openRepository, validate: async () => { throw new Error('validation_failed'); },
  }), /validation_failed/);
  assert.equal(connected, false);
  const out = await temporary(t);
  await generateContent({ cities: ['hangzhou'], out, count: 1, noValidate: true }, { model: new FakeContentModel() });
  const idsFile = resolve(packDirectory, 'published-ids.txt');
  const before = await readFile(idsFile, 'utf8');
  const logs: string[] = [];
  await publishContent({ drafts: out, dryRun: true }, { openRepository, validate: async () => {}, log: line => logs.push(line) });
  assert.equal(connected, false);
  assert.equal(logs.length, 2);
  for (const line of logs) {
    const operation = JSON.parse(line);
    assert.match(operation.sql, /INSERT INTO voyage_city_content/);
    assert.match(operation.sql, /ON DUPLICATE KEY UPDATE/);
    assert.ok(operation.values.includes('approved'));
    assert.ok(!operation.sql.includes('CREATE TABLE'));
  }
  assert.equal(await readFile(idsFile, 'utf8'), before);
});
