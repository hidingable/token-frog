import { createPool, type Pool, type RowDataPacket } from 'mysql2/promise';
import { z } from 'zod';
import type { readDbConfig } from '../config.js';
import {
  DEFAULT_FEATURES, FEATURE_KEYS, type CityContentRow, type Features, type Repository, type WishCacheRow,
} from './repository.js';

export function createDatabase(config: ReturnType<typeof readDbConfig>): Pool {
  return createPool({
    ...config, charset: 'utf8mb4', timezone: 'Z', connectionLimit: 5, connectTimeout: 2000,
    // Keep multipleStatements disabled. All runtime values are bound parameters.
  });
}

/** Shared by the publisher's SQL preview and the actual parameterized write. */
export function cityContentUpsert(row: CityContentRow) {
  const values = [row.cityId, row.kind, JSON.stringify(row.content), row.schemaVersion,
    row.status, row.source, row.generatedAt];
  return {
    sql: `INSERT INTO voyage_city_content
      (id, city_id, kind, content, schema_version, status, source, generated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON DUPLICATE KEY UPDATE city_id = ?, kind = ?, content = ?, schema_version = ?,
      status = ?, source = ?, generated_at = ?`,
    values: [row.id, ...values, ...values],
  };
}

export class MySQLRepository implements Repository {
  constructor(private pool: Pool) {}

  async ping(): Promise<void> {
    const connection = await this.pool.getConnection();
    try { await connection.ping(); } finally { connection.release(); }
  }

  async getFeatures(): Promise<Features> {
    const [rows] = await this.pool.execute<RowDataPacket[]>('SELECT config_key, config_value FROM voyage_config');
    const features = { ...DEFAULT_FEATURES };
    for (const [field, key] of Object.entries(FEATURE_KEYS)) {
      const row = rows.find(row => row.config_key === key);
      if (row) features[field as keyof Features] = z.boolean().parse(row.config_value);
    }
    return features;
  }

  async touchDevice(publicKey: Buffer, seenAt: Date): Promise<void> {
    await this.pool.execute(
      `INSERT INTO voyage_devices (public_key, first_seen_at, last_seen_at) VALUES (?, ?, ?)
       ON DUPLICATE KEY UPDATE last_seen_at = GREATEST(last_seen_at, ?)`,
      [publicKey, seenAt, seenAt, seenAt],
    );
  }

  async getApprovedCityContent(cityId: string): Promise<CityContentRow[]> {
    const [rows] = await this.pool.execute<RowDataPacket[]>(
      `SELECT id, city_id, kind, content, schema_version, status, source, generated_at
       FROM voyage_city_content WHERE city_id = ? AND status = ? ORDER BY id`,
      [cityId, 'approved'],
    );
    return rows.map(row => ({
      id: row.id, cityId: row.city_id, kind: row.kind, content: row.content,
      schemaVersion: row.schema_version, status: row.status, source: row.source, generatedAt: row.generated_at,
    }));
  }

  async putCityContent(row: CityContentRow): Promise<void> {
    const operation = cityContentUpsert(row);
    await this.pool.execute(operation.sql, operation.values);
  }

  async getWish(hash: string): Promise<WishCacheRow | null> {
    const [rows] = await this.pool.execute<RowDataPacket[]>(
      'SELECT wish_hash, language, tags, model, created_at FROM voyage_wish_cache WHERE wish_hash = ?', [hash],
    );
    const row = rows[0];
    if (!row) return null;
    return {
      hash: row.wish_hash, language: row.language, tags: z.array(z.string()).parse(row.tags),
      model: row.model, createdAt: row.created_at,
    };
  }

  async putWish(row: WishCacheRow): Promise<void> {
    await this.pool.execute(
      `INSERT INTO voyage_wish_cache (wish_hash, language, tags, model, created_at) VALUES (?, ?, ?, ?, ?)
       ON DUPLICATE KEY UPDATE tags = ?, model = ?, created_at = ?`,
      [row.hash, row.language, JSON.stringify(row.tags), row.model, row.createdAt,
        JSON.stringify(row.tags), row.model, row.createdAt],
    );
  }
}
