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
    WHERE name = 'state'
      AND timestamp > NOW() - INTERVAL '24 hours'
    GROUP BY asset_id
),
parts_delta AS (
    SELECT
        asset_id,
        origin,
        MAX(value) FILTER (WHERE name = 'good_count' AND timestamp <= NOW()) AS end_good,
        MAX(value) FILTER (WHERE name = 'good_count' AND timestamp < NOW() - INTERVAL '24 hours') AS start_good,
        MAX(value) FILTER (WHERE name = 'scrap_count' AND timestamp <= NOW()) AS end_scrap,
        MAX(value) FILTER (WHERE name = 'scrap_count' AND timestamp < NOW() - INTERVAL '24 hours') AS start_scrap
    FROM tag
    WHERE name IN ('good_count', 'scrap_count')
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
    WHERE name = 'cycle_time_ms'
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
BEGIN
    RETURN COALESCE((
        SELECT SUM(GREATEST(COALESCE(end_v, 0) - COALESCE(start_v, 0), 0))
        FROM (
            SELECT
                asset_id,
                origin,
                MAX(value) FILTER (WHERE timestamp <= _end_time) AS end_v,
                MAX(value) FILTER (WHERE timestamp < _start_time) AS start_v
            FROM tag
            WHERE name = _tag_name
              AND asset_id IN (SELECT get_asset_ids_stable(_enterprise, _site, _area, _line, _workcell))
            GROUP BY asset_id, origin
        ) sub
    ), 0);
END;
$func$ LANGUAGE plpgsql STABLE;

DO $$ BEGIN
    EXECUTE 'GRANT EXECUTE ON FUNCTION get_counter_delta(text,text,text,text,text,text,timestamptz,timestamptz) TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- Function: get_availability
-- Purpose: RUNNING count / total count from tag_string. Multi-asset aware.
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
    running_count bigint;
    total_count bigint;
BEGIN
    SELECT
        COUNT(*) FILTER (WHERE value = 'RUNNING'),
        COUNT(*)
    INTO running_count, total_count
    FROM tag_string
    WHERE asset_id IN (SELECT get_asset_ids_stable(_enterprise, _site, _area, _line, _workcell))
      AND name = 'state'
      AND timestamp BETWEEN _start_time AND _end_time;

    IF total_count = 0 THEN
        RETURN NULL;
    END IF;

    RETURN ROUND((running_count * 100.0 / total_count)::numeric, 1);
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
BEGIN
    RETURN (
        WITH shift_periods AS (
            SELECT
                GREATEST(s.start_time, _start_time) AS period_start,
                LEAST(s.end_time, _end_time) AS period_end
            FROM shifts s
            WHERE s.start_time < _end_time
              AND s.end_time > _start_time
        ),
        state_changes AS (
            SELECT
                timestamp,
                value,
                LEAD(timestamp) OVER (ORDER BY timestamp) AS next_ts
            FROM tag_string
            WHERE name = 'state'
              AND asset_id = _asset_id
        )
        SELECT CASE WHEN (SELECT COUNT(*) FROM shift_periods) > 0
            THEN COALESCE(SUM(
                EXTRACT(EPOCH FROM (
                    LEAST(COALESCE(sc.next_ts, sp.period_end), sp.period_end) -
                    GREATEST(sc.timestamp, sp.period_start)
                )) / 60.0
            ), 0)
            ELSE NULL
        END
        FROM state_changes sc, shift_periods sp
        WHERE sc.value = 'RUNNING'
          AND sc.timestamp < sp.period_end
          AND COALESCE(sc.next_ts, sp.period_end) > sp.period_start
    );
END;
$func$ LANGUAGE plpgsql STABLE;

DO $$ BEGIN
    EXECUTE 'GRANT EXECUTE ON FUNCTION get_runtime_minutes(integer,timestamptz,timestamptz) TO grafanareader';
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
BEGIN
    RETURN (
        SELECT AVG(t.value) / 1000.0
        FROM tag t
        WHERE t.asset_id IN (SELECT get_asset_ids_stable(_enterprise, _site, _area, _line, _workcell))
          AND t.name = 'cycle_time_ms'
          AND t.value > 0
          AND t.value < 300000
          AND (_start_time IS NULL OR t.timestamp >= _start_time)
          AND (_end_time IS NULL OR t.timestamp <= _end_time)
    );
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
-- Purpose: total_parts / theoretical_max * 100, capped at 100.
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
    running_count bigint;
    total_count bigint;
    avg_ct numeric;
    running_seconds numeric;
    theoretical_max numeric;
BEGIN
    good_parts := get_counter_delta(_enterprise, _site, _area, _line, _workcell, 'good_count', _start_time, _end_time);
    scrap_parts := get_counter_delta(_enterprise, _site, _area, _line, _workcell, 'scrap_count', _start_time, _end_time);
    total_parts := good_parts + scrap_parts;

    SELECT
        COUNT(*) FILTER (WHERE value = 'RUNNING'),
        COUNT(*)
    INTO running_count, total_count
    FROM tag_string
    WHERE asset_id IN (SELECT get_asset_ids_stable(_enterprise, _site, _area, _line, _workcell))
      AND name = 'state'
      AND timestamp BETWEEN _start_time AND _end_time;

    IF total_count = 0 OR running_count = 0 THEN
        RETURN 0;
    END IF;

    avg_ct := get_cycle_time_avg(_enterprise, _site, _area, _line, _workcell, _start_time, _end_time);
    IF avg_ct IS NULL OR avg_ct = 0 THEN
        RETURN 0;
    END IF;

    -- Running seconds = proportion of time range that was RUNNING
    running_seconds := running_count * 1.0 / total_count * EXTRACT(EPOCH FROM (_end_time - _start_time));
    -- Theoretical max = running_seconds / cycle_time_seconds
    theoretical_max := running_seconds / avg_ct;

    IF theoretical_max = 0 THEN
        RETURN 0;
    END IF;

    RETURN LEAST(ROUND((total_parts * 100.0 / theoretical_max)::numeric, 1), 100);
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
    ),
    latest_state AS (
        SELECT DISTINCT ON (ts.asset_id)
            ts.asset_id,
            ts.value AS state
        FROM tag_string ts
        WHERE ts.asset_id IN (SELECT id FROM matching_assets)
          AND ts.name = 'state'
        ORDER BY ts.asset_id, ts.timestamp DESC
    ),
    latest_parts AS (
        SELECT
            t.asset_id,
            MAX(t.value) FILTER (WHERE t.name = 'good_count') AS good_parts,
            MAX(t.value) FILTER (WHERE t.name = 'scrap_count') AS scrap_parts,
            (SELECT t2.value FROM tag t2 WHERE t2.asset_id = t.asset_id AND t2.name = 'cycle_time_ms' ORDER BY t2.timestamp DESC LIMIT 1) AS cycle_time
        FROM tag t
        WHERE t.asset_id IN (SELECT id FROM matching_assets)
          AND t.name IN ('good_count', 'scrap_count')
        GROUP BY t.asset_id
    )
    SELECT
        a.workcell::text AS machine,
        COALESCE(ls.state, 'UNKNOWN')::text AS state,
        COALESCE(lp.good_parts, 0)::integer AS good_parts,
        COALESCE(lp.scrap_parts, 0)::integer AS scrap_parts,
        ROUND(COALESCE(lp.cycle_time, 0)::numeric, 1) AS cycle_time
    FROM asset a
    LEFT JOIN latest_state ls ON ls.asset_id = a.id
    LEFT JOIN latest_parts lp ON lp.asset_id = a.id
    WHERE a.id IN (SELECT id FROM matching_assets)
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
    actual := get_counter_delta(_enterprise, _site, _area, _line, '', 'good_count', _start_time, _end_time);

    SELECT COALESCE(SUM(po.quantity), 1000) INTO target
    FROM production_orders po
    JOIN asset a ON a.id = po.asset_id
    WHERE a.enterprise = _enterprise
      AND a.site = _site
      AND (_line = '' OR a.line = _line)
      AND po.status IN ('IN_PROGRESS', 'RELEASED');

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
    RAISE NOTICE '       v_shift_production, v_oee_by_asset';
    RAISE NOTICE 'Functions (legacy): get_production_delta, get_availability_pct';
    RAISE NOTICE 'Functions (Layer 1): get_counter_delta, get_availability, get_planned_minutes,';
    RAISE NOTICE '                     get_runtime_minutes, get_cycle_time_avg, get_stop_count,';
    RAISE NOTICE '                     get_total_downtime_minutes';
    RAISE NOTICE 'Functions (Layer 2): get_quality, get_performance, get_oee';
    RAISE NOTICE 'Functions (Layer 3): get_state_timeline, get_tag_timeseries,';
    RAISE NOTICE '                     get_machine_status_table, get_stop_reasons_pareto,';
    RAISE NOTICE '                     get_output_vs_planned';
END $$;
