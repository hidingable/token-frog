import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { runMigrations, type MigrationExecutor } from '../src/migrate.js';

class FakeExecutor implements MigrationExecutor {
  applied = new Set<string>();
  statements: { sql: string; values?: string[] }[] = [];
  failOn?: string;
  async appliedVersions(): Promise<string[]> { return [...this.applied]; }
  async execute(sql: string, values?: string[]): Promise<unknown> {
    if (this.failOn && sql.includes(this.failOn)) throw new Error('migration failed');
    assert.equal(sql.includes(';'), false, 'one statement per execution');
    this.statements.push({ sql, values });
    if (sql.startsWith('INSERT INTO voyage_schema_migrations')) this.applied.add(values![0]!);
    return undefined;
  }
}

test('real initial migration defines the five utf8mb4 tables and seeds the four switches', async () => {
  const sql = await readFile(new URL('../migrations/0001_init.sql', import.meta.url), 'utf8');
  const tables = [...sql.matchAll(/CREATE TABLE IF NOT EXISTS (voyage_\w+)/g)].map(match => match[1]);
  assert.deepEqual(tables, ['voyage_schema_migrations', 'voyage_config', 'voyage_devices', 'voyage_city_content', 'voyage_wish_cache']);
  assert.equal(sql.match(/ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci/g)?.length, 5);
  for (const [key, value] of [['city_content_enabled', 'true'], ['wish_resolve_enabled', 'true'],
    ['encounters_enabled', 'false'], ['sponsor_content_enabled', 'false']]) {
    assert.ok(sql.includes(`('${key}', '${value}')`));
  }
  const executor = new FakeExecutor();
  const directory = new URL('../migrations/', import.meta.url).pathname;
  assert.deepEqual(await runMigrations(executor, directory), ['0001_init.sql', '0002_encounters.sql']);
  const count = executor.statements.length;
  assert.deepEqual(await runMigrations(executor, directory), []);
  assert.equal(executor.statements.length, count + 1, 'only bootstrap repeats');
});

test('encounter migration adds utf8mb4 stays/sync, unique device/day and queue/retention indexes without cascading pairs', async () => {
  const sql = await readFile(new URL('../migrations/0002_encounters.sql', import.meta.url), 'utf8');
  assert.deepEqual([...sql.matchAll(/CREATE TABLE IF NOT EXISTS (voyage_\w+)/g)].map(match => match[1]), ['voyage_stays', 'voyage_sync']);
  assert.equal(sql.match(/ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci/g)?.length, 2);
  assert.match(sql, /UNIQUE KEY voyage_stays_device_day \(public_key, local_day\)/);
  assert.match(sql, /INDEX voyage_stays_city_end \(city_id, ends_at\)/);
  assert.match(sql, /partner_appearance JSON NULL/);
  assert.equal(/FOREIGN KEY|CASCADE/i.test(sql), false);
});

test('migration files run in numeric order, record only after success, and skip applied versions', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'voyage-migrations-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  await writeFile(join(directory, '0001_init.sql'), 'CREATE TABLE IF NOT EXISTS voyage_schema_migrations (version VARCHAR(128));\nSELECT 1;');
  await writeFile(join(directory, '10_later.sql'), 'SELECT 10;');
  await writeFile(join(directory, '2_next.sql'), 'SELECT 2;');
  await writeFile(join(directory, 'README.md'), 'not a migration');
  const executor = new FakeExecutor();
  executor.failOn = 'SELECT 2';
  await assert.rejects(runMigrations(executor, directory));
  assert.deepEqual([...executor.applied], ['0001_init.sql']);
  assert.equal(executor.statements.some(statement => statement.sql === 'SELECT 10'), false);
  executor.failOn = undefined;
  assert.deepEqual(await runMigrations(executor, directory), ['2_next.sql', '10_later.sql']);
  assert.deepEqual(executor.statements.filter(statement => statement.sql.startsWith('INSERT INTO voyage_schema_migrations'))
    .map(statement => statement.values), [['0001_init.sql'], ['2_next.sql'], ['10_later.sql']]);
  await writeFile(join(directory, '0002_duplicate.sql'), 'SELECT 200;');
  await assert.rejects(runMigrations(executor, directory), /duplicate_migration_number/);
});
