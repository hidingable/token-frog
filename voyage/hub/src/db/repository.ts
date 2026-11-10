export const DEFAULT_FEATURES = {
  cityContentEnabled: true,
  wishResolveEnabled: true,
  encountersEnabled: false,
  sponsorContentEnabled: false,
};
export type Features = typeof DEFAULT_FEATURES;
export const FEATURE_KEYS: Record<keyof Features, string> = {
  cityContentEnabled: 'city_content_enabled',
  wishResolveEnabled: 'wish_resolve_enabled',
  encountersEnabled: 'encounters_enabled',
  sponsorContentEnabled: 'sponsor_content_enabled',
};

export interface CityContentRow {
  id: string;
  cityId: string;
  kind: 'play' | 'question' | 'souvenir';
  content: unknown;
  schemaVersion: number;
  status: 'draft' | 'approved' | 'rejected';
  source: string | null;
  generatedAt: Date;
}

export interface WishCacheRow {
  hash: string;
  language: string;
  tags: string[];
  model: string;
  createdAt: Date;
}

export interface Appearance { species: string; stage: 'hatchling' | 'juvenile' | 'teen' }
export interface StayRow {
  stayId: string;
  publicKey: Buffer;
  cityId: string;
  day: string;
  startedAt: Date;
  endsAt: Date;
  appearance: Appearance;
  pairedStayId: string | null;
  partnerAppearance: Appearance | null;
  pairedAt: Date | null;
}
export type StayRegistration =
  | { kind: 'ok'; stay: StayRow }
  | { kind: 'stay_id_conflict' | 'daily_limit' };

export interface SyncRow { publicKey: Buffer; collection: string[]; syncedAt: Date }

export interface Repository {
  ping(): Promise<void>;
  getFeatures(): Promise<Features>;
  touchDevice(publicKey: Buffer, seenAt: Date): Promise<void>;
  getApprovedCityContent(cityId: string): Promise<CityContentRow[]>;
  putCityContent(row: CityContentRow): Promise<void>;
  getWish(hash: string): Promise<WishCacheRow | null>;
  putWish(row: WishCacheRow): Promise<void>;
  /** Atomic registration, idempotency, daily limit and oldest-waiting pairing. */
  registerStay(row: StayRow): Promise<StayRegistration>;
  getStay(stayId: string): Promise<StayRow | null>;
  getApprovedContentIds(ids: string[]): Promise<Set<string>>;
  putSync(row: SyncRow): Promise<void>;
  deleteDevice(publicKey: Buffer): Promise<void>;
  deleteExpiredStays(endedBefore: Date): Promise<void>;
}

export class FeatureCache {
  private cached?: { value: Features; expiresAt: number };
  private pending?: Promise<Features>;

  constructor(private repository: Repository, private now = Date.now) {}

  async get(): Promise<Features> {
    if (this.cached && this.now() < this.cached.expiresAt) return this.cached.value;
    if (!this.pending) {
      this.pending = this.repository.getFeatures().then(value => {
        this.cached = { value, expiresAt: this.now() + 60_000 };
        return value;
      }).finally(() => { this.pending = undefined; });
    }
    return this.pending;
  }
}
