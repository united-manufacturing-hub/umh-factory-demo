# Database Structure

TimescaleDB 2.25.2 on PostgreSQL 16. Uses Hypercore columnstore for time-series data and continuous aggregates for pre-computed metrics.

## Tables

### `asset`
Asset registry with ISA-95 hierarchy. Created by UMH Core.

| Column | Type | Description |
|--------|------|-------------|
| id | SERIAL PK | Auto-incrementing ID |
| enterprise | VARCHAR(255) | ISA-95 enterprise level |
| site | VARCHAR(255) | ISA-95 site level |
| area | VARCHAR(255) | ISA-95 area level |
| line | VARCHAR(255) | ISA-95 line level |
| workcell | VARCHAR(255) | ISA-95 workcell (machine) level |
| origin_id | VARCHAR(255) | Data source identifier |

**Unique constraint:** `(enterprise, site, area, line, workcell, origin_id)`

### `tag` (Hypertable)
Numeric time-series values for all assets. High-volume (~3.7M+ rows).

| Column | Type | Description |
|--------|------|-------------|
| timestamp | TIMESTAMPTZ | Event time |
| asset_id | INTEGER | FK to asset.id |
| name | TEXT | Tag name (e.g., `good_count`, `scrap_count`, `cycle_time_ms`, `State`) |
| value | DOUBLE PRECISION | Numeric value |
| origin | VARCHAR(255) | Data source origin |

- **Chunk interval:** 1 day
- **Hypercore columnstore:** `segmentby = 'asset_id, name'`, `orderby = 'timestamp DESC'`
- **Columnstore policy:** Chunks older than 7 days
- **Index:** `idx_tag_asset_name_time (asset_id, name, timestamp DESC)`

### `tag_string` (Hypertable)
String time-series values. Low-volume (state transitions, etc.).

| Column | Type | Description |
|--------|------|-------------|
| timestamp | TIMESTAMPTZ | Event time |
| asset_id | INTEGER | FK to asset.id |
| name | TEXT | Tag name (e.g., `state`) |
| value | TEXT | String value (e.g., `RUNNING`, `IDLE`, `STOPPED`) |
| origin | VARCHAR(255) | Data source origin |

- **Chunk interval:** 7 days
- **Hypercore columnstore:** `segmentby = 'asset_id, name'`, `orderby = 'timestamp DESC'`
- **Columnstore policy:** Chunks older than 7 days
- **Index:** `idx_tag_string_asset_name_time (asset_id, name, timestamp DESC)`

### `machine_stops`
Machine stop events with duration and classification.

| Column | Type | Description |
|--------|------|-------------|
| id | SERIAL PK | Stop event ID |
| asset_id | INTEGER | FK to asset.id |
| start_time | TIMESTAMPTZ | Stop start |
| end_time | TIMESTAMPTZ | Stop end (NULL = ongoing) |
| stop_reason_id | INTEGER | FK to stop_reasons.id |
| notes | TEXT | Operator notes |

Defined in `sql/stop-schema.sql`.

### `stop_reasons`
Catalog of stop reason codes.

| Column | Type | Description |
|--------|------|-------------|
| id | SERIAL PK | Reason ID |
| name | VARCHAR(255) UNIQUE | Reason name |
| category | VARCHAR(50) | Category (`Planned`, `Unplanned`, `Quality`) |
| description | TEXT | Detailed description |

### `shifts`
Shift schedule definitions.

| Column | Type | Description |
|--------|------|-------------|
| id | SERIAL PK | Shift ID |
| asset_id | INTEGER | FK to asset.id (NULL = all assets) |
| shift_name | VARCHAR(100) | Shift name (`Morning`, `Afternoon`, etc.) |
| start_time | TIMESTAMPTZ | Shift start |
| end_time | TIMESTAMPTZ | Shift end |

### `production_orders`
Production order tracking with planned vs actual quantities.

| Column | Type | Description |
|--------|------|-------------|
| id | SERIAL PK | Order ID |
| order_id | VARCHAR(100) | External order reference |
| asset_id | INTEGER | FK to asset.id |
| customer | VARCHAR(255) | Customer name |
| part_number | VARCHAR(100) | Part identifier |
| part_description | TEXT | Part description |
| quantity | INTEGER | Target quantity |
| quantity_completed | INTEGER | Completed parts |
| quantity_scrap | INTEGER | Scrapped parts |
| status | VARCHAR(50) | `PLANNED`, `IN_PROGRESS`, `COMPLETED` |
| planned_cycle_time_ms | INTEGER | Ideal cycle time in ms |
| started_at | TIMESTAMPTZ | Actual start |
| completed_at | TIMESTAMPTZ | Actual completion |
| due_date | TIMESTAMPTZ | Due date |

### `line_downtime_costs`
Cost per minute of downtime per production line.

### `part_scrap_costs`
Cost per scrapped part by part number.

---

## Continuous Aggregates

### `cagg_counter_hourly`
Hourly rollup of counter tags (good_count, scrap_count) with per-origin grouping for reset handling. This is the highest-impact optimization — powers all OEE, quality, and performance calculations.

| Column | Type | Description |
|--------|------|-------------|
| bucket | TIMESTAMPTZ | 1-hour time bucket |
| asset_id | INTEGER | Asset reference |
| name | TEXT | Tag name |
| origin | VARCHAR(255) | Data source (for counter reset handling) |
| sample_count | BIGINT | Number of data points in bucket |
| max_value | DOUBLE PRECISION | Maximum value in bucket |
| min_value | DOUBLE PRECISION | Minimum value in bucket |

- **Source:** `tag` hypertable
- **Refresh:** Every 15 minutes, `end_offset = 1 hour`
- **Hypercore:** `segmentby = 'asset_id, name, origin'`, `orderby = 'bucket DESC'`
- **Index:** `idx_cagg_counter_hourly_lookup (asset_id, name, bucket DESC)`
- **Used by:** `get_counter_delta()`, `get_quality()`, `get_performance()`, `get_oee()`

```sql
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
```

### `cagg_tag_stats_hourly`
Hourly statistical rollup for all numeric tags. Used for cycle time averages and general analytics.

| Column | Type | Description |
|--------|------|-------------|
| bucket | TIMESTAMPTZ | 1-hour time bucket |
| asset_id | INTEGER | Asset reference |
| name | TEXT | Tag name |
| sample_count | BIGINT | Number of data points |
| avg_value | DOUBLE PRECISION | Average value |
| min_value | DOUBLE PRECISION | Minimum value |
| max_value | DOUBLE PRECISION | Maximum value |
| sum_value | DOUBLE PRECISION | Sum of values (for weighted re-aggregation) |

- **Source:** `tag` hypertable
- **Refresh:** Every 15 minutes, `end_offset = 1 hour`
- **Hypercore:** `segmentby = 'asset_id, name'`, `orderby = 'bucket DESC'`
- **Index:** `idx_cagg_tag_stats_hourly_lookup (asset_id, name, bucket DESC)`
- **Used by:** `get_cycle_time_avg()`

```sql
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
```

---

## Materialized View

### `mv_runtime_hourly`
Pre-computed RUNNING minutes per asset per hour. Uses `LEAD()` window function on `tag_string` state events — a pattern that cannot be in a continuous aggregate.

| Column | Type | Description |
|--------|------|-------------|
| bucket | TIMESTAMPTZ | 1-hour time bucket |
| asset_id | INTEGER | Asset reference |
| running_minutes | NUMERIC | Minutes in RUNNING state |
| event_count | BIGINT | Total state change events |

- **Source:** `tag_string` WHERE name = 'state'
- **Unique index:** `idx_mv_runtime_hourly_pk (asset_id, bucket)` — enables `REFRESH CONCURRENTLY`
- **Refresh:** Manual via `REFRESH MATERIALIZED VIEW CONCURRENTLY mv_runtime_hourly`
- **Used by:** `get_runtime_minutes()`

```sql
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
```

---

## Views

| View | Purpose | Source Tables |
|------|---------|--------------|
| `v_machine_current_state` | Current state per machine (latest row) | `tag_string`, `asset` |
| `v_active_issues` | Currently ongoing (open) stops | `machine_stops`, `asset`, `stop_reasons` |
| `v_stop_reasons_pareto` | Pareto analysis of stop reasons | `machine_stops`, `stop_reasons` |
| `v_order_progress` | Production order status with completion % | `production_orders`, `asset` |
| `v_cycle_time_stats` | Cycle time stats (last 24h) | `tag`, `asset` |
| `v_production_summary` | Daily production totals (last 30 days) | `tag`, `asset` |
| `v_shift_production` | Production output by shift period | `shifts`, `tag`, `asset` |
| `v_oee_by_asset` | OEE breakdown per machine (last 24h) | `tag`, `tag_string`, `shifts`, `production_orders`, `asset` |
| `v_availability` | Availability metric per asset | `tag_string`, `shifts`, `asset` |
| `v_performance` | Performance metric per asset | `tag`, `shifts`, `production_orders`, `asset` |
| `v_quality` | Quality metric per asset | `tag`, `asset` |
| `machine_stops_with_details` | Stops with asset hierarchy and reason details | `machine_stops`, `asset`, `stop_reasons` |

### `v_machine_current_state`

Current state for each machine (single row per asset). Uses `DISTINCT ON` to get the latest state event.

```sql
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
WHERE a.workcell != ''
ORDER BY a.id, ts.timestamp DESC;
```

### `v_active_issues`

Currently active (ongoing) stops requiring attention. Filters for `end_time IS NULL`.

```sql
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
WHERE ms.end_time IS NULL;
```

### `v_stop_reasons_pareto`

Pareto analysis of stop reasons with count, duration, and cumulative percentage.

```sql
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
```

### `v_order_progress`

Production order status with completion percentage and on-time tracking.

```sql
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
```

### `v_cycle_time_stats`

Cycle time analysis by asset for the last 24 hours. Filters outliers > 600,000ms (10 min).

```sql
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
  AND t.value < 600000
  AND t.timestamp > NOW() - INTERVAL '24 hours'
GROUP BY t.asset_id, a.enterprise, a.site, a.area, a.line, a.workcell;
```

### `v_production_summary`

Daily production totals aggregated by asset (last 30 days). Calculates deltas using `LAG()` window function.

```sql
CREATE OR REPLACE VIEW v_production_summary AS
WITH daily_production AS (
    SELECT
        t.asset_id,
        DATE(t.timestamp) AS production_date,
        t.name,
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
```

### `v_shift_production`

Production output aggregated by shift period. Joins shifts with asset hierarchy and calculates per-shift deltas.

```sql
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
```

### `v_availability`

Availability metric per asset: runtime / planned production time (last 24h). Calculates RUNNING minutes using `LEAD()` window function over state changes, constrained to shift periods.

```sql
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
```

### `v_performance`

Performance metric per asset: (actual output x ideal cycle time) / runtime x 100 (last 24h). Uses `planned_cycle_time_ms` from production orders when available, falls back to 5th percentile of actual cycle times.

```sql
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
```

### `v_quality`

Quality metric per asset: good parts / total parts (last 24h). Returns 100% when no parts produced.

```sql
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
```

### `v_oee_by_asset`

OEE (Availability x Performance x Quality) per asset for the last 24 hours. Uses `get_runtime_minutes()` for shift-constrained runtime and `LATERAL` joins for per-asset calculations.

```sql
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
    -- Performance: (total_parts x ideal_cycle_time) / runtime
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
    -- OEE: Availability x Performance x Quality
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
```

### `machine_stops_with_details`

Convenient view joining stops with reason and category info. Defined in `sql/stop-schema.sql`.

```sql
CREATE OR REPLACE VIEW machine_stops_with_details AS
SELECT
    ms.id,
    ms.asset_id,
    ms.start_time,
    ms.end_time,
    EXTRACT(EPOCH FROM (COALESCE(ms.end_time, NOW()) - ms.start_time)) AS duration_seconds,
    ms.notes,
    ms.updated_at,
    ms.updated_by,
    sr.id AS reason_id,
    sr.name AS reason_name,
    sr.category AS category_name
FROM machine_stops ms
LEFT JOIN stop_reasons sr ON ms.stop_reason_id = sr.id;
```

---

## Functions

### Layer 0: Asset Helpers
Defined in `sql/init-functions.sql`.

| Function | Returns | Description |
|----------|---------|-------------|
| `get_asset_id(enterprise, site, area, line, workcell, origin_id)` | INTEGER | Exact match, returns NULL if not found |
| `get_asset_id_stable(...)` | INTEGER | Exact match, STABLE, throws error if not found |
| `get_asset_id_immutable(...)` | INTEGER | Exact match, IMMUTABLE |
| `get_asset_ids(enterprise, site, area, line, workcell)` | SETOF INTEGER | Flexible filtering (empty string = match all) |
| `get_asset_ids_stable(...)` | SETOF INTEGER | Same as above, STABLE |

#### `get_asset_id`

Exact match lookup, returns NULL if not found.

```sql
CREATE OR REPLACE FUNCTION get_asset_id(
    _enterprise text,
    _site text DEFAULT '',
    _area text DEFAULT '',
    _line text DEFAULT '',
    _workcell text DEFAULT '',
    _origin_id text DEFAULT ''
) RETURNS integer AS $func$
DECLARE
    result_id integer;
BEGIN
    SELECT id INTO result_id FROM asset
    WHERE enterprise = _enterprise
    AND site = _site
    AND area = _area
    AND line = _line
    AND workcell = _workcell
    AND origin_id = _origin_id
    LIMIT 1;
    RETURN result_id;
END;
$func$ LANGUAGE plpgsql;
```

#### `get_asset_id_stable`

Exact match lookup, STABLE volatility, throws error if not found.

```sql
CREATE OR REPLACE FUNCTION get_asset_id_stable(
    _enterprise text,
    _site text DEFAULT '',
    _area text DEFAULT '',
    _line text DEFAULT '',
    _workcell text DEFAULT '',
    _origin_id text DEFAULT ''
) RETURNS integer AS $func$
DECLARE
    result_id integer;
BEGIN
    SELECT id INTO result_id FROM asset
    WHERE enterprise = _enterprise
    AND site = _site
    AND area = _area
    AND line = _line
    AND workcell = _workcell
    AND origin_id = _origin_id
    LIMIT 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No asset found with the given parameters';
    END IF;
    RETURN result_id;
END;
$func$ LANGUAGE plpgsql STABLE;
```

#### `get_asset_id_immutable`

Exact match lookup, IMMUTABLE volatility, throws error if not found.

```sql
CREATE OR REPLACE FUNCTION get_asset_id_immutable(
    _enterprise text,
    _site text DEFAULT '',
    _area text DEFAULT '',
    _line text DEFAULT '',
    _workcell text DEFAULT '',
    _origin_id text DEFAULT ''
) RETURNS integer AS $func$
DECLARE
    result_id integer;
BEGIN
    SELECT id INTO result_id FROM asset
    WHERE enterprise = _enterprise
    AND site = _site
    AND area = _area
    AND line = _line
    AND workcell = _workcell
    AND origin_id = _origin_id
    LIMIT 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No asset found with the given parameters';
    END IF;
    RETURN result_id;
END;
$func$ LANGUAGE plpgsql IMMUTABLE;
```

#### `get_asset_ids`

Flexible multi-asset lookup. Empty string parameters match all values at that hierarchy level.

```sql
CREATE OR REPLACE FUNCTION get_asset_ids(
    _enterprise text,
    _site text DEFAULT '',
    _area text DEFAULT '',
    _line text DEFAULT '',
    _workcell text DEFAULT '',
    _origin_id text DEFAULT ''
)
RETURNS SETOF integer AS $func$
BEGIN
    RETURN QUERY
    SELECT id FROM asset
    WHERE enterprise = _enterprise
    AND (_site = '' OR site = _site)
    AND (_area = '' OR area = _area)
    AND (_line = '' OR line = _line)
    AND (_workcell = '' OR workcell = _workcell)
    AND (_origin_id = '' OR origin_id = _origin_id);
END;
$func$ LANGUAGE plpgsql;
```

#### `get_asset_ids_stable`

Same as `get_asset_ids` with STABLE volatility for better query optimization.

```sql
CREATE OR REPLACE FUNCTION get_asset_ids_stable(
    _enterprise text,
    _site text DEFAULT '',
    _area text DEFAULT '',
    _line text DEFAULT '',
    _workcell text DEFAULT '',
    _origin_id text DEFAULT ''
)
RETURNS SETOF integer AS $func$
BEGIN
    RETURN QUERY
    SELECT id FROM asset
    WHERE enterprise = _enterprise
    AND (_site = '' OR site = _site)
    AND (_area = '' OR area = _area)
    AND (_line = '' OR line = _line)
    AND (_workcell = '' OR workcell = _workcell)
    AND (_origin_id = '' OR origin_id = _origin_id);
END;
$func$ LANGUAGE plpgsql STABLE;
```

### Layer 1: Primitives
Defined in `sql/views.sql`. These are the building blocks.

| Function | Returns | Description | Data Source |
|----------|---------|-------------|-------------|
| `get_counter_delta(E,S,A,L,W, tag_name, start, end)` | NUMERIC | Counter delta with origin grouping | `cagg_counter_hourly` + raw `tag` for boundaries |
| `get_runtime_minutes(asset_id, start, end)` | NUMERIC | RUNNING minutes, shift-constrained | `mv_runtime_hourly` + raw `tag_string` for boundaries |
| `get_planned_minutes(start, end)` | NUMERIC | Sum of overlapping shift periods | `shifts` |
| `get_availability(E,S,A,L,W, start, end)` | NUMERIC | Runtime / planned production time (%) | Calls `get_runtime_minutes` + `get_planned_minutes` |
| `get_cycle_time_avg(E,S,A,L,W, start, end)` | NUMERIC | Average cycle time in seconds | `cagg_tag_stats_hourly` + raw `tag` for boundaries |
| `get_stop_count(E,S,A,L,W, start, end)` | INTEGER | Count of machine stops | `machine_stops` |
| `get_total_downtime_minutes(E,S,A,L,W, start, end)` | NUMERIC | Sum of stop durations | `machine_stops` |

#### `get_counter_delta`

Counter delta with per-origin grouping and reset handling. Uses `cagg_counter_hourly` for complete hours and raw `tag` for boundary hours. Falls back to raw-only if cagg doesn't exist.

```sql
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
```

#### `get_runtime_minutes`

RUNNING minutes for a single asset, shift-constrained. Uses `mv_runtime_hourly` for complete hours and raw `tag_string` for boundary hours.

```sql
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

    SELECT COALESCE(SUM(mv.running_minutes), 0) INTO _runtime
    FROM mv_runtime_hourly mv
    WHERE mv.asset_id = _asset_id
      AND mv.bucket >= _start_bucket + INTERVAL '1 hour'
      AND mv.bucket < _end_bucket;

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
          AND timestamp < _start_bucket + INTERVAL '1 hour'
          AND (timestamp >= _start_bucket OR TRUE)
    ) sc
    WHERE sc.value = 'RUNNING'
      AND sc.timestamp < LEAST(_start_bucket + INTERVAL '1 hour', _end_time)
      AND COALESCE(sc.next_ts, _end_time) > _start_time;

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

    RETURN LEAST(_runtime + _boundary_runtime, _planned);
END;
$func$ LANGUAGE plpgsql STABLE;
```

#### `get_planned_minutes`

Sum of overlapping shift periods within time range.

```sql
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
```

#### `get_availability`

Runtime / Planned Production Time (time-based, shift-constrained). Sums runtime across all matching assets and divides by planned time per asset.

```sql
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

    RETURN ROUND(LEAST(total_runtime * 100.0 / (planned * asset_count), 100)::numeric, 1);
END;
$func$ LANGUAGE plpgsql STABLE;
```

#### `get_cycle_time_avg`

Average cycle time in seconds. Uses `cagg_tag_stats_hourly` for complete hours, raw `tag` for boundaries. Falls back to raw-only if cagg doesn't exist.

```sql
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
```

#### `get_stop_count`

Count of machine stops in time range.

```sql
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
```

#### `get_total_downtime_minutes`

Sum of stop durations in time range.

```sql
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
```

### Layer 2: Composites
These call Layer 1 primitives.

| Function | Returns | Description |
|----------|---------|-------------|
| `get_quality(E,S,A,L,W, start, end)` | NUMERIC | good / (good + scrap) * 100 |
| `get_performance(E,S,A,L,W, start, end)` | NUMERIC | (total_parts * ideal_ct) / runtime * 100 |
| `get_oee(E,S,A,L,W, start, end)` | NUMERIC | availability * performance * quality / 10000 |

#### `get_quality`

good / (good + scrap) * 100. Calls `get_counter_delta` internally. Returns 100 when no parts produced.

```sql
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
```

#### `get_performance`

(Actual Output x Ideal Cycle Time) / Runtime x 100, capped at 100. Uses `planned_cycle_time_ms` from production orders when available, falls back to 5th percentile of actual cycle times.

```sql
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

    FOR _aid IN SELECT get_asset_ids_stable(_enterprise, _site, _area, _line, _workcell)
    LOOP
        total_runtime := total_runtime + COALESCE(get_runtime_minutes(_aid, _start_time, _end_time), 0);
    END LOOP;

    IF total_runtime = 0 THEN
        RETURN 0;
    END IF;

    SELECT po.planned_cycle_time_ms / 1000.0 INTO ideal_ct_sec
    FROM production_orders po
    WHERE po.asset_id IN (SELECT get_asset_ids_stable(_enterprise, _site, _area, _line, _workcell))
      AND po.status = 'IN_PROGRESS'
      AND po.planned_cycle_time_ms IS NOT NULL
      AND po.planned_cycle_time_ms > 0
    ORDER BY po.started_at DESC
    LIMIT 1;

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

    RETURN LEAST(ROUND((total_parts * ideal_ct_sec * 100.0 / (total_runtime * 60))::numeric, 1), 100);
END;
$func$ LANGUAGE plpgsql STABLE;
```

#### `get_oee`

availability * performance * quality / 10000. Calls all three Layer 1/2 functions.

```sql
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
```

### Layer 3: Table-returning
Return result sets for dashboard panels.

| Function | Returns | Description |
|----------|---------|-------------|
| `get_state_timeline(E,S,A,L,W, start, end)` | TABLE(time, value, metric) | State timeline for Grafana state-timeline panel |
| `get_tag_timeseries(asset_id, tag_name, start, end)` | TABLE(time, value) | Raw tag values for time-series panels |
| `get_machine_status_table(E,S,A,L,W)` | TABLE(machine, state, good_parts, scrap_parts, cycle_time) | Current machine status overview |
| `get_stop_reasons_pareto(E,S,A,L,W, start, end, limit)` | TABLE(reason, category, stop_count, duration_mins, pct) | Top stop reasons |
| `get_output_vs_planned(E,S,A,L, start, end)` | NUMERIC | Actual vs target production (%) |

#### `get_state_timeline`

State timeline data for Grafana state-timeline panel. Returns workcell name as metric for multi-machine display.

```sql
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
```

#### `get_tag_timeseries`

Simple tag value lookup for time-series panels.

```sql
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
```

#### `get_machine_status_table`

Current status of all matching machines. Shows latest state, good/scrap parts, and cycle time.

```sql
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
      AND a.workcell != ''
    ORDER BY a.workcell;
END;
$func$ LANGUAGE plpgsql STABLE;
```

#### `get_stop_reasons_pareto`

Top stop reasons with counts and duration for Pareto analysis.

```sql
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
```

#### `get_output_vs_planned`

Actual good parts vs production order target as percentage.

```sql
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
        (po.started_at >= _start_time AND po.started_at <= _end_time)
        OR po.status = 'IN_PROGRESS'
      );

    IF target = 0 THEN
        RETURN NULL;
    END IF;

    RETURN ROUND((actual * 100.0 / target)::numeric, 1);
END;
$func$ LANGUAGE plpgsql STABLE;
```

### Legacy Functions
Kept for backward compatibility.

| Function | Description |
|----------|-------------|
| `get_production_delta(asset_id, tag_name, start, end)` | Single-asset counter delta |
| `get_availability_pct(asset_id, start, end)` | Count-based availability (not time-weighted) |

#### `get_production_delta`

Single-asset counter delta. Superseded by `get_counter_delta` which supports multi-asset and per-origin grouping.

```sql
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
    SELECT value INTO start_value
    FROM tag
    WHERE asset_id = _asset_id
      AND name = _tag_name
      AND timestamp < _start_time
    ORDER BY timestamp DESC
    LIMIT 1;

    SELECT value INTO end_value
    FROM tag
    WHERE asset_id = _asset_id
      AND name = _tag_name
      AND timestamp <= _end_time
    ORDER BY timestamp DESC
    LIMIT 1;

    RETURN GREATEST(COALESCE(end_value, 0) - COALESCE(start_value, 0), 0);
END;
$func$ LANGUAGE plpgsql STABLE;
```

#### `get_availability_pct`

Count-based availability (not time-weighted). Superseded by `get_availability` which uses shift-constrained runtime.

```sql
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
```

---

## SQL Files

| File | Purpose | When Run |
|------|---------|----------|
| `sql/init-functions.sql` | Asset helper functions (`get_asset_id*`, `get_asset_ids*`) | Builder Phase 2 (Step 1) |
| `sql/stop-schema.sql` | Tables: `machine_stops`, `stop_reasons`, `shifts`, `production_orders`, `line_downtime_costs`, `part_scrap_costs` | Builder Phase 2 (Step 1) |
| `sql/migrate-to-hypertables.sql` | Hypertable conversion, Hypercore, continuous aggregates, policies | Manual migration for existing deployments |
| `sql/views.sql` | All views, materialized views, and functions | Builder Phase 2 (Step 3) |

## Data Flow

```
UNS (MQTT/NATS) -> timescale-bridge.yaml -> tag / tag_string (hypertables)
                                            | (continuous aggregate refresh every 15 min)
                                      cagg_counter_hourly
                                      cagg_tag_stats_hourly
                                            | (manual refresh)
                                      mv_runtime_hourly
                                            | (queried by)
                                      Functions (get_counter_delta, get_runtime_minutes, etc.)
                                            | (used by)
                                      Views (v_oee_by_asset, etc.) + Grafana Dashboards
```

## Query Performance Strategy

| Query Pattern | Before | After |
|---------------|--------|-------|
| Counter deltas (good/scrap) | Full scan of `tag` table (~3.7M rows) | `cagg_counter_hourly` (~4K hourly buckets) + 2 boundary hours of raw data |
| Cycle time average | Full scan of `tag` with outlier filter | `cagg_tag_stats_hourly` weighted average + 2 boundary hours |
| Runtime minutes | `LEAD()` window over entire `tag_string` per asset | `mv_runtime_hourly` pre-computed + 2 boundary hours |
| State timeline | Sequential scan | Index scan via `idx_tag_string_asset_name_time` |
| OEE calculation | 4x full table scans + LEAD() per asset | Uses all three pre-aggregated sources above |
