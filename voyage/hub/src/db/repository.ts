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

export interface Repository {
  ping(): Promise<void>;
  getFeatures(): Promise<Features>;
  touchDevice(publicKey: Buffer, seenAt: Date): Promise<void>;
  getApprovedCityContent(cityId: string): Promise<CityContentRow[]>;
  putCityContent(row: CityContentRow): Promise<void>;
  getWish(hash: string): Promise<WishCacheRow | null>;
  putWish(row: WishCacheRow): Promise<void>;
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
