import { readdir, readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadEnvironment, readDbConfig } from './config.js';
import { createDatabase } from './db/mysql.js';

export interface MigrationExecutor {
  execute(sql: string, values?: string[]): Promise<unknown>;
  appliedVersions(): Promise<string[]>;
}

export async function runMigrations(executor: MigrationExecutor, directory: string): Promise<string[]> {
  const files = (await readdir(directory)).filter(name => /^\d+_[a-z0-9_]+\.sql$/.test(name))
    .sort((a, b) => Number(a.split('_')[0]) - Number(b.split('_')[0]));
  if (new Set(files.map(name => Number(name.split('_')[0]))).size !== files.length) {
    throw new Error('duplicate_migration_number');
  }
  // Bootstrap from the first statement of the initial migration: one DDL source of truth.
  const initial = files[0];
  if (!initial || !/^0*1_/.test(initial)) throw new Error('missing_initial_migration');
  const firstStatement = (await readFile(resolve(directory, initial), 'utf8')).split(';')[0]!;
  if (!/^CREATE TABLE IF NOT EXISTS voyage_schema_migrations\s*\(/.test(firstStatement.trim())) {
    throw new Error('invalid_migration_bootstrap');
  }
  await executor.execute(firstStatement);
  const applied = new Set(await executor.appliedVersions());
  const completed: string[] = [];
  for (const file of files) {
    if (applied.has(file)) continue;
    // These checked-in migrations use plain statements, without procedures or semicolons in literals.
    const statements = (await readFile(resolve(directory, file), 'utf8')).split(';').map(sql => sql.trim()).filter(Boolean);
    for (const statement of statements) await executor.execute(statement);
    await executor.execute('INSERT INTO voyage_schema_migrations (version) VALUES (?)', [file]);
    completed.push(file);
  }
  return completed;
}

async function main(): Promise<void> {
  loadEnvironment();
  const pool = createDatabase(readDbConfig());
  try {
    const completed = await runMigrations({
      execute: (sql, values) => pool.execute(sql, values),
      appliedVersions: async () => {
        const [rows] = await pool.execute<import('mysql2').RowDataPacket[]>('SELECT version FROM voyage_schema_migrations');
        return rows.map(row => row.version as string);
      },
    }, resolve('migrations'));
    console.info(JSON.stringify({ event: 'migrations_applied', versions: completed }));
  } finally { await pool.end(); }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(() => {
    console.error(JSON.stringify({ error: 'migration_failed' }));
    process.exitCode = 1;
  });
}
