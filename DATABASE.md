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

### Layer 2: Composites
These call Layer 1 primitives.

| Function | Returns | Description |
|----------|---------|-------------|
| `get_quality(E,S,A,L,W, start, end)` | NUMERIC | good / (good + scrap) * 100 |
| `get_performance(E,S,A,L,W, start, end)` | NUMERIC | (total_parts * ideal_ct) / runtime * 100 |
| `get_oee(E,S,A,L,W, start, end)` | NUMERIC | availability * performance * quality / 10000 |

### Layer 3: Table-returning
Return result sets for dashboard panels.

| Function | Returns | Description |
|----------|---------|-------------|
| `get_state_timeline(E,S,A,L,W, start, end)` | TABLE(time, value, metric) | State timeline for Grafana state-timeline panel |
| `get_tag_timeseries(asset_id, tag_name, start, end)` | TABLE(time, value) | Raw tag values for time-series panels |
| `get_machine_status_table(E,S,A,L,W)` | TABLE(machine, state, good_parts, scrap_parts, cycle_time) | Current machine status overview |
| `get_stop_reasons_pareto(E,S,A,L,W, start, end, limit)` | TABLE(reason, category, stop_count, duration_mins, pct) | Top stop reasons |
| `get_output_vs_planned(E,S,A,L, start, end)` | NUMERIC | Actual vs target production (%) |

### Legacy Functions
Kept for backward compatibility.

| Function | Description |
|----------|-------------|
| `get_production_delta(asset_id, tag_name, start, end)` | Single-asset counter delta |
| `get_availability_pct(asset_id, start, end)` | Count-based availability (not time-weighted) |

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
UNS (MQTT/NATS) → timescale-bridge.yaml → tag / tag_string (hypertables)
                                            ↓ (continuous aggregate refresh every 15 min)
                                      cagg_counter_hourly
                                      cagg_tag_stats_hourly
                                            ↓ (manual refresh)
                                      mv_runtime_hourly
                                            ↓ (queried by)
                                      Functions (get_counter_delta, get_runtime_minutes, etc.)
                                            ↓ (used by)
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
