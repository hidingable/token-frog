# Voyage Hub

Independent Node 22 / TypeScript service for redesign step 5a. It does not live in or import from Token Monitor's `worker/`. This step supplies configuration, city-content reads and wish classification. Content generation/publishing (5b), the Swift client (5c), stays, sync and pairing are later work. Nothing here deploys the service.

## Run and check

Run all commands from `voyage/hub/`, using the existing pinned dependencies:

```sh
npm run typecheck
npm test
npm run build
npm start
# Development alternative:
npm run dev
```

`build` emits `dist/src/server.js`. The server does not create tables or run migrations. Tests use `Fastify.inject`, `MemoryRepository` and fake models, with no database or OpenAI calls. MySQL integration is not part of `npm test`.

## Environment

See [.env.example](.env.example) for the complete variable list and placeholders. The service reads the process environment; it never searches for an env file. Optionally pass an explicit `HUB_ENV_FILE` to load it with Node's `process.loadEnvFile`, which supports `KEY = value`, quoted values and spaces. Existing process variables win. No credentials belong in tracked files.

| Variables | Behavior |
|---|---|
| `DB_HOST`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD` | Required MySQL connection values; the existing production database is `token`. Use only the dedicated `voyage_` tables. |
| `DB_PORT` | Default `3306`. |
| `OPENAI_MODEL` | Required model identifier, with no hardcoded model choice. |
| `OPENAI_API_KEY` | Optional at startup; without it, uncached wishes return `source: "error"`. |
| `OPENAI_BASE_URL` | Optional SDK base URL; otherwise the SDK's OpenAI endpoint. |
| `HOST`, `PORT` | Defaults `127.0.0.1:17322`. |
| `TRUST_PROXY` | Default `false`. Use trusted proxy IPs/CIDRs (comma-separated), or `true` when the origin is reachable only through trusted proxies. Numeric hop counts are unsupported by the installed Fastify. |
| `HUB_TAGS_FILE` | Default `../Content/tags.json`, resolved from the working directory and loaded once at startup. Keep the content pack beside the Hub or supply its path; no second maintained tag list. |
| `WISH_TIMEOUT_MS` | Default and maximum `2500`; includes feature lookup, cache I/O and model time after authentication. SDK retries and SDK logging are disabled. |
| `HUB_ENV_FILE` | Optional explicit env-file path. Never implicitly loads `voyage/.env`. |

Each rate bucket has a capacity and a continuous refill rate (tokens/second):

| Scope | Capacity variable (default) | Refill variable (default) |
|---|---|---|
| All API traffic by IP | `RATE_IP_CAPACITY` (120) | `RATE_IP_REFILL_PER_SECOND` (2) |
| Signed traffic by device | `RATE_DEVICE_CAPACITY` (60) | `RATE_DEVICE_REFILL_PER_SECOND` (1) |
| Wishes by IP, additional bucket | `WISH_RATE_IP_CAPACITY` (10) | `WISH_RATE_IP_REFILL_PER_SECOND` (1/6) |
| Wishes by device, additional bucket | `WISH_RATE_DEVICE_CAPACITY` (5) | `WISH_RATE_DEVICE_REFILL_PER_SECOND` (1/12) |

All buckets are in-process, for one Hub instance. `request.ip` follows Fastify's `TRUST_PROXY` rules; untrusted `X-Forwarded-For` values cannot split the IP bucket. Health probes bypass rate limiting. Inactive device/bucket entries expire lazily. Restarting clears rate counts, device-write throttles and the feature cache.

## Migrations

Only run this command after explicitly choosing the intended database/environment:

```sh
HUB_ENV_FILE=/absolute/path/to/private.env npm run migrate
```

The tiny runner applies numbered `.sql` files in numeric order and records each completed filename in `voyage_schema_migrations`. The initial file creates that bookkeeping table, `voyage_config`, `voyage_devices`, `voyage_city_content` and `voyage_wish_cache`, all with InnoDB and explicit `utf8mb4_0900_ai_ci` table defaults. City/content IDs and hashes use case-sensitive key collations. Default feature rows enable city content and wish resolution and disable encounters and sponsor content.

Run one migrator at a time. MySQL DDL commits implicitly: a failed file is not recorded, and already completed DDL is not rolled back. The initial migration is rerunnable (`IF NOT EXISTS`, non-overwriting config seeds). Applied files are immutable; append a numbered file for future changes. The runner accepts simple SQL statements separated by semicolons, not procedures or semicolons inside literals. It never creates a database. No migration was executed against a real database for this step.

## Endpoints

All `/v1` response fields are additive. Errors use `{ "error": "code" }`, with no request text or internal error details. Requests have a 32 KiB body limit. GET routes require an empty body. POST wishes require `Content-Type: application/json`.

| Endpoint | Signing | Result |
|---|---|---|
| `GET /healthz` | No | DB ping; `200 {"ok":true}` or `503 {"error":"database_unavailable"}`. |
| `GET /v1/config` | Optional, not verified | `{schemaVersion:1, cityContentEnabled, wishResolveEnabled, encountersEnabled, sponsorContentEnabled}`. Shared 60 s process cache. |
| `GET /v1/cities/:cityId/content?lang=zh-Hans\|en` | Required | `{schemaVersion:1, cityId, language, disabled, items:[...]}`. Only approved, supported, structurally valid city records. Empty results are `items:[]`; switch off also sets `disabled:true` and skips the content query. |
| `POST /v1/wishes/resolve` | Required | Accepts `{text, language, allowedTags?}`; returns `{tags:[], source}`. |

Content items retain the content pack's native `Story` / `Item` shapes, including both `zh-Hans` and `en` maps. `lang` is required and echoed as `language`; it does not discard the other translation, because the app stores bilingual snapshots. Database categories `play` and `question` both store a complete `Story` (questions are its embedded `replies`); `souvenir` stores an `Item` with native `kind: "souvenir"`. Do not replace `Story.kind` with the storage category. Unknown additive fields survive reads. This service checks shape, bilingual fields, ID/city consistency and schema version; full cross-reference and semantic `ContentValidator` checks belong to the 5b publish pipeline and 5c client.

Wish `language` is `zh-Hans` or `en`. `text` must be nonblank and at most 40 grapheme clusters **before** normalization, counted with `Intl.Segmenter`; combined emoji count as one. Normalize with NFKC, trim, collapse whitespace to one ASCII space, then lowercase. `allowedTags`, when present, replaces the server's tag list; it may be empty. It is at most 256 tag IDs, each at most 64 characters matching `[a-z][a-z0-9-]*`. Otherwise the existing content pack's tags are used. No other wish fields are persisted.

For cache identity, deduplicate and sort the effective allowed list; `tagTableVersion = SHA256_HEX(UTF8(JSON.stringify(sortedTags)))`. Then `wishHash = SHA256_HEX(UTF8(JSON.stringify([normalizedText, language, tagTableVersion])))`. This prevents reuse across different client whitelists or languages. Model and cached results are deduplicated and whitelist-filtered. Persist only the hash, language, tags, model and creation time. No raw or normalized wish text is stored or logged. Success sources are `model` and `cache`; unavailable/invalid model output or cache failure gives `error`; the server deadline gives `timeout`; the feature switch gives `disabled`. All three fallbacks return HTTP 200 with empty tags. A model that finishes after timeout is not allowed to populate the cache. A database write already issued before the deadline may complete afterwards.

Invalid signatures return 401, validation failures 400, unsupported media types 415, oversized bodies 413 and exhausted buckets 429 with `Retry-After` in whole seconds. Other service failures return 503. Structured request logs contain request ID, method, route template and response status, without bodies, headers, raw URLs or provider error messages.

## Request signing (Swift client contract)

Send these headers:

- `X-Voyage-Device`: standard padded base64 of the **raw 32-byte Ed25519 public key**, not DER.
- `X-Voyage-Timestamp`: canonical nonnegative integer Unix seconds, decimal ASCII.
- `X-Voyage-Signature`: standard padded base64 of the raw 64-byte Ed25519 signature.

Sign the UTF-8 bytes of this exact string, with LF separators and **no trailing newline**:

```text
METHOD\nPATH_WITH_QUERY\nTIMESTAMP\nSHA256_HEX(body)
```

`METHOD` is uppercase. `PATH_WITH_QUERY` is the exact transmitted origin-form path and query (no scheme/host/fragment): preserve parameter order, percent-encoding, percent-escape case and all other bytes. The server uses `request.raw.url`. The body hash is lowercase hex of the exact transmitted body bytes, before JSON parsing; never reserialize after signing. GET has an empty body, whose SHA-256 is `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`. Timestamps at ±300 seconds are accepted; beyond that they fail. Node wraps the public key with SPKI DER prefix `302a300506032b6570032100` and calls `crypto.verify(null, ...)`. No algorithm negotiation.

Device sightings are upserted at most once per five minutes per active device per process. This key is an anonymous rate-limit identifier, not proof of trusted identity. Signed requests are replayable within the time window, subject to rate limiting; these 5a endpoints have no per-user state-changing operations beyond sightings/cache. No nonce protocol is introduced.

### Fixed test vector

This is public test material, never a production device key. It is checked in [test/signing.test.ts](test/signing.test.ts) and [test/helpers.ts](test/helpers.ts).

```text
Ed25519 private seed (hex):
9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60
Raw public key (base64):
11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=
Method: POST
Path: /v1/wishes/resolve
Timestamp: 1700000000
Body (UTF-8, no newline): {"text":"Sea","language":"en"}
Body SHA-256:
895ab08e3bbe7108c3f5e0f19d347db7a735b79bae98e9f7dfda829a4ed95e2e
Expected signature (base64):
ZcXYcypapsgkZLVgpkdFDahx+Ed6QLX7ocMNE8yRo5ajcda2/NKsFLEgcjnZmWn+50GhacL3FQWV3Yh9kCz+AQ==
```

The private seed can be imported into Node as PKCS#8 DER prefix `302e020100300506032b657004220420` followed by the seed. The canonical string for this vector is:

```text
POST
/v1/wishes/resolve
1700000000
895ab08e3bbe7108c3f5e0f19d347db7a735b79bae98e9f7dfda829a4ed95e2e
```
