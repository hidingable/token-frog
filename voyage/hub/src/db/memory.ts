import {
  DEFAULT_FEATURES, type CityContentRow, type Features, type Repository, type WishCacheRow,
  type StayRow, type StayRegistration, type SyncRow,
} from './repository.js';

/** Test repository; no connection, credentials or model access. */
export class MemoryRepository implements Repository {
  features: Features = { ...DEFAULT_FEATURES };
  content: CityContentRow[] = [];
  wishes = new Map<string, WishCacheRow>();
  devices = new Map<string, { firstSeen: Date; lastSeen: Date }>();
  stays = new Map<string, StayRow>();
  sync = new Map<string, SyncRow>();
  private stayTransaction: Promise<void> = Promise.resolve();

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

  async putCityContent(row: CityContentRow): Promise<void> {
    const index = this.content.findIndex(existing => existing.id === row.id);
    if (index < 0) this.content.push(structuredClone(row));
    else this.content[index] = structuredClone(row);
  }

  async getWish(hash: string): Promise<WishCacheRow | null> {
    return structuredClone(this.wishes.get(hash) ?? null);
  }
  async putWish(row: WishCacheRow): Promise<void> { this.wishes.set(row.hash, structuredClone(row)); }

  async registerStay(row: StayRow): Promise<StayRegistration> {
    // Model the database registration lock. Concurrent callers cannot select the same waiter.
    const previous = this.stayTransaction;
    let release!: () => void;
    this.stayTransaction = new Promise<void>(resolve => { release = resolve; });
    await previous;
    try {
      const existing = this.stays.get(row.stayId);
      if (existing) return existing.publicKey.equals(row.publicKey)
        ? { kind: 'ok', stay: cloneStay(existing) } : { kind: 'stay_id_conflict' };
      if ([...this.stays.values()].some(stay => stay.publicKey.equals(row.publicKey) && stay.day === row.day)) {
        return { kind: 'daily_limit' };
      }
      const own = cloneStay(row);
      const partner = [...this.stays.values()].filter(stay => stay.cityId === own.cityId
        && !stay.pairedAt && stay.endsAt > own.startedAt && !stay.publicKey.equals(own.publicKey))
        .sort((a, b) => a.startedAt.getTime() - b.startedAt.getTime() || a.stayId.localeCompare(b.stayId))[0];
      if (partner) {
        own.pairedStayId = partner.stayId;
        own.partnerAppearance = { ...partner.appearance };
        own.pairedAt = new Date(own.startedAt);
        partner.pairedStayId = own.stayId;
        partner.partnerAppearance = { ...own.appearance };
        partner.pairedAt = new Date(own.startedAt);
      }
      this.stays.set(own.stayId, own);
      return { kind: 'ok', stay: cloneStay(own) };
    } finally { release(); }
  }

  async getStay(stayId: string): Promise<StayRow | null> {
    const row = this.stays.get(stayId);
    return row ? cloneStay(row) : null;
  }

  async getApprovedContentIds(ids: string[]): Promise<Set<string>> {
    const requested = new Set(ids);
    return new Set(this.content.filter(row => row.status === 'approved' && requested.has(row.id)).map(row => row.id));
  }

  async putSync(row: SyncRow): Promise<void> {
    this.sync.set(row.publicKey.toString('base64'), { ...structuredClone(row), publicKey: Buffer.from(row.publicKey) });
  }

  async deleteDevice(publicKey: Buffer): Promise<void> {
    for (const [id, row] of this.stays) if (row.publicKey.equals(publicKey)) this.stays.delete(id);
    this.sync.delete(publicKey.toString('base64'));
    this.devices.delete(publicKey.toString('base64'));
  }

  async deleteExpiredStays(endedBefore: Date): Promise<void> {
    for (const [id, row] of this.stays) if (row.endsAt < endedBefore) this.stays.delete(id);
  }
}

function cloneStay(row: StayRow): StayRow {
  return { ...structuredClone(row), publicKey: Buffer.from(row.publicKey) };
}
