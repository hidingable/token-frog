import { createPool, type Pool, type RowDataPacket } from 'mysql2/promise';
import { z } from 'zod';
import type { readDbConfig } from '../config.js';
import {
  DEFAULT_FEATURES, FEATURE_KEYS, type CityContentRow, type Features, type Repository, type WishCacheRow,
  type StayRow, type StayRegistration, type SyncRow,
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

  async registerStay(row: StayRow): Promise<StayRegistration> {
    const connection = await this.pool.getConnection();
    try {
      await connection.beginTransaction();
      // A short registration lock also handles two arrivals at a previously empty city.
      // SKIP LOCKED alone would let both insert an unpaired row without seeing the other.
      await connection.execute("SELECT config_key FROM voyage_config WHERE config_key = 'encounters_enabled' FOR UPDATE");
      const [existing] = await connection.execute<RowDataPacket[]>(
        'SELECT * FROM voyage_stays WHERE stay_id = ? FOR UPDATE', [row.stayId],
      );
      if (existing[0]) {
        await connection.commit();
        const stay = stayFromSQL(existing[0]);
        return stay.publicKey.equals(row.publicKey) ? { kind: 'ok', stay } : { kind: 'stay_id_conflict' };
      }
      const [daily] = await connection.execute<RowDataPacket[]>(
        'SELECT stay_id FROM voyage_stays WHERE public_key = ? AND local_day = ? FOR UPDATE', [row.publicKey, row.day],
      );
      if (daily.length) { await connection.commit(); return { kind: 'daily_limit' }; }
      await connection.execute(
        `INSERT INTO voyage_stays
         (stay_id, public_key, city_id, local_day, started_at, ends_at, appearance)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
        [row.stayId, row.publicKey, row.cityId, row.day, row.startedAt, row.endsAt, JSON.stringify(row.appearance)],
      );
      const [waiting] = await connection.execute<RowDataPacket[]>(
        `SELECT * FROM voyage_stays
         WHERE city_id = ? AND paired_at IS NULL AND ends_at > ? AND public_key <> ?
         ORDER BY started_at, stay_id LIMIT 1 FOR UPDATE SKIP LOCKED`,
        [row.cityId, row.startedAt, row.publicKey],
      );
      const own = { ...row };
      if (waiting[0]) {
        const partner = stayFromSQL(waiting[0]);
        own.pairedStayId = partner.stayId;
        own.partnerAppearance = partner.appearance;
        own.pairedAt = row.startedAt;
        await connection.execute(
          'UPDATE voyage_stays SET paired_stay_id = ?, partner_appearance = ?, paired_at = ? WHERE stay_id = ?',
          [partner.stayId, JSON.stringify(partner.appearance), row.startedAt, row.stayId],
        );
        await connection.execute(
          'UPDATE voyage_stays SET paired_stay_id = ?, partner_appearance = ?, paired_at = ? WHERE stay_id = ?',
          [row.stayId, JSON.stringify(row.appearance), row.startedAt, partner.stayId],
        );
      }
      await connection.commit();
      return { kind: 'ok', stay: own };
    } catch (error) { await connection.rollback(); throw error; }
    finally { connection.release(); }
  }

  async getStay(stayId: string): Promise<StayRow | null> {
    const [rows] = await this.pool.execute<RowDataPacket[]>(
      'SELECT * FROM voyage_stays WHERE stay_id = ?', [stayId],
    );
    return rows[0] ? stayFromSQL(rows[0]) : null;
  }

  async getApprovedContentIds(ids: string[]): Promise<Set<string>> {
    if (ids.length === 0) return new Set();
    const [rows] = await this.pool.execute<RowDataPacket[]>(
      `SELECT id FROM voyage_city_content WHERE status = 'approved' AND id IN (${ids.map(() => '?').join(',')})`, ids,
    );
    return new Set(rows.map(row => row.id as string));
  }

  async putSync(row: SyncRow): Promise<void> {
    await this.pool.execute(
      `INSERT INTO voyage_sync (public_key, collection, synced_at) VALUES (?, ?, ?)
       ON DUPLICATE KEY UPDATE collection = ?, synced_at = ?`,
      [row.publicKey, JSON.stringify(row.collection), row.syncedAt, JSON.stringify(row.collection), row.syncedAt],
    );
  }

  async deleteDevice(publicKey: Buffer): Promise<void> {
    const connection = await this.pool.getConnection();
    try {
      await connection.beginTransaction();
      await connection.execute("SELECT config_key FROM voyage_config WHERE config_key = 'encounters_enabled' FOR UPDATE");
      await connection.execute('DELETE FROM voyage_stays WHERE public_key = ?', [publicKey]);
      await connection.execute('DELETE FROM voyage_sync WHERE public_key = ?', [publicKey]);
      await connection.execute('DELETE FROM voyage_devices WHERE public_key = ?', [publicKey]);
      await connection.commit();
    } catch (error) { await connection.rollback(); throw error; }
    finally { connection.release(); }
  }

  async deleteExpiredStays(endedBefore: Date): Promise<void> {
    await this.pool.execute('DELETE FROM voyage_stays WHERE ends_at < ?', [endedBefore]);
  }
}

function stayFromSQL(row: RowDataPacket): StayRow {
  return {
    stayId: row.stay_id, publicKey: row.public_key, cityId: row.city_id,
    day: typeof row.local_day === 'string' ? row.local_day : row.local_day.toISOString().slice(0, 10),
    startedAt: row.started_at, endsAt: row.ends_at, appearance: row.appearance,
    pairedStayId: row.paired_stay_id, partnerAppearance: row.partner_appearance, pairedAt: row.paired_at,
  };
}
