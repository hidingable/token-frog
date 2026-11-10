import { createHash, createPublicKey, verify } from 'node:crypto';
import type { Repository } from './db/repository.js';

const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');
export const sha256 = (value: string | Buffer): string => createHash('sha256').update(value).digest('hex');

export function canonicalRequest(method: string, pathWithQuery: string, timestamp: string, body: Buffer): string {
  return `${method.toUpperCase()}\n${pathWithQuery}\n${timestamp}\n${sha256(body)}`;
}

function decodeBase64(value: unknown, size: number): Buffer | null {
  if (typeof value !== 'string') return null;
  const bytes = Buffer.from(value, 'base64');
  // Node's decoder accepts junk and base64url; the wire protocol is canonical padded base64.
  return bytes.length === size && bytes.toString('base64') === value ? bytes : null;
}

export function verifyRequest(input: {
  method: string; pathWithQuery: string; body: Buffer;
  device: unknown; timestamp: unknown; signature: unknown;
}, nowSeconds = Math.floor(Date.now() / 1000)): Buffer | null {
  const publicKey = decodeBase64(input.device, 32);
  const signature = decodeBase64(input.signature, 64);
  const timestamp = input.timestamp;
  if (!publicKey || !signature || typeof timestamp !== 'string' || !/^(0|[1-9]\d{0,10})$/.test(timestamp)) return null;
  if (Math.abs(nowSeconds - Number(timestamp)) > 300) return null;
  const key = createPublicKey({ key: Buffer.concat([ED25519_SPKI_PREFIX, publicKey]), format: 'der', type: 'spki' });
  return verify(null, Buffer.from(canonicalRequest(input.method, input.pathWithQuery, timestamp, input.body)), key, signature)
    ? publicKey : null;
}

/** Limit device writes, coalesce concurrent sightings, and expire inactive entries. */
export class DeviceRecorder {
  private seen = new Map<string, { at: number; pending?: Promise<void> }>();
  private lastSweep = 0;
  constructor(private repository: Repository, private now = Date.now) {}

  async record(publicKey: Buffer): Promise<void> {
    const now = this.now();
    if (now - this.lastSweep >= 60_000) {
      for (const [key, value] of this.seen) if (!value.pending && now - value.at >= 300_000) this.seen.delete(key);
      this.lastSweep = now;
    }
    const key = publicKey.toString('base64');
    const previous = this.seen.get(key);
    if (previous?.pending) return previous.pending;
    if (previous && now - previous.at < 300_000) return;
    const entry: { at: number; pending?: Promise<void> } = { at: now };
    this.seen.set(key, entry);
    entry.pending = this.repository.touchDevice(publicKey, new Date(now)).then(() => {
      entry.pending = undefined;
    }).catch(error => {
      this.seen.delete(key);
      throw error;
    });
    return entry.pending;
  }
}
