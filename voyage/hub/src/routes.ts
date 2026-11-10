import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { z } from 'zod';
import type { HubConfig } from './config.js';
import { readCityContent, SCHEMA_VERSION } from './content.js';
import { FeatureCache, type Repository } from './db/repository.js';
import { TokenBuckets } from './rateLimit.js';
import { DeviceRecorder, verifyRequest } from './signing.js';
import { languageSchema, WishResolver, wishRequestSchema, type WishModel } from './wish.js';

export interface RouteDependencies {
  config: HubConfig;
  repository: Repository;
  model: WishModel;
  tags: string[];
  now?: () => number;
}

export function registerRoutes(app: FastifyInstance, dependencies: RouteDependencies): void {
  const { config, repository, model, tags, now = Date.now } = dependencies;
  const features = new FeatureCache(repository, now);
  const devices = new DeviceRecorder(repository, now);
  const ip = new TokenBuckets(config.rate.ip, now);
  const device = new TokenBuckets(config.rate.device, now);
  const wishIp = new TokenBuckets(config.rate.wishIp, now);
  const wishDevice = new TokenBuckets(config.rate.wishDevice, now);
  const wishes = new WishResolver(repository, model, tags, config.wishTimeoutMs, now);

  function limit(reply: FastifyReply, delay: number): boolean {
    if (!delay) return false;
    reply.header('Retry-After', String(delay)).code(429).send({ error: 'rate_limited' });
    return true;
  }

  app.addHook('onRequest', async (request, reply) => {
    // Fastify does not parse GET bodies. Explicitly require empty bodies on these read routes.
    if (request.method === 'GET' && (request.headers['transfer-encoding'] || Number(request.headers['content-length'] ?? 0) > 0)) {
      return reply.code(400).send({ error: 'unexpected_body' });
    }
    // Health probes should report DB health, independently of API traffic.
    if (request.routeOptions.url === '/healthz') return;
    if (limit(reply, ip.take(request.ip))) return reply;
    if (request.routeOptions.url === '/v1/wishes/resolve' && limit(reply, wishIp.take(request.ip))) return reply;
  });

  async function signed(request: FastifyRequest, reply: FastifyReply) {
    const key = verifyRequest({
      method: request.method, pathWithQuery: request.raw.url!,
      body: Buffer.isBuffer(request.body) ? request.body : Buffer.alloc(0),
      device: request.headers['x-voyage-device'], timestamp: request.headers['x-voyage-timestamp'],
      signature: request.headers['x-voyage-signature'],
    }, Math.floor(now() / 1000));
    if (!key) return reply.code(401).send({ error: 'invalid_signature' });
    const id = key.toString('base64');
    if (limit(reply, device.take(id))) return reply;
    if (request.routeOptions.url === '/v1/wishes/resolve' && limit(reply, wishDevice.take(id))) return reply;
    await devices.record(key);
  }

  app.get('/healthz', async (_request, reply) => {
    try { await repository.ping(); return { ok: true }; }
    catch { return reply.code(503).send({ error: 'database_unavailable' }); }
  });

  app.get('/v1/config', async () => ({ schemaVersion: SCHEMA_VERSION, ...await features.get() }));

  app.get('/v1/cities/:cityId/content', { preValidation: signed }, async (request, reply) => {
    const params = z.object({ cityId: z.string().min(1).max(96).regex(/^[a-z0-9][a-z0-9-]*$/) }).safeParse(request.params);
    const query = z.object({ lang: languageSchema }).safeParse(request.query);
    if (!params.success || !query.success) return reply.code(400).send({ error: 'invalid_request' });
    const enabled = (await features.get()).cityContentEnabled;
    return {
      schemaVersion: SCHEMA_VERSION, cityId: params.data.cityId, language: query.data.lang, disabled: !enabled,
      items: enabled ? await readCityContent(repository, params.data.cityId) : [],
    };
  });

  app.post('/v1/wishes/resolve', { preValidation: signed }, async (request, reply) => {
    if (!/^application\/json(?:\s*;|$)/i.test(request.headers['content-type'] ?? '')) {
      return reply.code(415).send({ error: 'unsupported_media_type' });
    }
    let body: unknown;
    try { body = JSON.parse((request.body as Buffer).toString('utf8')); }
    catch { return reply.code(400).send({ error: 'invalid_json' }); }
    const parsed = wishRequestSchema.safeParse(body);
    if (!parsed.success) return reply.code(400).send({ error: 'invalid_request' });
    return wishes.resolve(parsed.data, features.get().then(value => value.wishResolveEnabled));
  });
}
