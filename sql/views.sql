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
LEFT JOIN tag_string ts ON ts.asset_id = a.id AND ts.name = 'State'
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
WHERE ms.end_time IS NULL  -- Only ongoing stops
ORDER BY ms.start_time ASC;  -- Oldest first (longest duration)

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
WHERE t.name = 'CycleTime'
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
-- Usage: SELECT get_production_delta(asset_id, 'GoodParts', start_time, end_time);
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
      AND name = 'State'
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
    WHERE t.name IN ('GoodParts', 'ScrapParts')
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
        SUM(CASE WHEN name = 'GoodParts' THEN GREATEST(COALESCE(end_of_day_value, 0) - COALESCE(prev_value, 0), 0) ELSE 0 END) AS good_parts,
        SUM(CASE WHEN name = 'ScrapParts' THEN GREATEST(COALESCE(end_of_day_value, 0) - COALESCE(prev_value, 0), 0) ELSE 0 END) AS scrap_parts
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
        COALESCE((SELECT value FROM tag WHERE asset_id = sp.asset_id AND name = 'GoodParts' AND timestamp <= sp.end_time ORDER BY timestamp DESC LIMIT 1), 0) -
        COALESCE((SELECT value FROM tag WHERE asset_id = sp.asset_id AND name = 'GoodParts' AND timestamp < sp.start_time ORDER BY timestamp DESC LIMIT 1), 0),
        0
    )), 0) AS good_parts,
    COALESCE(SUM(GREATEST(
        COALESCE((SELECT value FROM tag WHERE asset_id = sp.asset_id AND name = 'ScrapParts' AND timestamp <= sp.end_time ORDER BY timestamp DESC LIMIT 1), 0) -
        COALESCE((SELECT value FROM tag WHERE asset_id = sp.asset_id AND name = 'ScrapParts' AND timestamp < sp.start_time ORDER BY timestamp DESC LIMIT 1), 0),
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
-- View: v_oee_by_asset
-- Purpose: OEE (Availability x Performance x Quality) calculation per asset
-- Note: Calculates OEE for the last 24 hours by default
-- Usage: SELECT * FROM v_oee_by_asset WHERE line = 'line1';
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_oee_by_asset AS
WITH state_counts AS (
    SELECT
        asset_id,
        COUNT(*) AS total_states,
        COUNT(*) FILTER (WHERE value = 'RUNNING') AS running_count
    FROM tag_string
    WHERE name = 'State'
      AND timestamp > NOW() - INTERVAL '24 hours'
    GROUP BY asset_id
),
parts_delta AS (
    SELECT
        asset_id,
        origin,
        MAX(value) FILTER (WHERE name = 'GoodParts' AND timestamp <= NOW()) AS end_good,
        MAX(value) FILTER (WHERE name = 'GoodParts' AND timestamp < NOW() - INTERVAL '24 hours') AS start_good,
        MAX(value) FILTER (WHERE name = 'ScrapParts' AND timestamp <= NOW()) AS end_scrap,
        MAX(value) FILTER (WHERE name = 'ScrapParts' AND timestamp < NOW() - INTERVAL '24 hours') AS start_scrap
    FROM tag
    WHERE name IN ('GoodParts', 'ScrapParts')
      AND timestamp > NOW() - INTERVAL '25 hours'  -- Include buffer for start values
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
cycle_times AS (
    SELECT
        asset_id,
        AVG(value) / 1000.0 AS avg_cycle_time_sec  -- Convert ms to seconds
    FROM tag
    WHERE name = 'CycleTime'
      AND value > 0
      AND value < 600000
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
    -- Availability: % of time in RUNNING state
    ROUND((sc.running_count * 100.0 / NULLIF(sc.total_states, 0))::numeric, 1) AS availability_pct,
    -- Performance: actual output vs theoretical max during running time
    ROUND(LEAST(
        CASE
            WHEN sc.running_count > 0 AND ct.avg_cycle_time_sec > 0 THEN
                ((pt.good_parts + pt.scrap_parts) * ct.avg_cycle_time_sec * 100.0) /
                NULLIF((sc.running_count * 1.0 / NULLIF(sc.total_states, 0) * 86400), 0)  -- 24h in seconds
            ELSE 0
        END,
        100
    )::numeric, 1) AS performance_pct,
    -- Quality: good parts / total parts
    ROUND(
        CASE
            WHEN (pt.good_parts + pt.scrap_parts) > 0
            THEN (pt.good_parts * 100.0 / (pt.good_parts + pt.scrap_parts))
            ELSE 100
        END::numeric, 1
    ) AS quality_pct,
    -- OEE: Availability x Performance x Quality
    ROUND((
        (COALESCE(sc.running_count * 100.0 / NULLIF(sc.total_states, 0), 0) / 100.0) *
        (LEAST(COALESCE(
            CASE
                WHEN sc.running_count > 0 AND ct.avg_cycle_time_sec > 0 THEN
                    ((pt.good_parts + pt.scrap_parts) * ct.avg_cycle_time_sec * 100.0) /
                    NULLIF((sc.running_count * 1.0 / NULLIF(sc.total_states, 0) * 86400), 0)
                ELSE 0
            END,
            0
        ), 100) / 100.0) *
        (COALESCE(
            CASE
                WHEN (pt.good_parts + pt.scrap_parts) > 0
                THEN (pt.good_parts * 100.0 / (pt.good_parts + pt.scrap_parts))
                ELSE 100
            END,
            100
        ) / 100.0) * 100
    )::numeric, 1) AS oee_pct,
    pt.good_parts,
    pt.scrap_parts,
    ct.avg_cycle_time_sec
FROM asset a
LEFT JOIN state_counts sc ON sc.asset_id = a.id
LEFT JOIN parts_totals pt ON pt.asset_id = a.id
LEFT JOIN cycle_times ct ON ct.asset_id = a.id
WHERE a.workcell != '';  -- Only workcell-level assets

-- Grant permissions
DO $$ BEGIN
    EXECUTE 'GRANT SELECT ON v_oee_by_asset TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- Success message
-- -----------------------------------------------------------------------------
DO $$ BEGIN
    RAISE NOTICE 'All views and functions created successfully';
    RAISE NOTICE 'Views: v_machine_current_state, v_active_issues, v_stop_reasons_pareto,';
    RAISE NOTICE '       v_order_progress, v_cycle_time_stats, v_production_summary,';
    RAISE NOTICE '       v_shift_production, v_oee_by_asset';
    RAISE NOTICE 'Functions: get_production_delta, get_availability_pct';
END $$;
