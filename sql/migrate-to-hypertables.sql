-- migrate-to-hypertables.sql
-- Converts tag/tag_string to TimescaleDB hypertables with Hypercore columnstore,
-- indexes, continuous aggregates, and refresh policies.
-- Idempotent: safe to run multiple times.
-- Requires: TimescaleDB >= 2.25.0

-- =============================================================================
-- 1. HYPERTABLE CONVERSION
-- =============================================================================

-- Drop FK constraints (TimescaleDB hypertables don't support outgoing FKs)
ALTER TABLE tag DROP CONSTRAINT IF EXISTS tag_asset_id_fkey;
ALTER TABLE tag_string DROP CONSTRAINT IF EXISTS tag_string_asset_id_fkey;

-- Convert tag to hypertable (1-day chunks for high-volume numeric data)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM timescaledb_information.hypertables WHERE hypertable_name = 'tag') THEN
    PERFORM create_hypertable('tag', 'timestamp', migrate_data => true, chunk_time_interval => INTERVAL '1 day');
    RAISE NOTICE 'Converted tag to hypertable';
  END IF;
END $$;

-- Convert tag_string to hypertable (7-day chunks for low-volume string data)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM timescaledb_information.hypertables WHERE hypertable_name = 'tag_string') THEN
    PERFORM create_hypertable('tag_string', 'timestamp', migrate_data => true, chunk_time_interval => INTERVAL '7 days');
    RAISE NOTICE 'Converted tag_string to hypertable';
  END IF;
END $$;

-- =============================================================================
-- 2. INDEXES
-- =============================================================================

CREATE INDEX IF NOT EXISTS idx_tag_asset_name_time ON tag (asset_id, name, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_tag_string_asset_name_time ON tag_string (asset_id, name, timestamp DESC);

-- =============================================================================
-- 3. HYPERCORE COLUMNSTORE (replaces legacy compression)
-- =============================================================================

ALTER TABLE tag SET (
    timescaledb.enable_columnstore = true,
    timescaledb.segmentby = 'asset_id, name',
    timescaledb.orderby = 'timestamp DESC'
);

ALTER TABLE tag_string SET (
    timescaledb.enable_columnstore = true,
    timescaledb.segmentby = 'asset_id, name',
    timescaledb.orderby = 'timestamp DESC'
);

-- Columnstore policy: convert chunks older than 7 days to columnar format
DO $$ BEGIN
  BEGIN
    CALL add_columnstore_policy('tag', after => INTERVAL '7 days', if_not_exists => true);
    RAISE NOTICE 'Added columnstore policy for tag';
  EXCEPTION WHEN OTHERS THEN
    -- Fall back to legacy compression policy if columnstore policy not available
    PERFORM add_compression_policy('tag', INTERVAL '7 days', if_not_exists => true);
    RAISE NOTICE 'Added compression policy for tag (fallback)';
  END;
END $$;

DO $$ BEGIN
  BEGIN
    CALL add_columnstore_policy('tag_string', after => INTERVAL '7 days', if_not_exists => true);
    RAISE NOTICE 'Added columnstore policy for tag_string';
  EXCEPTION WHEN OTHERS THEN
    PERFORM add_compression_policy('tag_string', INTERVAL '7 days', if_not_exists => true);
    RAISE NOTICE 'Added compression policy for tag_string (fallback)';
  END;
END $$;

-- =============================================================================
-- 4. CONTINUOUS AGGREGATES
-- =============================================================================

-- 4a. Counter hourly aggregate (good_count, scrap_count with per-origin grouping)
-- Used by: get_counter_delta, get_quality, get_performance, get_oee
CREATE MATERIALIZED VIEW IF NOT EXISTS cagg_counter_hourly
WITH (timescaledb.continuous) AS
SELECT
    time_bucket(INTERVAL '1 hour', timestamp) AS bucket,
    asset_id,
    name,
    origin,
    COUNT(*) AS sample_count,
    MAX(value) AS max_value,
    MIN(value) AS min_value
FROM tag
GROUP BY bucket, asset_id, name, origin
WITH NO DATA;

-- 4b. Tag stats hourly aggregate (cycle_time_ms and all numeric tags)
-- Used by: get_cycle_time_avg, v_cycle_time_stats
CREATE MATERIALIZED VIEW IF NOT EXISTS cagg_tag_stats_hourly
WITH (timescaledb.continuous) AS
SELECT
    time_bucket(INTERVAL '1 hour', timestamp) AS bucket,
    asset_id,
    name,
    COUNT(*) AS sample_count,
    AVG(value) AS avg_value,
    MIN(value) AS min_value,
    MAX(value) AS max_value,
    SUM(value) AS sum_value
FROM tag
GROUP BY bucket, asset_id, name
WITH NO DATA;

-- =============================================================================
-- 5. CONTINUOUS AGGREGATE REFRESH POLICIES
-- =============================================================================

SELECT add_continuous_aggregate_policy('cagg_counter_hourly',
    start_offset => NULL,
    end_offset => INTERVAL '1 hour',
    schedule_interval => INTERVAL '15 minutes',
    if_not_exists => TRUE);

SELECT add_continuous_aggregate_policy('cagg_tag_stats_hourly',
    start_offset => NULL,
    end_offset => INTERVAL '1 hour',
    schedule_interval => INTERVAL '15 minutes',
    if_not_exists => TRUE);

-- =============================================================================
-- 6. HYPERCORE ON CONTINUOUS AGGREGATES
-- =============================================================================

ALTER MATERIALIZED VIEW cagg_counter_hourly SET (
    timescaledb.enable_columnstore = true,
    timescaledb.segmentby = 'asset_id, name, origin',
    timescaledb.orderby = 'bucket DESC'
);

ALTER MATERIALIZED VIEW cagg_tag_stats_hourly SET (
    timescaledb.enable_columnstore = true,
    timescaledb.segmentby = 'asset_id, name',
    timescaledb.orderby = 'bucket DESC'
);

DO $$ BEGIN
  BEGIN
    CALL add_columnstore_policy('cagg_counter_hourly', after => INTERVAL '7 days', if_not_exists => true);
    RAISE NOTICE 'Added columnstore policy for cagg_counter_hourly';
  EXCEPTION WHEN OTHERS THEN
    PERFORM add_compression_policy('cagg_counter_hourly', INTERVAL '7 days', if_not_exists => true);
  END;
END $$;

DO $$ BEGIN
  BEGIN
    CALL add_columnstore_policy('cagg_tag_stats_hourly', after => INTERVAL '7 days', if_not_exists => true);
    RAISE NOTICE 'Added columnstore policy for cagg_tag_stats_hourly';
  EXCEPTION WHEN OTHERS THEN
    PERFORM add_compression_policy('cagg_tag_stats_hourly', INTERVAL '7 days', if_not_exists => true);
  END;
END $$;

-- =============================================================================
-- 7. CONTINUOUS AGGREGATE INDEXES
-- =============================================================================

CREATE INDEX IF NOT EXISTS idx_cagg_counter_hourly_lookup
    ON cagg_counter_hourly (asset_id, name, bucket DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_tag_stats_hourly_lookup
    ON cagg_tag_stats_hourly (asset_id, name, bucket DESC);

-- =============================================================================
-- 8. PERMISSIONS
-- =============================================================================

DO $$ BEGIN
    EXECUTE 'GRANT SELECT ON cagg_counter_hourly TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

DO $$ BEGIN
    EXECUTE 'GRANT SELECT ON cagg_tag_stats_hourly TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;
