CREATE TABLE IF NOT EXISTS voyage_schema_migrations (
  version VARCHAR(128) NOT NULL PRIMARY KEY,
  applied_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS voyage_config (
  config_key VARCHAR(64) NOT NULL PRIMARY KEY,
  config_value JSON NOT NULL,
  updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS voyage_devices (
  public_key BINARY(32) NOT NULL PRIMARY KEY,
  first_seen_at DATETIME(3) NOT NULL,
  last_seen_at DATETIME(3) NOT NULL,
  INDEX voyage_devices_last_seen (last_seen_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS voyage_city_content (
  id VARCHAR(128) COLLATE utf8mb4_bin NOT NULL PRIMARY KEY,
  city_id VARCHAR(96) COLLATE utf8mb4_bin NOT NULL,
  kind ENUM('play', 'question', 'souvenir') NOT NULL,
  content JSON NOT NULL,
  schema_version SMALLINT UNSIGNED NOT NULL DEFAULT 1,
  status ENUM('draft', 'approved', 'rejected') NOT NULL DEFAULT 'draft',
  source TEXT NULL,
  generated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  INDEX voyage_city_content_read (city_id, status, id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS voyage_wish_cache (
  wish_hash CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
  language VARCHAR(16) NOT NULL,
  tags JSON NOT NULL,
  model VARCHAR(128) NOT NULL,
  created_at DATETIME(3) NOT NULL,
  INDEX voyage_wish_cache_created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

INSERT INTO voyage_config (config_key, config_value) VALUES
  ('city_content_enabled', 'true'),
  ('wish_resolve_enabled', 'true'),
  ('encounters_enabled', 'false'),
  ('sponsor_content_enabled', 'false')
ON DUPLICATE KEY UPDATE config_key = config_key;
