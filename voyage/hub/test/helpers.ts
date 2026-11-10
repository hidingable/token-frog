import { createPrivateKey, createPublicKey, sign } from 'node:crypto';
import { readConfig } from '../src/config.js';
import { MemoryRepository } from '../src/db/memory.js';
import { buildServer } from '../src/server.js';
import { canonicalRequest } from '../src/signing.js';
import type { WishModel } from '../src/wish.js';

// RFC 8032 test seed, public and private material is deliberately non-secret.
export const SEED = '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60';
export const PRIVATE_KEY = createPrivateKey({
  key: Buffer.from('302e020100300506032b657004220420' + SEED, 'hex'), format: 'der', type: 'pkcs8',
});
export const DEVICE = createPublicKey(PRIVATE_KEY).export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64');
export const FIXED_NOW = 1700000000_000;
export const VECTOR = {
  body: '{"text":"Sea","language":"en"}',
  hash: '895ab08e3bbe7108c3f5e0f19d347db7a735b79bae98e9f7dfda829a4ed95e2e',
  signature: 'ZcXYcypapsgkZLVgpkdFDahx+Ed6QLX7ocMNE8yRo5ajcda2/NKsFLEgcjnZmWn+50GhacL3FQWV3Yh9kCz+AQ==',
};

export function headers(method: string, url: string, body = '', timestamp = '1700000000', privateKey = PRIVATE_KEY) {
  const raw = createPublicKey(privateKey).export({ format: 'der', type: 'spki' }).subarray(-32);
  return {
    'x-voyage-device': raw.toString('base64'), 'x-voyage-timestamp': timestamp,
    'x-voyage-signature': sign(null, Buffer.from(canonicalRequest(method, url, timestamp, Buffer.from(body))), privateKey).toString('base64'),
    'content-type': 'application/json',
  };
}

export class FakeModel implements WishModel {
  name = 'fake-model';
  calls: { text: string; language: string; allowedTags: string[] }[] = [];
  output: unknown = { tags: ['coast'] };
  async pickTags(input: { text: string; language: string; allowedTags: string[] }, _signal: AbortSignal): Promise<unknown> {
    this.calls.push(input);
    return this.output;
  }
}

export function fixture(options: {
  env?: NodeJS.ProcessEnv; repository?: MemoryRepository; model?: WishModel; now?: () => number;
  logger?: Parameters<typeof buildServer>[1];
} = {}) {
  const repository = options.repository ?? new MemoryRepository();
  const model = options.model ?? new FakeModel();
  const config = readConfig({
    DB_HOST: 'unused.invalid', DB_DATABASE: 'unused', DB_USERNAME: 'unused', DB_PASSWORD: 'unused',
    OPENAI_MODEL: 'fake-model', ...options.env,
  });
  const app = buildServer({ config, repository, model, tags: ['coast', 'capital', 'food'], now: options.now ?? (() => FIXED_NOW) }, options.logger);
  return { app, repository, model, config };
}

export function wish(app: ReturnType<typeof buildServer>, data: unknown, signedBody?: string) {
  const body = JSON.stringify(data);
  return app.inject({ method: 'POST', url: '/v1/wishes/resolve', payload: body,
    headers: headers('POST', '/v1/wishes/resolve', signedBody ?? body) });
}
