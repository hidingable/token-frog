import type { Repository } from './db/repository.js';

export const RETENTION_INTERVAL_MS = 3_600_000;
export const STAY_RETENTION_MS = 7 * 24 * RETENTION_INTERVAL_MS;

export function cleanExpiredStays(repository: Repository, now = Date.now()): Promise<void> {
  return repository.deleteExpiredStays(new Date(now - STAY_RETENTION_MS));
}
