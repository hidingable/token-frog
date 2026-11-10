import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import Fastify, { LogController, type FastifyServerOptions } from 'fastify';
import { loadEnvironment, readConfig } from './config.js';
import { createDatabase, MySQLRepository } from './db/mysql.js';
import { registerRoutes, type RouteDependencies } from './routes.js';
import { loadTags, OpenAIWishModel } from './wish.js';

export function buildServer(dependencies: RouteDependencies, logger: FastifyServerOptions['logger'] = false) {
  const app = Fastify({
    logger, logController: new LogController({ disableRequestLogging: true }),
    trustProxy: dependencies.config.trustProxy, bodyLimit: 32 * 1024,
  });
  // Preserve the exact bytes BEFORE JSON decoding: whitespace and key order are signed.
  app.removeAllContentTypeParsers();
  app.addContentTypeParser('*', { parseAs: 'buffer' }, (_request, body, done) => done(null, body));
  app.setErrorHandler((error, request, reply) => {
    const statusCode = error && typeof error === 'object' && 'statusCode' in error ? error.statusCode : undefined;
    const status = typeof statusCode === 'number' && statusCode >= 400 && statusCode < 500 ? statusCode : 503;
    const code = status === 413 ? 'body_too_large' : status < 500 ? 'invalid_request' : 'service_unavailable';
    request.log.warn({ statusCode: status, code }, 'request_error');
    reply.code(status).send({ error: code });
  });
  app.setNotFoundHandler((_request, reply) => reply.code(404).send({ error: 'not_found' }));
  app.addHook('onResponse', async (request, reply) => {
    request.log.info({
      requestId: request.id, method: request.method, route: request.routeOptions.url ?? 'unmatched', statusCode: reply.statusCode,
    }, 'request_complete');
  });
  registerRoutes(app, dependencies);
  return app;
}

async function main(): Promise<void> {
  loadEnvironment();
  const config = readConfig();
  const tags = await loadTags(config.tagsFile);
  const pool = createDatabase(config.db);
  const app = buildServer({ config, tags, repository: new MySQLRepository(pool), model: new OpenAIWishModel(config.openai) }, true);
  app.addHook('onClose', async () => { await pool.end(); });
  for (const signal of ['SIGINT', 'SIGTERM'] as const) {
    process.once(signal, () => {
      app.close().catch(() => { process.exitCode = 1; });
    });
  }
  try { await app.listen({ host: config.host, port: config.port }); }
  catch (error) { await app.close(); throw error; }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(() => {
    console.error(JSON.stringify({ error: 'startup_failed' }));
    process.exitCode = 1;
  });
}
