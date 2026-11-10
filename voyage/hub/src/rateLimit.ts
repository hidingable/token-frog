import type { BucketConfig } from './config.js';

export class TokenBuckets {
  private buckets = new Map<string, { tokens: number; at: number }>();
  private lastSweep = 0;
  constructor(private config: BucketConfig, private now = Date.now) {}

  /** Returns zero on acceptance, otherwise the Retry-After delay in whole seconds. */
  take(key: string): number {
    const now = this.now();
    const { capacity, refillPerSecond } = this.config;
    if (now - this.lastSweep >= 60_000) {
      const refillMs = capacity / refillPerSecond * 1000;
      for (const [id, bucket] of this.buckets) if (now - bucket.at >= refillMs) this.buckets.delete(id);
      this.lastSweep = now;
    }
    const bucket = this.buckets.get(key) ?? { tokens: capacity, at: now };
    bucket.tokens = Math.min(capacity, bucket.tokens + Math.max(0, now - bucket.at) / 1000 * refillPerSecond);
    bucket.at = now;
    this.buckets.set(key, bucket);
    if (bucket.tokens < 1) return Math.ceil((1 - bucket.tokens) / refillPerSecond);
    bucket.tokens -= 1;
    return 0;
  }
}
