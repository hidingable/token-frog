import {
  DEFAULT_FEATURES, type CityContentRow, type Features, type Repository, type WishCacheRow,
} from './repository.js';

/** Test repository; no connection, credentials or model access. */
export class MemoryRepository implements Repository {
  features: Features = { ...DEFAULT_FEATURES };
  content: CityContentRow[] = [];
  wishes = new Map<string, WishCacheRow>();
  devices = new Map<string, { firstSeen: Date; lastSeen: Date }>();

  async ping(): Promise<void> {}
  async getFeatures(): Promise<Features> { return { ...this.features }; }

  async touchDevice(publicKey: Buffer, seenAt: Date): Promise<void> {
    const key = publicKey.toString('base64');
    this.devices.set(key, { firstSeen: this.devices.get(key)?.firstSeen ?? seenAt, lastSeen: seenAt });
  }

  async getApprovedCityContent(cityId: string): Promise<CityContentRow[]> {
    return structuredClone(this.content.filter(row => row.cityId === cityId && row.status === 'approved')
      .sort((a, b) => a.id.localeCompare(b.id)));
  }

  async getWish(hash: string): Promise<WishCacheRow | null> {
    return structuredClone(this.wishes.get(hash) ?? null);
  }
  async putWish(row: WishCacheRow): Promise<void> { this.wishes.set(row.hash, structuredClone(row)); }
}
