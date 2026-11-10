CREATE TABLE IF NOT EXISTS voyage_stays (
  stay_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
  public_key BINARY(32) NOT NULL,
  city_id VARCHAR(96) COLLATE utf8mb4_bin NOT NULL,
  local_day DATE NOT NULL,
  started_at DATETIME(3) NOT NULL,
  ends_at DATETIME(3) NOT NULL,
  appearance JSON NOT NULL,
  paired_stay_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NULL,
  partner_appearance JSON NULL,
  paired_at DATETIME(3) NULL,
  UNIQUE KEY voyage_stays_device_day (public_key, local_day),
  INDEX voyage_stays_city_end (city_id, ends_at),
  INDEX voyage_stays_waiting (city_id, paired_at, started_at, stay_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS voyage_sync (
  public_key BINARY(32) NOT NULL PRIMARY KEY,
  collection JSON NOT NULL,
  synced_at DATETIME(3) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
