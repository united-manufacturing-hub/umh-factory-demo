-- =============================================================================
-- REUSABLE SQL VIEWS FOR GRAFANA DASHBOARDS
-- Provides pre-calculated metrics for OEE, production, stops, and more
-- =============================================================================
-- Run with: docker compose exec timescaledb psql -U postgres -d umh -f /sql/views.sql

-- -----------------------------------------------------------------------------
-- View: v_machine_current_state
-- Purpose: Current state for each machine (single row per asset)
-- Usage: SELECT * FROM v_machine_current_state WHERE line = 'line1';
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_machine_current_state AS
SELECT DISTINCT ON (a.id)
    a.id AS asset_id,
    a.enterprise,
    a.site,
    a.area,
    a.line,
    a.workcell,
    ts.value AS state,
    ts.timestamp AS state_since,
    EXTRACT(EPOCH FROM (NOW() - ts.timestamp))::integer AS duration_seconds
FROM asset a
LEFT JOIN tag_string ts ON ts.asset_id = a.id AND ts.name = 'state'
WHERE a.workcell != ''  -- Only include workcell-level assets (machines)
ORDER BY a.id, ts.timestamp DESC;

-- Grant permissions
DO $$ BEGIN
    EXECUTE 'GRANT SELECT ON v_machine_current_state TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- View: v_active_issues
-- Purpose: Currently active (ongoing) stops requiring attention
-- Usage: SELECT * FROM v_active_issues WHERE line = 'line1';
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_active_issues AS
SELECT
    ms.id AS stop_id,
    ms.asset_id,
    a.enterprise,
    a.site,
    a.area,
    a.line,
    a.workcell,
    ms.start_time,
    EXTRACT(EPOCH FROM (NOW() - ms.start_time)) / 60.0 AS duration_mins,
    COALESCE(sr.name, 'Unspecified') AS reason_name,
    COALESCE(sr.category, 'Unknown') AS category,
    ms.notes
FROM machine_stops ms
JOIN asset a ON a.id = ms.asset_id
LEFT JOIN stop_reasons sr ON sr.id = ms.stop_reason_id
WHERE ms.end_time IS NULL;  -- Only ongoing stops

-- Grant permissions
DO $$ BEGIN
    EXECUTE 'GRANT SELECT ON v_active_issues TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- View: v_stop_reasons_pareto
-- Purpose: Pareto analysis of stop reasons (count, duration, cumulative %)
-- Note: This is a materialized calculation, best used with time filter in query
-- Usage: SELECT * FROM v_stop_reasons_pareto WHERE asset_id IN (...);
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_stop_reasons_pareto AS
WITH stop_agg AS (
    SELECT
        ms.asset_id,
        COALESCE(sr.name, 'Unspecified') AS reason_name,
        COALESCE(sr.category, 'Unknown') AS category,
        COUNT(*) AS stop_count,
        SUM(EXTRACT(EPOCH FROM (COALESCE(ms.end_time, NOW()) - ms.start_time)) / 60.0) AS total_duration_mins
    FROM machine_stops ms
    LEFT JOIN stop_reasons sr ON sr.id = ms.stop_reason_id
    GROUP BY ms.asset_id, sr.name, sr.category
),
totals AS (
    SELECT
        asset_id,
        SUM(stop_count) AS total_stops,
        SUM(total_duration_mins) AS total_duration
    FROM stop_agg
    GROUP BY asset_id
),
ranked AS (
    SELECT
        sa.asset_id,
        sa.reason_name,
        sa.category,
        sa.stop_count,
        ROUND(sa.total_duration_mins::numeric, 1) AS total_duration_mins,
        ROUND((sa.stop_count * 100.0 / NULLIF(t.total_stops, 0))::numeric, 1) AS pct_of_total,
        SUM(sa.stop_count) OVER (PARTITION BY sa.asset_id ORDER BY sa.stop_count DESC) AS cumulative_count,
        t.total_stops
    FROM stop_agg sa
    JOIN totals t ON t.asset_id = sa.asset_id
)
SELECT
    asset_id,
    reason_name,
    category,
    stop_count,
    total_duration_mins,
    pct_of_total,
    ROUND((cumulative_count * 100.0 / NULLIF(total_stops, 0))::numeric, 1) AS cumulative_pct
FROM ranked
ORDER BY asset_id, stop_count DESC;

-- Grant permissions
DO $$ BEGIN
    EXECUTE 'GRANT SELECT ON v_stop_reasons_pareto TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- View: v_order_progress
-- Purpose: Production order status with completion percentage
-- Usage: SELECT * FROM v_order_progress WHERE line = 'line1' AND status = 'IN_PROGRESS';
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_order_progress AS
SELECT
    po.id,
    po.order_id,
    po.asset_id,
    a.enterprise,
    a.site,
    a.area,
    a.line,
    po.customer,
    po.part_number,
    po.part_description,
    po.quantity,
    po.quantity_completed,
    po.quantity_scrap,
    ROUND((po.quantity_completed * 100.0 / NULLIF(po.quantity, 0))::numeric, 1) AS progress_pct,
    ROUND((po.quantity_completed * 100.0 / NULLIF(po.quantity_completed + po.quantity_scrap, 0))::numeric, 1) AS quality_pct,
    po.status,
    po.started_at,
    po.completed_at,
    po.due_date,
    CASE
        WHEN po.status = 'COMPLETED' AND po.due_date IS NOT NULL AND po.completed_at > po.due_date THEN FALSE
        WHEN po.status != 'COMPLETED' AND po.due_date IS NOT NULL AND NOW() > po.due_date THEN FALSE
        ELSE TRUE
    END AS on_time,
    po.created_at,
    po.updated_at
FROM production_orders po
JOIN asset a ON a.id = po.asset_id;

-- Grant permissions
DO $$ BEGIN
    EXECUTE 'GRANT SELECT ON v_order_progress TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- View: v_cycle_time_stats
-- Purpose: Cycle time analysis by asset (for recent data)
-- Note: Best used with time filter in Grafana query
-- Usage: SELECT * FROM v_cycle_time_stats WHERE asset_id = X;
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_cycle_time_stats AS
SELECT
    t.asset_id,
    a.enterprise,
    a.site,
    a.area,
    a.line,
    a.workcell,
    ROUND(AVG(t.value)::numeric, 0) AS avg_cycle_time_ms,
    ROUND(MIN(t.value)::numeric, 0) AS min_cycle_time_ms,
    ROUND(MAX(t.value)::numeric, 0) AS max_cycle_time_ms,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY t.value)::numeric, 0) AS median_cycle_time_ms,
    COUNT(*) AS sample_count
FROM tag t
JOIN asset a ON a.id = t.asset_id
WHERE t.name = 'cycle_time_ms'
  AND t.value > 0
  AND t.value < 600000  -- Filter outliers (max 10 min cycle time)
  AND t.timestamp > NOW() - INTERVAL '24 hours'  -- Last 24 hours by default
GROUP BY t.asset_id, a.enterprise, a.site, a.area, a.line, a.workcell;

-- Grant permissions
DO $$ BEGIN
    EXECUTE 'GRANT SELECT ON v_cycle_time_stats TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- Function: get_production_delta
-- Purpose: Calculate production delta for a time range (handles counter resets)
-- Usage: SELECT get_production_delta(asset_id, 'good_count', start_time, end_time);
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_production_delta(
    _asset_id integer,
    _tag_name text,
    _start_time timestamptz,
    _end_time timestamptz
) RETURNS numeric AS $func$
DECLARE
    start_value numeric;
    end_value numeric;
BEGIN
    -- Get the last value before or at start_time
    SELECT value INTO start_value
    FROM tag
    WHERE asset_id = _asset_id
      AND name = _tag_name
      AND timestamp < _start_time
    ORDER BY timestamp DESC
    LIMIT 1;

    -- Get the last value before or at end_time
    SELECT value INTO end_value
    FROM tag
    WHERE asset_id = _asset_id
      AND name = _tag_name
      AND timestamp <= _end_time
    ORDER BY timestamp DESC
    LIMIT 1;

    -- Return delta, handling NULL cases
    RETURN GREATEST(COALESCE(end_value, 0) - COALESCE(start_value, 0), 0);
END;
$func$ LANGUAGE plpgsql STABLE;

-- Grant permissions
DO $$ BEGIN
    EXECUTE 'GRANT EXECUTE ON FUNCTION get_production_delta(integer, text, timestamptz, timestamptz) TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- Function: get_availability_pct
-- Purpose: Calculate availability percentage for asset in time range
-- Usage: SELECT get_availability_pct(asset_id, start_time, end_time);
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_availability_pct(
    _asset_id integer,
    _start_time timestamptz,
    _end_time timestamptz
) RETURNS numeric AS $func$
DECLARE
    running_count bigint;
    total_count bigint;
BEGIN
    SELECT
        COUNT(*) FILTER (WHERE value = 'RUNNING'),
        COUNT(*)
    INTO running_count, total_count
    FROM tag_string
    WHERE asset_id = _asset_id
      AND name = 'state'
      AND timestamp BETWEEN _start_time AND _end_time;

    IF total_count = 0 THEN
        RETURN NULL;
    END IF;

    RETURN ROUND((running_count * 100.0 / total_count)::numeric, 1);
END;
$func$ LANGUAGE plpgsql STABLE;

-- Grant permissions
DO $$ BEGIN
    EXECUTE 'GRANT EXECUTE ON FUNCTION get_availability_pct(integer, timestamptz, timestamptz) TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- View: v_production_summary
-- Purpose: Production totals aggregated by asset and day
-- Note: Uses the last 30 days by default, use with time filter for specific ranges
-- Usage: SELECT * FROM v_production_summary WHERE line = 'line1';
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_production_summary AS
WITH daily_production AS (
    SELECT
        t.asset_id,
        DATE(t.timestamp) AS production_date,
        t.name,
        -- Get the last value of each day
        MAX(t.value) FILTER (WHERE t.timestamp = (
            SELECT MAX(timestamp)
            FROM tag t2
            WHERE t2.asset_id = t.asset_id
              AND t2.name = t.name
              AND DATE(t2.timestamp) = DATE(t.timestamp)
        )) AS end_of_day_value
    FROM tag t
    WHERE t.name IN ('good_count', 'scrap_count')
      AND t.timestamp > NOW() - INTERVAL '30 days'
    GROUP BY t.asset_id, DATE(t.timestamp), t.name
),
daily_with_prev AS (
    SELECT
        asset_id,
        production_date,
        name,
        end_of_day_value,
        LAG(end_of_day_value) OVER (PARTITION BY asset_id, name ORDER BY production_date) AS prev_value
    FROM daily_production
),
daily_deltas AS (
    SELECT
        asset_id,
        production_date,
        SUM(CASE WHEN name = 'good_count' THEN GREATEST(COALESCE(end_of_day_value, 0) - COALESCE(prev_value, 0), 0) ELSE 0 END) AS good_parts,
        SUM(CASE WHEN name = 'scrap_count' THEN GREATEST(COALESCE(end_of_day_value, 0) - COALESCE(prev_value, 0), 0) ELSE 0 END) AS scrap_parts
    FROM daily_with_prev
    GROUP BY asset_id, production_date
)
SELECT
    dd.asset_id,
    a.enterprise,
    a.site,
    a.area,
    a.line,
    a.workcell,
    dd.production_date,
    dd.good_parts,
    dd.scrap_parts,
    dd.good_parts + dd.scrap_parts AS total_parts,
    CASE
        WHEN (dd.good_parts + dd.scrap_parts) > 0
        THEN ROUND((dd.scrap_parts * 100.0 / (dd.good_parts + dd.scrap_parts))::numeric, 2)
        ELSE 0
    END AS scrap_rate_pct
FROM daily_deltas dd
JOIN asset a ON a.id = dd.asset_id
WHERE dd.production_date > NOW() - INTERVAL '30 days'
ORDER BY dd.production_date DESC, a.line, a.workcell;

-- Grant permissions
DO $$ BEGIN
    EXECUTE 'GRANT SELECT ON v_production_summary TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- View: v_shift_production
-- Purpose: Production output aggregated by shift period
-- Usage: SELECT * FROM v_shift_production WHERE line = 'line1';
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_shift_production AS
WITH shift_lines AS (
    SELECT DISTINCT enterprise, site, area, line FROM asset WHERE workcell != ''
),
shift_production AS (
    SELECT
        s.id AS shift_id,
        s.shift_name,
        DATE(s.start_time) AS shift_date,
        s.start_time,
        s.end_time,
        sl.enterprise,
        sl.site,
        sl.area,
        sl.line,
        a.id AS asset_id
    FROM shifts s
    CROSS JOIN shift_lines sl
    JOIN asset a ON a.enterprise = sl.enterprise
                AND a.site = sl.site
                AND a.area = sl.area
                AND a.line = sl.line
                AND a.workcell != ''
    WHERE s.end_time <= NOW()
      AND (s.asset_id IS NULL OR s.asset_id = a.id)
)
SELECT
    sp.shift_id,
    sp.shift_name,
    sp.shift_date,
    sp.start_time,
    sp.end_time,
    sp.enterprise,
    sp.site,
    sp.area,
    sp.line,
    COALESCE(SUM(GREATEST(
        COALESCE((SELECT value FROM tag WHERE asset_id = sp.asset_id AND name = 'good_count' AND timestamp <= sp.end_time ORDER BY timestamp DESC LIMIT 1), 0) -
        COALESCE((SELECT value FROM tag WHERE asset_id = sp.asset_id AND name = 'good_count' AND timestamp < sp.start_time ORDER BY timestamp DESC LIMIT 1), 0),
        0
    )), 0) AS good_parts,
    COALESCE(SUM(GREATEST(
        COALESCE((SELECT value FROM tag WHERE asset_id = sp.asset_id AND name = 'scrap_count' AND timestamp <= sp.end_time ORDER BY timestamp DESC LIMIT 1), 0) -
        COALESCE((SELECT value FROM tag WHERE asset_id = sp.asset_id AND name = 'scrap_count' AND timestamp < sp.start_time ORDER BY timestamp DESC LIMIT 1), 0),
        0
    )), 0) AS scrap_parts
FROM shift_production sp
GROUP BY sp.shift_id, sp.shift_name, sp.shift_date, sp.start_time, sp.end_time,
         sp.enterprise, sp.site, sp.area, sp.line
ORDER BY sp.start_time DESC;

-- Grant permissions
DO $$ BEGIN
    EXECUTE 'GRANT SELECT ON v_shift_production TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- View: v_availability
-- Purpose: Availability metric per asset (runtime / planned production time)
-- Note: Last 24 hours by default
-- Usage: SELECT * FROM v_availability WHERE line = 'line1';
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_availability AS
WITH time_range AS (
    SELECT NOW() - INTERVAL '24 hours' AS range_start, NOW() AS range_end
),
planned AS (
    SELECT CASE WHEN COUNT(*) > 0
        THEN SUM(EXTRACT(EPOCH FROM (
            LEAST(s.end_time, tr.range_end) - GREATEST(s.start_time, tr.range_start)
        )) / 60.0)
        ELSE NULL
    END AS planned_minutes
    FROM shifts s, time_range tr
    WHERE s.start_time < tr.range_end
      AND s.end_time > tr.range_start
),
runtime_per_asset AS (
    SELECT
        a.id AS asset_id,
        COALESCE((
            WITH shift_periods AS (
                SELECT
                    GREATEST(s.start_time, tr.range_start) AS period_start,
                    LEAST(s.end_time, tr.range_end) AS period_end
                FROM shifts s, time_range tr
                WHERE s.start_time < tr.range_end
                  AND s.end_time > tr.range_start
            ),
            state_changes AS (
                SELECT
                    timestamp, value,
                    LEAD(timestamp) OVER (ORDER BY timestamp) AS next_ts
                FROM tag_string
                WHERE name = 'state' AND asset_id = a.id
            )
            SELECT CASE WHEN (SELECT COUNT(*) FROM shift_periods) > 0
                THEN COALESCE(SUM(
                    EXTRACT(EPOCH FROM (
                        LEAST(COALESCE(sc.next_ts, sp.period_end), sp.period_end) -
                        GREATEST(sc.timestamp, sp.period_start)
                    )) / 60.0
                ), 0) ELSE NULL END
            FROM state_changes sc, shift_periods sp
            WHERE sc.value = 'RUNNING'
              AND sc.timestamp < sp.period_end
              AND COALESCE(sc.next_ts, sp.period_end) > sp.period_start
        ), 0) AS runtime_minutes
    FROM asset a
    WHERE a.workcell != ''
)
SELECT
    a.id AS asset_id,
    a.enterprise,
    a.site,
    a.area,
    a.line,
    a.workcell,
    rt.runtime_minutes,
    p.planned_minutes,
    CASE WHEN p.planned_minutes IS NOT NULL AND p.planned_minutes > 0
        THEN ROUND(LEAST(rt.runtime_minutes * 100.0 / p.planned_minutes, 100)::numeric, 1)
        ELSE NULL
    END AS availability_pct
FROM asset a
CROSS JOIN planned p
LEFT JOIN runtime_per_asset rt ON rt.asset_id = a.id
WHERE a.workcell != '';

DO $$ BEGIN
    EXECUTE 'GRANT SELECT ON v_availability TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- View: v_performance
-- Purpose: Performance metric per asset (actual output × ideal cycle time / runtime)
-- Note: Last 24 hours by default
-- Usage: SELECT * FROM v_performance WHERE line = 'line1';
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_performance AS
WITH time_range AS (
    SELECT NOW() - INTERVAL '24 hours' AS range_start, NOW() AS range_end
),
runtime_per_asset AS (
    SELECT
        a.id AS asset_id,
        COALESCE((
            WITH shift_periods AS (
                SELECT
                    GREATEST(s.start_time, tr.range_start) AS period_start,
                    LEAST(s.end_time, tr.range_end) AS period_end
                FROM shifts s, time_range tr
                WHERE s.start_time < tr.range_end
                  AND s.end_time > tr.range_start
            ),
            state_changes AS (
                SELECT
                    timestamp, value,
                    LEAD(timestamp) OVER (ORDER BY timestamp) AS next_ts
                FROM tag_string
                WHERE name = 'state' AND asset_id = a.id
            )
            SELECT CASE WHEN (SELECT COUNT(*) FROM shift_periods) > 0
                THEN COALESCE(SUM(
                    EXTRACT(EPOCH FROM (
                        LEAST(COALESCE(sc.next_ts, sp.period_end), sp.period_end) -
                        GREATEST(sc.timestamp, sp.period_start)
                    )) / 60.0
                ), 0) ELSE NULL END
            FROM state_changes sc, shift_periods sp
            WHERE sc.value = 'RUNNING'
              AND sc.timestamp < sp.period_end
              AND COALESCE(sc.next_ts, sp.period_end) > sp.period_start
        ), 0) AS runtime_minutes
    FROM asset a
    WHERE a.workcell != ''
),
parts_delta AS (
    SELECT
        asset_id, origin,
        MAX(value) FILTER (WHERE name = 'good_count' AND timestamp <= NOW()) AS end_good,
        MAX(value) FILTER (WHERE name = 'good_count' AND timestamp < NOW() - INTERVAL '24 hours') AS start_good,
        MAX(value) FILTER (WHERE name = 'scrap_count' AND timestamp <= NOW()) AS end_scrap,
        MAX(value) FILTER (WHERE name = 'scrap_count' AND timestamp < NOW() - INTERVAL '24 hours') AS start_scrap
    FROM tag
    WHERE name IN ('good_count', 'scrap_count')
      AND timestamp > NOW() - INTERVAL '25 hours'
    GROUP BY asset_id, origin
),
parts_totals AS (
    SELECT
        asset_id,
        SUM(GREATEST(COALESCE(end_good, 0) - COALESCE(start_good, 0), 0)) AS good_parts,
        SUM(GREATEST(COALESCE(end_scrap, 0) - COALESCE(start_scrap, 0), 0)) AS scrap_parts
    FROM parts_delta
    GROUP BY asset_id
),
ideal_cycle_times AS (
    SELECT DISTINCT ON (po.asset_id)
        po.asset_id,
        po.planned_cycle_time_ms / 1000.0 AS ideal_ct_sec
    FROM production_orders po
    WHERE po.status = 'IN_PROGRESS'
      AND po.planned_cycle_time_ms IS NOT NULL
      AND po.planned_cycle_time_ms > 0
    ORDER BY po.asset_id, po.started_at DESC
),
fallback_cycle_times AS (
    SELECT
        asset_id,
        PERCENTILE_CONT(0.05) WITHIN GROUP (ORDER BY value) / 1000.0 AS p5_ct_sec
    FROM tag
    WHERE name = 'cycle_time_ms'
      AND value > 0 AND value < 600000
      AND timestamp > NOW() - INTERVAL '24 hours'
    GROUP BY asset_id
)
SELECT
    a.id AS asset_id,
    a.enterprise,
    a.site,
    a.area,
    a.line,
    a.workcell,
    COALESCE(pt.good_parts, 0) + COALESCE(pt.scrap_parts, 0) AS total_parts,
    ROUND(COALESCE(COALESCE(ict.ideal_ct_sec, fct.p5_ct_sec) * 1000, 0)::numeric, 0) AS planned_cycle_time_ms,
    rt.runtime_minutes,
    ROUND(LEAST(
        CASE
            WHEN rt.runtime_minutes > 0 AND COALESCE(ict.ideal_ct_sec, fct.p5_ct_sec) > 0 THEN
                ((COALESCE(pt.good_parts, 0) + COALESCE(pt.scrap_parts, 0))
                 * COALESCE(ict.ideal_ct_sec, fct.p5_ct_sec) * 100.0)
                / (rt.runtime_minutes * 60)
            ELSE 0
        END,
        100
    )::numeric, 1) AS performance_pct
FROM asset a
LEFT JOIN runtime_per_asset rt ON rt.asset_id = a.id
LEFT JOIN parts_totals pt ON pt.asset_id = a.id
LEFT JOIN ideal_cycle_times ict ON ict.asset_id = a.id
LEFT JOIN fallback_cycle_times fct ON fct.asset_id = a.id
WHERE a.workcell != '';

DO $$ BEGIN
    EXECUTE 'GRANT SELECT ON v_performance TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- View: v_quality
-- Purpose: Quality metric per asset (good parts / total parts)
-- Note: Last 24 hours by default
-- Usage: SELECT * FROM v_quality WHERE line = 'line1';
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_quality AS
WITH parts_delta AS (
    SELECT
        asset_id, origin,
        MAX(value) FILTER (WHERE name = 'good_count' AND timestamp <= NOW()) AS end_good,
        MAX(value) FILTER (WHERE name = 'good_count' AND timestamp < NOW() - INTERVAL '24 hours') AS start_good,
        MAX(value) FILTER (WHERE name = 'scrap_count' AND timestamp <= NOW()) AS end_scrap,
        MAX(value) FILTER (WHERE name = 'scrap_count' AND timestamp < NOW() - INTERVAL '24 hours') AS start_scrap
    FROM tag
    WHERE name IN ('good_count', 'scrap_count')
      AND timestamp > NOW() - INTERVAL '25 hours'
    GROUP BY asset_id, origin
),
parts_totals AS (
    SELECT
        asset_id,
        SUM(GREATEST(COALESCE(end_good, 0) - COALESCE(start_good, 0), 0)) AS good_parts,
        SUM(GREATEST(COALESCE(end_scrap, 0) - COALESCE(start_scrap, 0), 0)) AS scrap_parts
    FROM parts_delta
    GROUP BY asset_id
)
SELECT
    a.id AS asset_id,
    a.enterprise,
    a.site,
    a.area,
    a.line,
    a.workcell,
    COALESCE(pt.good_parts, 0) AS good_parts,
    COALESCE(pt.scrap_parts, 0) AS scrap_parts,
    COALESCE(pt.good_parts, 0) + COALESCE(pt.scrap_parts, 0) AS total_parts,
    ROUND(
        CASE
            WHEN (COALESCE(pt.good_parts, 0) + COALESCE(pt.scrap_parts, 0)) > 0
            THEN (COALESCE(pt.good_parts, 0) * 100.0 / (COALESCE(pt.good_parts, 0) + COALESCE(pt.scrap_parts, 0)))
            ELSE 100
        END::numeric, 1
    ) AS quality_pct
FROM asset a
LEFT JOIN parts_totals pt ON pt.asset_id = a.id
WHERE a.workcell != '';

DO $$ BEGIN
    EXECUTE 'GRANT SELECT ON v_quality TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

-- =============================================================================
-- MATERIALIZED VIEW: mv_runtime_hourly
-- Pre-computes hourly RUNNING minutes per asset from tag_string state events.
-- Uses LEAD() window function which can't be in a continuous aggregate.
-- Refresh: REFRESH MATERIALIZED VIEW CONCURRENTLY mv_runtime_hourly;
-- =============================================================================

DROP MATERIALIZED VIEW IF EXISTS mv_runtime_hourly;

CREATE MATERIALIZED VIEW mv_runtime_hourly AS
WITH state_events AS (
    SELECT
        asset_id,
        timestamp,
        value,
        LEAD(timestamp) OVER (PARTITION BY asset_id ORDER BY timestamp) AS next_ts
    FROM tag_string
    WHERE name = 'state'
)
SELECT
    time_bucket('1 hour', se.timestamp) AS bucket,
    se.asset_id,
    COALESCE(SUM(
        EXTRACT(EPOCH FROM (
            LEAST(
                COALESCE(se.next_ts, NOW()),
                time_bucket('1 hour', se.timestamp) + INTERVAL '1 hour'
            ) - GREATEST(se.timestamp, time_bucket('1 hour', se.timestamp))
        )) / 60.0
    ) FILTER (WHERE se.value = 'RUNNING'), 0) AS running_minutes,
    COUNT(*) AS event_count
FROM state_events se
GROUP BY time_bucket('1 hour', se.timestamp), se.asset_id;

CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_runtime_hourly_pk
    ON mv_runtime_hourly (asset_id, bucket);

DO $$ BEGIN
    EXECUTE 'GRANT SELECT ON mv_runtime_hourly TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

-- =============================================================================
-- LAYER 1: PRIMITIVE FUNCTIONS
-- These are the building blocks called by dashboard panels and composite functions
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Function: get_counter_delta
-- Purpose: Counter delta with per-origin grouping and reset handling.
--          Works at any hierarchy level (empty string = match all).
-- Usage: SELECT get_counter_delta('E','S','A','L','W','good_count',start,end);
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_counter_delta(
    _enterprise text,
    _site text,
    _area text,
    _line text,
    _workcell text,
    _tag_name text,
    _start_time timestamptz,
    _end_time timestamptz
) RETURNS numeric AS $func$
DECLARE
    _start_bucket timestamptz := time_bucket('1 hour', _start_time);
    _end_bucket   timestamptz := time_bucket('1 hour', _end_time);
    _result numeric;
BEGIN
    -- Try cagg_counter_hourly for complete hours + raw tag for boundary hours.
    -- Falls back to raw-only query if cagg doesn't exist.
    BEGIN
        SELECT COALESCE(SUM(GREATEST(COALESCE(end_v, 0) - COALESCE(start_v, 0), 0)), 0) INTO _result
        FROM (
            SELECT
                asset_id, origin,
                MAX(value) FILTER (WHERE ts_marker <= _end_time) AS end_v,
                MAX(value) FILTER (WHERE ts_marker < _start_time) AS start_v
            FROM (
                SELECT c.asset_id, c.origin, c.max_value AS value,
                       c.bucket + INTERVAL '1 hour' - INTERVAL '1 microsecond' AS ts_marker
                FROM cagg_counter_hourly c
                WHERE c.name = _tag_name
                  AND c.asset_id IN (SELECT get_asset_ids_stable(_enterprise, _site, _area, _line, _workcell))
                  AND c.bucket >= _start_bucket - INTERVAL '1 hour'
                  AND c.bucket < _end_bucket
                UNION ALL
                SELECT t.asset_id, t.origin, t.value, t.timestamp AS ts_marker
                FROM tag t
                WHERE t.name = _tag_name
                  AND t.asset_id IN (SELECT get_asset_ids_stable(_enterprise, _site, _area, _line, _workcell))
                  AND t.timestamp >= _start_bucket
                  AND t.timestamp < _start_bucket + INTERVAL '1 hour'
                UNION ALL
                SELECT t.asset_id, t.origin, t.value, t.timestamp AS ts_marker
                FROM tag t
                WHERE t.name = _tag_name
                  AND t.asset_id IN (SELECT get_asset_ids_stable(_enterprise, _site, _area, _line, _workcell))
                  AND t.timestamp >= _end_bucket
                  AND t.timestamp <= _end_time
            ) combined
            GROUP BY asset_id, origin
        ) sub;
        RETURN _result;
    EXCEPTION WHEN undefined_table THEN
        -- Fallback: raw tag table only (no cagg available)
        RETURN COALESCE((
            SELECT SUM(GREATEST(COALESCE(end_v, 0) - COALESCE(start_v, 0), 0))
            FROM (
                SELECT t.asset_id, t.origin,
                    MAX(t.value) FILTER (WHERE t.timestamp <= _end_time) AS end_v,
                    MAX(t.value) FILTER (WHERE t.timestamp < _start_time) AS start_v
                FROM tag t
                WHERE t.name = _tag_name
                  AND t.asset_id IN (SELECT get_asset_ids_stable(_enterprise, _site, _area, _line, _workcell))
                  AND t.timestamp >= _start_time - INTERVAL '1 hour'
                  AND t.timestamp <= _end_time
                GROUP BY t.asset_id, t.origin
            ) sub
        ), 0);
    END;
END;
$func$ LANGUAGE plpgsql STABLE;

DO $$ BEGIN
    EXECUTE 'GRANT EXECUTE ON FUNCTION get_counter_delta(text,text,text,text,text,text,timestamptz,timestamptz) TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- Function: get_availability
-- Purpose: Runtime / Planned Production Time (time-based, shift-constrained).
-- Usage: SELECT get_availability('E','S','A','L','',start,end);
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_availability(
    _enterprise text,
    _site text,
    _area text,
    _line text,
    _workcell text,
    _start_time timestamptz,
    _end_time timestamptz
) RETURNS numeric AS $func$
DECLARE
    total_runtime numeric := 0;
    planned numeric;
    asset_count integer := 0;
    _aid integer;
BEGIN
    -- Sum runtime across all matching assets
    FOR _aid IN SELECT get_asset_ids_stable(_enterprise, _site, _area, _line, _workcell)
    LOOP
        total_runtime := total_runtime + COALESCE(get_runtime_minutes(_aid, _start_time, _end_time), 0);
        asset_count := asset_count + 1;
    END LOOP;

    IF asset_count = 0 THEN
        RETURN NULL;
    END IF;

    planned := get_planned_minutes(_start_time, _end_time);
    IF planned IS NULL OR planned = 0 THEN
        RETURN NULL;
    END IF;

    -- Average availability: total runtime / (planned time × number of assets)
    RETURN ROUND(LEAST(total_runtime * 100.0 / (planned * asset_count), 100)::numeric, 1);
END;
$func$ LANGUAGE plpgsql STABLE;

DO $$ BEGIN
    EXECUTE 'GRANT EXECUTE ON FUNCTION get_availability(text,text,text,text,text,timestamptz,timestamptz) TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- Function: get_planned_minutes
-- Purpose: Sum of overlapping shift periods within time range.
-- Usage: SELECT get_planned_minutes(start, end);
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_planned_minutes(
    _start_time timestamptz,
    _end_time timestamptz
) RETURNS numeric AS $func$
BEGIN
    RETURN (
        SELECT CASE WHEN COUNT(*) > 0
            THEN SUM(EXTRACT(EPOCH FROM (
                LEAST(s.end_time, _end_time) - GREATEST(s.start_time, _start_time)
            )) / 60.0)
            ELSE NULL
        END
        FROM shifts s
        WHERE s.start_time < _end_time
          AND s.end_time > _start_time
    );
END;
$func$ LANGUAGE plpgsql STABLE;

DO $$ BEGIN
    EXECUTE 'GRANT EXECUTE ON FUNCTION get_planned_minutes(timestamptz,timestamptz) TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- Function: get_runtime_minutes
-- Purpose: RUNNING minutes for single asset, shift-constrained. Uses state_changes + LEAD().
-- Usage: SELECT get_runtime_minutes(asset_id, start, end);
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_runtime_minutes(
    _asset_id integer,
    _start_time timestamptz,
    _end_time timestamptz
) RETURNS numeric AS $func$
DECLARE
    _start_bucket timestamptz := time_bucket('1 hour', _start_time);
    _end_bucket   timestamptz := time_bucket('1 hour', _end_time);
    _planned numeric;
    _runtime numeric := 0;
    _boundary_runtime numeric := 0;
BEGIN
    -- Check if any shifts overlap
    SELECT CASE WHEN COUNT(*) > 0
        THEN SUM(EXTRACT(EPOCH FROM (
            LEAST(s.end_time, _end_time) - GREATEST(s.start_time, _start_time)
        )) / 60.0)
        ELSE NULL
    END INTO _planned
    FROM shifts s
    WHERE s.start_time < _end_time AND s.end_time > _start_time;

    IF _planned IS NULL THEN
        RETURN NULL;
    END IF;

    -- Sum pre-computed running minutes from mv_runtime_hourly for complete hours
    SELECT COALESCE(SUM(mv.running_minutes), 0) INTO _runtime
    FROM mv_runtime_hourly mv
    WHERE mv.asset_id = _asset_id
      AND mv.bucket >= _start_bucket + INTERVAL '1 hour'  -- first complete bucket after start
      AND mv.bucket < _end_bucket;                          -- last complete bucket before end

    -- Add boundary hours from raw tag_string (only 2 partial hours max)
    SELECT COALESCE(SUM(
        EXTRACT(EPOCH FROM (
            LEAST(COALESCE(sc.next_ts, _end_time), _end_time) -
            GREATEST(sc.timestamp, _start_time)
        )) / 60.0
    ), 0) INTO _boundary_runtime
    FROM (
        SELECT timestamp, value,
               LEAD(timestamp) OVER (ORDER BY timestamp) AS next_ts
        FROM tag_string
        WHERE name = 'state' AND asset_id = _asset_id
          AND timestamp < _start_bucket + INTERVAL '1 hour'  -- events that overlap start boundary
          AND (timestamp >= _start_bucket OR TRUE)            -- include pre-boundary for LEAD
    ) sc
    WHERE sc.value = 'RUNNING'
      AND sc.timestamp < LEAST(_start_bucket + INTERVAL '1 hour', _end_time)
      AND COALESCE(sc.next_ts, _end_time) > _start_time;

    -- End boundary (only if start and end are in different hours)
    IF _start_bucket != _end_bucket THEN
        _boundary_runtime := _boundary_runtime + COALESCE((
            SELECT SUM(
                EXTRACT(EPOCH FROM (
                    LEAST(COALESCE(sc.next_ts, _end_time), _end_time) -
                    GREATEST(sc.timestamp, _end_bucket)
                )) / 60.0
            )
            FROM (
                SELECT timestamp, value,
                       LEAD(timestamp) OVER (ORDER BY timestamp) AS next_ts
                FROM tag_string
                WHERE name = 'state' AND asset_id = _asset_id
                  AND timestamp >= _end_bucket - INTERVAL '1 hour'
                  AND timestamp <= _end_time
            ) sc
            WHERE sc.value = 'RUNNING'
              AND sc.timestamp < _end_time
              AND COALESCE(sc.next_ts, _end_time) > _end_bucket
        ), 0);
    END IF;

    -- Constrain by shift periods: cap at planned minutes
    RETURN LEAST(_runtime + _boundary_runtime, _planned);
END;
$func$ LANGUAGE plpgsql STABLE;

DO $$ BEGIN
    EXECUTE 'GRANT EXECUTE ON FUNCTION get_runtime_minutes(integer,timestamptz,timestamptz) TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- View: v_oee_by_asset
-- Purpose: OEE (Availability x Performance x Quality) calculation per asset
-- Note: Calculates OEE for the last 24 hours using time-based availability
--       and planned/ideal cycle time for performance.
--       Placed after get_planned_minutes and get_runtime_minutes which it depends on.
-- Usage: SELECT * FROM v_oee_by_asset WHERE line = 'line1';
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_oee_by_asset AS
WITH planned AS (
    SELECT get_planned_minutes(NOW() - INTERVAL '24 hours', NOW()) AS planned_minutes
),
ideal_cycle_times AS (
    SELECT DISTINCT ON (po.asset_id)
        po.asset_id,
        po.planned_cycle_time_ms / 1000.0 AS ideal_ct_sec
    FROM production_orders po
    WHERE po.status = 'IN_PROGRESS'
      AND po.planned_cycle_time_ms IS NOT NULL
      AND po.planned_cycle_time_ms > 0
    ORDER BY po.asset_id, po.started_at DESC
)
SELECT
    a.id AS asset_id,
    a.enterprise,
    a.site,
    a.area,
    a.line,
    a.workcell,
    -- Availability: runtime / planned production time
    CASE WHEN p.planned_minutes IS NOT NULL AND p.planned_minutes > 0
        THEN ROUND(LEAST(rt.runtime_minutes * 100.0 / p.planned_minutes, 100)::numeric, 1)
        ELSE NULL
    END AS availability_pct,
    -- Performance: (total_parts × ideal_cycle_time) / runtime
    ROUND(LEAST(
        CASE
            WHEN rt.runtime_minutes > 0 AND COALESCE(ict.ideal_ct_sec, fct.avg_ct_sec) > 0 THEN
                ((COALESCE(parts.good_parts, 0) + COALESCE(parts.scrap_parts, 0))
                 * COALESCE(ict.ideal_ct_sec, fct.avg_ct_sec) * 100.0)
                / (rt.runtime_minutes * 60)
            ELSE 0
        END,
        100
    )::numeric, 1) AS performance_pct,
    -- Quality: good parts / total parts
    ROUND(
        CASE
            WHEN (COALESCE(parts.good_parts, 0) + COALESCE(parts.scrap_parts, 0)) > 0
            THEN (COALESCE(parts.good_parts, 0) * 100.0 / (COALESCE(parts.good_parts, 0) + COALESCE(parts.scrap_parts, 0)))
            ELSE 100
        END::numeric, 1
    ) AS quality_pct,
    -- OEE: Availability × Performance × Quality
    ROUND((
        COALESCE(CASE WHEN p.planned_minutes IS NOT NULL AND p.planned_minutes > 0
            THEN LEAST(rt.runtime_minutes * 100.0 / p.planned_minutes, 100)
            ELSE 0
        END, 0) / 100.0 *
        LEAST(COALESCE(
            CASE
                WHEN rt.runtime_minutes > 0 AND COALESCE(ict.ideal_ct_sec, fct.avg_ct_sec) > 0 THEN
                    ((COALESCE(parts.good_parts, 0) + COALESCE(parts.scrap_parts, 0))
                     * COALESCE(ict.ideal_ct_sec, fct.avg_ct_sec) * 100.0)
                    / (rt.runtime_minutes * 60)
                ELSE 0
            END, 0
        ), 100) / 100.0 *
        COALESCE(
            CASE
                WHEN (COALESCE(parts.good_parts, 0) + COALESCE(parts.scrap_parts, 0)) > 0
                THEN (COALESCE(parts.good_parts, 0) * 100.0 / (COALESCE(parts.good_parts, 0) + COALESCE(parts.scrap_parts, 0)))
                ELSE 100
            END, 100
        ) / 100.0 * 100
    )::numeric, 1) AS oee_pct,
    COALESCE(parts.good_parts, 0) AS good_parts,
    COALESCE(parts.scrap_parts, 0) AS scrap_parts,
    rt.runtime_minutes,
    p.planned_minutes,
    COALESCE(ict.ideal_ct_sec, fct.avg_ct_sec) AS ideal_cycle_time_sec
FROM asset a
CROSS JOIN planned p
LEFT JOIN LATERAL (
    SELECT COALESCE(get_runtime_minutes(a.id, NOW() - INTERVAL '24 hours', NOW()), 0) AS runtime_minutes
) rt ON true
LEFT JOIN LATERAL (
    SELECT
        SUM(GREATEST(COALESCE(end_v, 0) - COALESCE(start_v, 0), 0)) FILTER (WHERE tag_name = 'good_count') AS good_parts,
        SUM(GREATEST(COALESCE(end_v, 0) - COALESCE(start_v, 0), 0)) FILTER (WHERE tag_name = 'scrap_count') AS scrap_parts
    FROM (
        SELECT
            t.name AS tag_name,
            t.origin,
            MAX(t.value) FILTER (WHERE t.timestamp <= NOW()) AS end_v,
            MAX(t.value) FILTER (WHERE t.timestamp < NOW() - INTERVAL '24 hours') AS start_v
        FROM tag t
        WHERE t.asset_id = a.id
          AND t.name IN ('good_count', 'scrap_count')
          AND t.timestamp > NOW() - INTERVAL '25 hours'
        GROUP BY t.name, t.origin
    ) sub
) parts ON true
LEFT JOIN ideal_cycle_times ict ON ict.asset_id = a.id
LEFT JOIN LATERAL (
    SELECT PERCENTILE_CONT(0.05) WITHIN GROUP (ORDER BY t.value) / 1000.0 AS avg_ct_sec
    FROM tag t
    WHERE t.asset_id = a.id
      AND t.name = 'cycle_time_ms'
      AND t.value > 0
      AND t.value < 600000
      AND t.timestamp > NOW() - INTERVAL '24 hours'
) fct ON true
WHERE a.workcell != '';

-- Grant permissions
DO $$ BEGIN
    EXECUTE 'GRANT SELECT ON v_oee_by_asset TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- Function: get_cycle_time_avg
-- Purpose: AVG cycle time in seconds (divides ms by 1000), filters outliers.
--          NULL times = all-time average.
-- Usage: SELECT get_cycle_time_avg('E','S','A','L','',start,end);
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_cycle_time_avg(
    _enterprise text,
    _site text,
    _area text,
    _line text,
    _workcell text,
    _start_time timestamptz DEFAULT NULL,
    _end_time timestamptz DEFAULT NULL
) RETURNS numeric AS $func$
DECLARE
    _start_bucket timestamptz;
    _end_bucket timestamptz;
    _result numeric;
BEGIN
    -- Try cagg_tag_stats_hourly for complete hours, raw tag for boundary hours.
    -- Falls back to raw-only query if cagg doesn't exist.
    BEGIN
        IF _start_time IS NULL OR _end_time IS NULL THEN
            SELECT SUM(c.sum_value) / NULLIF(SUM(c.sample_count), 0) / 1000.0 INTO _result
            FROM cagg_tag_stats_hourly c
            WHERE c.asset_id IN (SELECT get_asset_ids_stable(_enterprise, _site, _area, _line, _workcell))
              AND c.name = 'cycle_time_ms'
              AND c.avg_value > 0
              AND c.max_value < 300000;
            RETURN _result;
        END IF;

        _start_bucket := time_bucket('1 hour', _start_time);
        _end_bucket := time_bucket('1 hour', _end_time);

        SELECT total_sum / NULLIF(total_count, 0) / 1000.0 INTO _result
        FROM (
            SELECT SUM(s) AS total_sum, SUM(c) AS total_count
            FROM (
                SELECT c.sum_value AS s, c.sample_count AS c
                FROM cagg_tag_stats_hourly c
                WHERE c.asset_id IN (SELECT get_asset_ids_stable(_enterprise, _site, _area, _line, _workcell))
                  AND c.name = 'cycle_time_ms'
                  AND c.bucket >= _start_bucket + INTERVAL '1 hour'
                  AND c.bucket < _end_bucket
                  AND c.avg_value > 0
                  AND c.max_value < 300000
                UNION ALL
                SELECT SUM(t.value), COUNT(*)
                FROM tag t
                WHERE t.asset_id IN (SELECT get_asset_ids_stable(_enterprise, _site, _area, _line, _workcell))
                  AND t.name = 'cycle_time_ms'
                  AND t.value > 0 AND t.value < 300000
                  AND t.timestamp >= _start_time
                  AND t.timestamp < _start_bucket + INTERVAL '1 hour'
                UNION ALL
                SELECT SUM(t.value), COUNT(*)
                FROM tag t
                WHERE t.asset_id IN (SELECT get_asset_ids_stable(_enterprise, _site, _area, _line, _workcell))
                  AND t.name = 'cycle_time_ms'
                  AND t.value > 0 AND t.value < 300000
                  AND t.timestamp >= _end_bucket
                  AND t.timestamp <= _end_time
            ) combined
        ) totals;
        RETURN _result;
    EXCEPTION WHEN undefined_table THEN
        -- Fallback: raw tag table only (no cagg available)
        RETURN (
            SELECT AVG(t.value) / 1000.0
            FROM tag t
            WHERE t.asset_id IN (SELECT get_asset_ids_stable(_enterprise, _site, _area, _line, _workcell))
              AND t.name = 'cycle_time_ms'
              AND t.value > 0 AND t.value < 300000
              AND (_start_time IS NULL OR t.timestamp >= _start_time)
              AND (_end_time IS NULL OR t.timestamp <= _end_time)
        );
    END;
END;
$func$ LANGUAGE plpgsql STABLE;

DO $$ BEGIN
    EXECUTE 'GRANT EXECUTE ON FUNCTION get_cycle_time_avg(text,text,text,text,text,timestamptz,timestamptz) TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- Function: get_stop_count
-- Purpose: COUNT of machine_stops in range.
-- Usage: SELECT get_stop_count('E','S','A','L','',start,end);
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_stop_count(
    _enterprise text,
    _site text,
    _area text,
    _line text,
    _workcell text,
    _start_time timestamptz,
    _end_time timestamptz
) RETURNS integer AS $func$
BEGIN
    RETURN (
        SELECT COUNT(*)::integer
        FROM machine_stops ms
        WHERE ms.asset_id IN (SELECT get_asset_ids_stable(_enterprise, _site, _area, _line, _workcell))
          AND ms.start_time BETWEEN _start_time AND _end_time
    );
END;
$func$ LANGUAGE plpgsql STABLE;

DO $$ BEGIN
    EXECUTE 'GRANT EXECUTE ON FUNCTION get_stop_count(text,text,text,text,text,timestamptz,timestamptz) TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- Function: get_total_downtime_minutes
-- Purpose: SUM duration of machine_stops in range.
-- Usage: SELECT get_total_downtime_minutes('E','S','A','L','',start,end);
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_total_downtime_minutes(
    _enterprise text,
    _site text,
    _area text,
    _line text,
    _workcell text,
    _start_time timestamptz,
    _end_time timestamptz
) RETURNS numeric AS $func$
BEGIN
    RETURN COALESCE((
        SELECT SUM(EXTRACT(EPOCH FROM (COALESCE(ms.end_time, NOW()) - ms.start_time)) / 60.0)
        FROM machine_stops ms
        WHERE ms.asset_id IN (SELECT get_asset_ids_stable(_enterprise, _site, _area, _line, _workcell))
          AND ms.start_time >= _start_time
          AND ms.start_time <= _end_time
    ), 0);
END;
$func$ LANGUAGE plpgsql STABLE;

DO $$ BEGIN
    EXECUTE 'GRANT EXECUTE ON FUNCTION get_total_downtime_minutes(text,text,text,text,text,timestamptz,timestamptz) TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

-- =============================================================================
-- LAYER 2: COMPOSITE FUNCTIONS (call primitives)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Function: get_quality
-- Purpose: good / (good + scrap) * 100. Calls get_counter_delta internally.
-- Usage: SELECT get_quality('E','S','A','L','',start,end);
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_quality(
    _enterprise text,
    _site text,
    _area text,
    _line text,
    _workcell text,
    _start_time timestamptz,
    _end_time timestamptz
) RETURNS numeric AS $func$
DECLARE
    good_parts numeric;
    scrap_parts numeric;
    total numeric;
BEGIN
    good_parts := get_counter_delta(_enterprise, _site, _area, _line, _workcell, 'good_count', _start_time, _end_time);
    scrap_parts := get_counter_delta(_enterprise, _site, _area, _line, _workcell, 'scrap_count', _start_time, _end_time);
    total := good_parts + scrap_parts;

    IF total = 0 THEN
        RETURN 100;
    END IF;

    RETURN ROUND((good_parts * 100.0 / total)::numeric, 1);
END;
$func$ LANGUAGE plpgsql STABLE;

DO $$ BEGIN
    EXECUTE 'GRANT EXECUTE ON FUNCTION get_quality(text,text,text,text,text,timestamptz,timestamptz) TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- Function: get_performance
-- Purpose: (Actual Output × Ideal Cycle Time) / Runtime × 100, capped at 100.
--          Uses planned_cycle_time_ms from production_orders when available,
--          falls back to 5th percentile of actual cycle times.
-- Usage: SELECT get_performance('E','S','A','L','',start,end);
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_performance(
    _enterprise text,
    _site text,
    _area text,
    _line text,
    _workcell text,
    _start_time timestamptz,
    _end_time timestamptz
) RETURNS numeric AS $func$
DECLARE
    good_parts numeric;
    scrap_parts numeric;
    total_parts numeric;
    total_runtime numeric := 0;
    ideal_ct_sec numeric;
    _aid integer;
BEGIN
    good_parts := get_counter_delta(_enterprise, _site, _area, _line, _workcell, 'good_count', _start_time, _end_time);
    scrap_parts := get_counter_delta(_enterprise, _site, _area, _line, _workcell, 'scrap_count', _start_time, _end_time);
    total_parts := good_parts + scrap_parts;

    -- Sum runtime across matching assets (shift-constrained)
    FOR _aid IN SELECT get_asset_ids_stable(_enterprise, _site, _area, _line, _workcell)
    LOOP
        total_runtime := total_runtime + COALESCE(get_runtime_minutes(_aid, _start_time, _end_time), 0);
    END LOOP;

    IF total_runtime = 0 THEN
        RETURN 0;
    END IF;

    -- Try planned_cycle_time_ms from active production order
    SELECT po.planned_cycle_time_ms / 1000.0 INTO ideal_ct_sec
    FROM production_orders po
    WHERE po.asset_id IN (SELECT get_asset_ids_stable(_enterprise, _site, _area, _line, _workcell))
      AND po.status = 'IN_PROGRESS'
      AND po.planned_cycle_time_ms IS NOT NULL
      AND po.planned_cycle_time_ms > 0
    ORDER BY po.started_at DESC
    LIMIT 1;

    -- Fallback: 5th percentile of actual cycle times (best realistic speed)
    IF ideal_ct_sec IS NULL OR ideal_ct_sec = 0 THEN
        SELECT PERCENTILE_CONT(0.05) WITHIN GROUP (ORDER BY t.value) / 1000.0
        INTO ideal_ct_sec
        FROM tag t
        WHERE t.asset_id IN (SELECT get_asset_ids_stable(_enterprise, _site, _area, _line, _workcell))
          AND t.name = 'cycle_time_ms'
          AND t.value > 0
          AND t.value < 600000
          AND t.timestamp BETWEEN _start_time AND _end_time;
    END IF;

    IF ideal_ct_sec IS NULL OR ideal_ct_sec = 0 THEN
        RETURN 0;
    END IF;

    -- Performance = (total_parts × ideal_cycle_time) / runtime × 100
    RETURN LEAST(ROUND((total_parts * ideal_ct_sec * 100.0 / (total_runtime * 60))::numeric, 1), 100);
END;
$func$ LANGUAGE plpgsql STABLE;

DO $$ BEGIN
    EXECUTE 'GRANT EXECUTE ON FUNCTION get_performance(text,text,text,text,text,timestamptz,timestamptz) TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- Function: get_oee
-- Purpose: availability * performance * quality / 10000.
-- Usage: SELECT get_oee('E','S','A','L','',start,end);
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_oee(
    _enterprise text,
    _site text,
    _area text,
    _line text,
    _workcell text,
    _start_time timestamptz,
    _end_time timestamptz
) RETURNS numeric AS $func$
DECLARE
    avail numeric;
    perf numeric;
    qual numeric;
BEGIN
    avail := COALESCE(get_availability(_enterprise, _site, _area, _line, _workcell, _start_time, _end_time), 0);
    perf := COALESCE(get_performance(_enterprise, _site, _area, _line, _workcell, _start_time, _end_time), 0);
    qual := COALESCE(get_quality(_enterprise, _site, _area, _line, _workcell, _start_time, _end_time), 100);

    RETURN ROUND((avail * perf * qual / 10000.0)::numeric, 1);
END;
$func$ LANGUAGE plpgsql STABLE;

DO $$ BEGIN
    EXECUTE 'GRANT EXECUTE ON FUNCTION get_oee(text,text,text,text,text,timestamptz,timestamptz) TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

-- =============================================================================
-- LAYER 3: TABLE-RETURNING FUNCTIONS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Function: get_state_timeline
-- Purpose: State timeline data for Grafana state-timeline panel.
-- Usage: SELECT * FROM get_state_timeline('E','S','A','L','W',start,end);
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_state_timeline(
    _enterprise text,
    _site text,
    _area text,
    _line text,
    _workcell text,
    _start_time timestamptz,
    _end_time timestamptz
) RETURNS TABLE("time" timestamptz, value text, metric text) AS $func$
BEGIN
    RETURN QUERY
    SELECT
        t.timestamp AS time,
        t.value AS value,
        a.workcell::text AS metric
    FROM tag_string t
    JOIN asset a ON a.id = t.asset_id
    WHERE t.asset_id IN (SELECT get_asset_ids_stable(_enterprise, _site, _area, _line, _workcell))
      AND t.name = 'state'
      AND t.timestamp BETWEEN _start_time AND _end_time
    ORDER BY t.timestamp;
END;
$func$ LANGUAGE plpgsql STABLE;

DO $$ BEGIN
    EXECUTE 'GRANT EXECUTE ON FUNCTION get_state_timeline(text,text,text,text,text,timestamptz,timestamptz) TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- Function: get_tag_timeseries
-- Purpose: Simple tag value lookup for type-specific machine panels.
-- Usage: SELECT * FROM get_tag_timeseries(asset_id, 'tag_name', start, end);
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_tag_timeseries(
    _asset_id integer,
    _tag_name text,
    _start_time timestamptz,
    _end_time timestamptz
) RETURNS TABLE("time" timestamptz, value double precision) AS $func$
BEGIN
    RETURN QUERY
    SELECT t.timestamp AS time, t.value AS value
    FROM tag t
    WHERE t.asset_id = _asset_id
      AND t.name = _tag_name
      AND t.timestamp BETWEEN _start_time AND _end_time
    ORDER BY t.timestamp;
END;
$func$ LANGUAGE plpgsql STABLE;

DO $$ BEGIN
    EXECUTE 'GRANT EXECUTE ON FUNCTION get_tag_timeseries(integer,text,timestamptz,timestamptz) TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- Function: get_machine_status_table
-- Purpose: Current status of all matching machines.
-- Usage: SELECT * FROM get_machine_status_table('E','S','','','');
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_machine_status_table(
    _enterprise text,
    _site text,
    _area text,
    _line text,
    _workcell text
) RETURNS TABLE(
    machine text,
    state text,
    good_parts integer,
    scrap_parts integer,
    cycle_time numeric
) AS $func$
BEGIN
    RETURN QUERY
    WITH matching_assets AS (
        SELECT get_asset_ids_stable(_enterprise, _site, _area, _line, _workcell) AS id
    )
    SELECT
        a.workcell::text AS machine,
        COALESCE(ls.value, 'UNKNOWN')::text AS state,
        COALESCE(gp.value, 0)::integer AS good_parts,
        COALESCE(sp.value, 0)::integer AS scrap_parts,
        ROUND(COALESCE(ct.value, 0)::numeric, 1) AS cycle_time
    FROM asset a
    LEFT JOIN LATERAL (
        SELECT ts.value FROM tag_string ts
        WHERE ts.asset_id = a.id AND ts.name = 'state'
        ORDER BY ts.timestamp DESC LIMIT 1
    ) ls ON true
    LEFT JOIN LATERAL (
        SELECT t.value FROM tag t
        WHERE t.asset_id = a.id AND t.name = 'good_count'
        ORDER BY t.timestamp DESC LIMIT 1
    ) gp ON true
    LEFT JOIN LATERAL (
        SELECT t.value FROM tag t
        WHERE t.asset_id = a.id AND t.name = 'scrap_count'
        ORDER BY t.timestamp DESC LIMIT 1
    ) sp ON true
    LEFT JOIN LATERAL (
        SELECT t.value FROM tag t
        WHERE t.asset_id = a.id AND t.name = 'cycle_time_ms'
        ORDER BY t.timestamp DESC LIMIT 1
    ) ct ON true
    WHERE a.id IN (SELECT id FROM matching_assets)
      AND a.workcell != ''
    ORDER BY a.workcell;
END;
$func$ LANGUAGE plpgsql STABLE;

DO $$ BEGIN
    EXECUTE 'GRANT EXECUTE ON FUNCTION get_machine_status_table(text,text,text,text,text) TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- Function: get_stop_reasons_pareto
-- Purpose: Top stop reasons with counts and duration.
-- Usage: SELECT * FROM get_stop_reasons_pareto('E','S','A','L','',start,end,10);
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_stop_reasons_pareto(
    _enterprise text,
    _site text,
    _area text,
    _line text,
    _workcell text,
    _start_time timestamptz,
    _end_time timestamptz,
    _limit integer DEFAULT 10
) RETURNS TABLE(
    reason text,
    category text,
    stop_count bigint,
    duration_mins numeric,
    pct numeric
) AS $func$
BEGIN
    RETURN QUERY
    WITH stop_data AS (
        SELECT
            COALESCE(sr.name, 'Unspecified') AS reason,
            COALESCE(sr.category, 'Unknown') AS category,
            COUNT(*) AS stop_count,
            SUM(EXTRACT(EPOCH FROM (COALESCE(ms.end_time, NOW()) - ms.start_time)) / 60.0) AS total_duration_mins
        FROM machine_stops ms
        LEFT JOIN stop_reasons sr ON ms.stop_reason_id = sr.id
        WHERE ms.asset_id IN (SELECT get_asset_ids_stable(_enterprise, _site, _area, _line, _workcell))
          AND ms.start_time BETWEEN _start_time AND _end_time
        GROUP BY sr.name, sr.category
    ),
    totals AS (
        SELECT SUM(sd.stop_count) AS total_stops FROM stop_data sd
    )
    SELECT
        sd.reason::text,
        sd.category::text,
        sd.stop_count,
        ROUND(sd.total_duration_mins::numeric, 1) AS duration_mins,
        ROUND((sd.stop_count * 100.0 / NULLIF(t.total_stops, 0))::numeric, 1) AS pct
    FROM stop_data sd, totals t
    ORDER BY sd.stop_count DESC
    LIMIT _limit;
END;
$func$ LANGUAGE plpgsql STABLE;

DO $$ BEGIN
    EXECUTE 'GRANT EXECUTE ON FUNCTION get_stop_reasons_pareto(text,text,text,text,text,timestamptz,timestamptz,integer) TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- Function: get_output_vs_planned
-- Purpose: Actual good parts vs production order target, as percentage.
-- Usage: SELECT get_output_vs_planned('E','S','','L',start,end);
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_output_vs_planned(
    _enterprise text,
    _site text,
    _area text,
    _line text,
    _start_time timestamptz,
    _end_time timestamptz
) RETURNS numeric AS $func$
DECLARE
    actual numeric;
    target numeric;
BEGIN
    SELECT COALESCE(SUM(po.quantity_completed), 0),
           COALESCE(SUM(po.quantity), 0)
    INTO actual, target
    FROM production_orders po
    JOIN asset a ON a.id = po.asset_id
    WHERE a.enterprise = _enterprise
      AND a.site = _site
      AND (_line = '' OR a.line = _line OR a.line LIKE _line || '-%')
      AND (
        -- Include orders that started in the time range
        (po.started_at >= _start_time AND po.started_at <= _end_time)
        -- Include IN_PROGRESS orders (even if started_at is NULL)
        OR po.status = 'IN_PROGRESS'
      );

    IF target = 0 THEN
        RETURN NULL;
    END IF;

    RETURN ROUND((actual * 100.0 / target)::numeric, 1);
END;
$func$ LANGUAGE plpgsql STABLE;

DO $$ BEGIN
    EXECUTE 'GRANT EXECUTE ON FUNCTION get_output_vs_planned(text,text,text,text,timestamptz,timestamptz) TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- Success message
-- -----------------------------------------------------------------------------
DO $$ BEGIN
    RAISE NOTICE 'All views and functions created successfully';
    RAISE NOTICE 'Views: v_machine_current_state, v_active_issues, v_stop_reasons_pareto,';
    RAISE NOTICE '       v_order_progress, v_cycle_time_stats, v_production_summary,';
    RAISE NOTICE '       v_shift_production, v_oee_by_asset, v_availability,';
    RAISE NOTICE '       v_performance, v_quality';
    RAISE NOTICE 'Functions (legacy): get_production_delta, get_availability_pct';
    RAISE NOTICE 'Functions (Layer 1): get_counter_delta, get_availability, get_planned_minutes,';
    RAISE NOTICE '                     get_runtime_minutes, get_cycle_time_avg, get_stop_count,';
    RAISE NOTICE '                     get_total_downtime_minutes';
    RAISE NOTICE 'Functions (Layer 2): get_quality, get_performance, get_oee';
    RAISE NOTICE 'Functions (Layer 3): get_state_timeline, get_tag_timeseries,';
    RAISE NOTICE '                     get_machine_status_table, get_stop_reasons_pareto,';
    RAISE NOTICE '                     get_output_vs_planned';
END $$;
