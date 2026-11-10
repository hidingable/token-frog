import { resolve } from 'node:path';
import { z } from 'zod';

const positiveNumber = z.coerce.number().positive().finite();
const capacity = positiveNumber.int();
const dbSchema = z.object({
  DB_HOST: z.string().min(1),
  DB_PORT: capacity.max(65535).default(3306),
  DB_DATABASE: z.string().min(1),
  DB_USERNAME: z.string().min(1),
  DB_PASSWORD: z.string(),
});

export function loadEnvironment(): void {
  if (process.env.HUB_ENV_FILE) process.loadEnvFile(process.env.HUB_ENV_FILE);
}

export function readDbConfig(env: NodeJS.ProcessEnv = process.env) {
  // Do not expose Zod diagnostics: invalid environment values can be credentials.
  const parsed = dbSchema.safeParse(env);
  if (!parsed.success) throw new Error('invalid_database_configuration');
  const value = parsed.data;
  return {
    host: value.DB_HOST, port: value.DB_PORT, database: value.DB_DATABASE,
    user: value.DB_USERNAME, password: value.DB_PASSWORD,
  };
}

const envSchema = z.object({
  OPENAI_API_KEY: z.string().optional(),
  OPENAI_MODEL: z.string().min(1),
  OPENAI_BASE_URL: z.url().optional(),
  PORT: capacity.max(65535).default(17322),
  HOST: z.string().min(1).default('127.0.0.1'),
  TRUST_PROXY: z.string().default('false'),
  HUB_TAGS_FILE: z.string().min(1).default('../Content/tags.json'),
  WISH_TIMEOUT_MS: capacity.max(2500).default(2500),
  RATE_IP_CAPACITY: capacity.default(120),
  RATE_IP_REFILL_PER_SECOND: positiveNumber.default(2),
  RATE_DEVICE_CAPACITY: capacity.default(60),
  RATE_DEVICE_REFILL_PER_SECOND: positiveNumber.default(1),
  WISH_RATE_IP_CAPACITY: capacity.default(10),
  WISH_RATE_IP_REFILL_PER_SECOND: positiveNumber.default(1 / 6),
  WISH_RATE_DEVICE_CAPACITY: capacity.default(5),
  WISH_RATE_DEVICE_REFILL_PER_SECOND: positiveNumber.default(1 / 12),
});

export interface BucketConfig { capacity: number; refillPerSecond: number }

export function readConfig(env: NodeJS.ProcessEnv = process.env) {
  const parsed = envSchema.safeParse(env);
  if (!parsed.success) throw new Error('invalid_hub_configuration');
  const v = parsed.data;
  const proxy = v.TRUST_PROXY.trim();
  if (/^\d+$/.test(proxy)) throw new Error('trust_proxy_requires_addresses');
  const trustProxy = proxy === 'false' ? false : proxy === 'true' ? true
    : proxy.split(',').map(value => value.trim()).filter(Boolean);
  if (Array.isArray(trustProxy) && trustProxy.length === 0) throw new Error('invalid_trust_proxy');
  return {
    db: readDbConfig(env), port: v.PORT, host: v.HOST, trustProxy,
    tagsFile: resolve(v.HUB_TAGS_FILE), wishTimeoutMs: v.WISH_TIMEOUT_MS,
    openai: { apiKey: v.OPENAI_API_KEY, model: v.OPENAI_MODEL, baseURL: v.OPENAI_BASE_URL },
    rate: {
      ip: { capacity: v.RATE_IP_CAPACITY, refillPerSecond: v.RATE_IP_REFILL_PER_SECOND },
      device: { capacity: v.RATE_DEVICE_CAPACITY, refillPerSecond: v.RATE_DEVICE_REFILL_PER_SECOND },
      wishIp: { capacity: v.WISH_RATE_IP_CAPACITY, refillPerSecond: v.WISH_RATE_IP_REFILL_PER_SECOND },
      wishDevice: { capacity: v.WISH_RATE_DEVICE_CAPACITY, refillPerSecond: v.WISH_RATE_DEVICE_REFILL_PER_SECOND },
    },
  };
}

export type HubConfig = ReturnType<typeof readConfig>;
