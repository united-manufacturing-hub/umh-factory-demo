# Historian Bridge

The historian bridge (`timescale-bridge.yaml`) is a streaming dataflow that consumes messages from the Unified Namespace (UNS) and writes them to TimescaleDB. It is the primary ingestion path for all time-series data.

## Overview

```
UNS (NATS/MQTT)  -->  timescale-bridge  -->  tag (numeric values)
                                         -->  tag_string (string values)
```

**Input:** UNS topic pattern `^umh\.v1.*$`, consumer group `timescalebridgev1`

**Metadata requirement:** Only messages with `historian` metadata set to `"true"` are processed. All other messages are silently dropped by the first pipeline stage.

## Pipeline Stages

### 1. `filter_historian` — Metadata Filter

Checks the `historian` metadata field. Messages where `historian != "true"` are deleted (dropped). This ensures only data explicitly marked for historical storage reaches the database.

### 2. `validate_json` — JSON Validation

Catches malformed JSON payloads. Invalid messages are silently dropped via `.catch(deleted())`.

### 3. `parse_and_type` — Timestamp & Type Detection

- **Timestamp:** Converts `timestamp_ms` (milliseconds) to UTC. Falls back to `now()` if missing.
- **Type detection:** Inspects `value` field — numbers become `"number"`, everything else becomes `"string"`.
- **Tag name:** Extracted from `tag_name` metadata (defaults to `"unknown"`).

### 4. `convert_state_strings` — State Value Mapping (Optional)

This stage is specific to this demo implementation and not required for a general historian bridge. It converts `State` tags from string values to numeric codes so they can be stored in the `tag` table (numeric) instead of `tag_string`, enabling easier aggregation in views and continuous aggregates.

| String | Numeric |
|--------|---------|
| IDLE | 0 |
| STOPPED | 1 |
| RUNNING | 2 |
| FAULT | 3 |
| MAINTENANCE | 4 |

Unrecognized state strings are passed through as-is. After conversion, the type is changed to `"number"`.

### 5. `extract_location` — ISA-95 Hierarchy Parsing

Parses the UMH topic using regex to extract the ISA-95 hierarchy levels into metadata:

```
umh.v1.{enterprise}.{site}.{area}.{line}.{workcell}.{origin_id}._{contract}
```

Each level is stored as a separate metadata field (`enterprise`, `site`, `area`, `line`, `workcell`, `origin_id`).

### 6. Asset ID Resolution (3-step branch)

Resolves the UMH topic to an `asset.id` in the database:

1. **Cache lookup** — Checks `asset_id_cache` (in-memory) using the full UMH topic as key. On hit, sets `asset_id` from cached value.
2. **SQL insert-or-select** — On cache miss, runs an upsert query against the `asset` table: inserts a new row if the enterprise/site/area/line/workcell/origin_id combination doesn't exist, otherwise selects the existing ID.
3. **Cache write** — Stores the resolved `asset_id` back into the cache for future lookups.

## Output

A switch routes messages by type:

- **`type == "number"`** → `tag` table (numeric hypertable)
- **`type == "string"`** → `tag_string` table (string hypertable)

Both outputs use `sql_insert` with `ON CONFLICT DO NOTHING` and include init statements that create tables and hypertables if they don't exist.

### Columns Written

| Column | Source |
|--------|--------|
| `timestamp` | Parsed from `timestamp_ms` or `now()` |
| `asset_id` | Resolved via cache/SQL lookup |
| `name` | From `tag_name` metadata |
| `value` | Message value (DOUBLE PRECISION for tag, TEXT for tag_string) |
| `origin` | Set to `"timescale_bridge"` |

## Cache

**Resource:** `asset_id_cache` (in-memory)
- **TTL:** 24 hours
- **Compaction interval:** 60 seconds
- **Key:** Full UMH topic string
- **Value:** Asset ID (integer as string)

The cache eliminates repeated database lookups for the same topic. Since asset IDs are stable, a 24-hour TTL is sufficient.

## Full Template

Source: `templates/dataflows/timescale-bridge.yaml`

```yaml
# Timescale Bridge Dataflow
# Consumes historian data from UNS and writes to TimescaleDB (tag/tag_string tables)
# requires: historian

input:
  uns:
    consumer_group: timescalebridgev1
    umh_topic: ^umh\.v1.*$

pipeline:
  processors:
    - bloblang: |-
        let historian = meta("historian")
        root = match {
          $historian == "true" => root,
          _ => deleted()
        }
      label: filter_historian
    - bloblang: root = this.catch(deleted())
      label: validate_json
    - bloblang: |-
        # Convert timestamp
        root.timestamp = if this.timestamp_ms != null {
          (this.timestamp_ms / 1000).ts_format(tz: "UTC")
        } else {
          now().ts_format(tz: "UTC")
        }

        # Detect value type
        let val = this.value
        root.value = $val
        root.type = match $val.type() {
          "number" => "number",
          _ => "string"
        }

        # Get tag name from metadata
        root.name = meta("tag_name").or("unknown")
        root.origin = "timescale_bridge"
      label: parse_and_type
    - bloblang: |-
        # Convert State string values to numeric for consistent storage in tag table
        # Mapping: IDLE=0, STOPPED=1, RUNNING=2, FAULT=3, MAINTENANCE=4
        root = this
        root.value = if this.name == "State" && this.type == "string" {
          match this.value {
            "RUNNING" => 2,
            "IDLE" => 0,
            "STOPPED" => 1,
            "FAULT" => 3,
            "MAINTENANCE" => 4,
            _ => this.value
          }
        } else {
          this.value
        }
        root.type = if this.name == "State" && this.type == "string" { "number" } else { this.type }
      label: convert_state_strings
    - bloblang: |-
        let topic = meta("umh_topic")
        let matches = $topic.re_find_all_object("^umh\\.v1\\.(?P<enterprise>[\\w-]+)(?:\\.(?P<site>[\\w-]*))?(?:\\.(?P<area>[\\w-]*))?(?:\\.(?P<line>[\\w-]*))?(?:\\.(?P<workcell>[\\w-]*))?(?:\\.(?P<origin_id>[\\w-]*))?\\._(?P<contract>[\\w-]+)")

        let m = if $matches.length() > 0 { $matches.index(0) } else { {} }

        meta "enterprise" = $m.enterprise.or("")
        meta "site" = $m.site.or("")
        meta "area" = $m.area.or("")
        meta "line" = $m.line.or("")
        meta "workcell" = $m.workcell.or("")
        meta "origin_id" = $m.origin_id.or("")

        root = this
      label: extract_location
    - branch:
        processors:
          - try:
              - cache:
                  key: ${! meta("umh_topic") }
                  operator: get
                  resource: asset_id_cache
          - catch:
              - mapping: root = "CACHE_MISS"
        request_map: root = ""
        result_map: root.asset_id = if content() != "CACHE_MISS" && content() != "" && content() != "null" { content().number() } else { null }
    - branch:
        processors:
          - sql_raw:
              driver: postgres
              dsn: postgres://postgres:postgres@pgbouncer:5432/umh?sslmode=disable
              query: |
                WITH existing AS (
                  SELECT id FROM public.asset
                  WHERE enterprise = '${! meta("enterprise") }'
                    AND site = '${! meta("site").or("")}'
                    AND area = '${! meta("area").or("")}'
                    AND line = '${! meta("line").or("")}'
                    AND workcell = '${! meta("workcell").or("")}'
                    AND origin_id = '${! meta("origin_id").or("")}'
                ),
                inserted AS (
                  INSERT INTO public.asset (enterprise, site, area, line, workcell, origin_id)
                  SELECT '${! meta("enterprise") }', '${! meta("site").or("")}', '${! meta("area").or("")}', '${! meta("line").or("")}', '${! meta("workcell").or("")}', '${! meta("origin_id").or("")}'
                  WHERE NOT EXISTS (SELECT 1 FROM existing)
                  RETURNING id
                )
                SELECT id FROM inserted
                UNION ALL
                SELECT id FROM existing
                LIMIT 1;
              unsafe_dynamic_query: true
        request_map: root = if this.asset_id == null { "" } else { deleted() }
        result_map: root.asset_id = this.index(0).get("id")
    - branch:
        processors:
          - cache:
              key: ${! meta("umh_topic") }
              operator: set
              resource: asset_id_cache
              value: ${! content() }
        request_map: root = if this.asset_id != null { this.asset_id.string() } else { deleted() }
        result_map: root = root

output:
  switch:
    cases:
      - check: this.type == "number"
        output:
          sql_insert:
            args_mapping: |
              root = [this.asset_id, this.value, this.timestamp, this.name, this.origin]
            columns:
              - asset_id
              - value
              - timestamp
              - name
              - origin
            driver: postgres
            dsn: postgres://postgres:postgres@pgbouncer:5432/umh?sslmode=disable
            init_statement: |
              CREATE TABLE IF NOT EXISTS asset (
                id SERIAL PRIMARY KEY,
                enterprise VARCHAR(255) NOT NULL,
                site VARCHAR(255) DEFAULT '',
                area VARCHAR(255) DEFAULT '',
                line VARCHAR(255) DEFAULT '',
                workcell VARCHAR(255) DEFAULT '',
                origin_id VARCHAR(255) DEFAULT '',
                UNIQUE (enterprise, site, area, line, workcell, origin_id)
              );
              CREATE TABLE IF NOT EXISTS tag (
                timestamp TIMESTAMPTZ NOT NULL,
                asset_id INTEGER,
                name TEXT NOT NULL,
                value DOUBLE PRECISION,
                origin VARCHAR(255)
              );
              DO $$ BEGIN
                IF NOT EXISTS (SELECT 1 FROM timescaledb_information.hypertables WHERE hypertable_name = 'tag') THEN
                  PERFORM create_hypertable('tag', 'timestamp', chunk_time_interval => INTERVAL '1 day');
                END IF;
              END $$;
              ALTER TABLE tag SET (timescaledb.enable_columnstore = true, timescaledb.segmentby = 'asset_id, name', timescaledb.orderby = 'timestamp DESC');
              CREATE INDEX IF NOT EXISTS idx_tag_asset_name_time ON tag (asset_id, name, timestamp DESC);
            suffix: ON CONFLICT DO NOTHING
            table: tag
      - check: this.type == "string"
        output:
          sql_insert:
            args_mapping: |
              root = [this.asset_id, this.value, this.timestamp, this.name, this.origin]
            columns:
              - asset_id
              - value
              - timestamp
              - name
              - origin
            driver: postgres
            dsn: postgres://postgres:postgres@pgbouncer:5432/umh?sslmode=disable
            init_statement: |
              CREATE TABLE IF NOT EXISTS tag_string (
                timestamp TIMESTAMPTZ NOT NULL,
                asset_id INTEGER,
                name TEXT NOT NULL,
                value TEXT,
                origin VARCHAR(255)
              );
              DO $$ BEGIN
                IF NOT EXISTS (SELECT 1 FROM timescaledb_information.hypertables WHERE hypertable_name = 'tag_string') THEN
                  PERFORM create_hypertable('tag_string', 'timestamp', chunk_time_interval => INTERVAL '7 days');
                END IF;
              END $$;
              ALTER TABLE tag_string SET (timescaledb.enable_columnstore = true, timescaledb.segmentby = 'asset_id, name', timescaledb.orderby = 'timestamp DESC');
              CREATE INDEX IF NOT EXISTS idx_tag_string_asset_name_time ON tag_string (asset_id, name, timestamp DESC);
            suffix: ON CONFLICT DO NOTHING
            table: tag_string

cache_resources:
  - label: asset_id_cache
    memory:
      compaction_interval: 60s
      default_ttl: 24h
```
