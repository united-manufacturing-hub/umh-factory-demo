#!/bin/bash
# builder-post-init.sh - Phase 2: Post-init after docker compose up
#
# This script runs INSIDE the builder container AFTER it has been
# connected to the compose network. It can reach services by name:
#   pgbouncer:5432, grafana:3000, etc.
#
# Env vars expected:
#   TEMPLATES_DIR   - path to downloaded repo root
#   SCRIPTS_DIR     - path to downloaded repo scripts/
#   HISTORY_DAYS    - days of historical data to generate (0 = skip)
#   PORT_GRAFANA    - host port for Grafana (for display only)
#   PORT_NGINX      - host port for Nginx (for display only)

set -euo pipefail

WORK_DIR="/workspace"
LOG_FILE="${WORK_DIR}/builder-post-init.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

HISTORY_DAYS="${HISTORY_DAYS:-0}"
PORT_GRAFANA="${PORT_GRAFANA:-8080}"
NO_GRAFANA="${NO_GRAFANA:-false}"
NO_HISTORIAN="${NO_HISTORIAN:-false}"

echo -e "${BLUE}=== Builder Phase 2: Post-Init ===${NC}"
echo ""

# ============================================================
# Health check helpers
# ============================================================

# TimescaleDB readiness via pgbouncer (max 120s)
wait_for_timescaledb() {
    echo "  Waiting for TimescaleDB (via pgbouncer)..."
    for i in $(seq 1 120); do
        if pg_isready -h pgbouncer -p 5432 -U postgres -q 2>/dev/null; then
            echo -e "${GREEN}  ✓ TimescaleDB is ready${NC}"
            return 0
        fi
        sleep 1
    done
    echo -e "${RED}  Error: TimescaleDB did not become ready within 120s${NC}"
    return 1
}

# Grafana readiness (max 120s)
wait_for_grafana() {
    echo "  Waiting for Grafana..."
    for i in $(seq 1 120); do
        if curl -sf grafana:3000/api/health 2>/dev/null | grep -q "ok"; then
            echo -e "${GREEN}  ✓ Grafana is ready${NC}"
            return 0
        fi
        sleep 2
    done
    echo -e "${RED}  Error: Grafana did not become ready within 120s${NC}"
    return 1
}

# UMH Core assets created (max 120s)
wait_for_assets() {
    echo "  Waiting for UMH Core to create assets..."
    for i in $(seq 1 60); do
        count=$(PGPASSWORD=postgres psql -h pgbouncer -U postgres -d umh -tAc "SELECT count(*) FROM asset" 2>/dev/null || echo "0")
        if [ "$count" -gt 0 ]; then
            echo -e "${GREEN}  ✓ Assets created ($count found)${NC}"
            return 0
        fi
        sleep 2
    done
    echo -e "${YELLOW}  Warning: Assets not found after 120s${NC}"
    return 1
}

# ============================================================
# Step 1: Initialize SQL schema
# ============================================================
if [ "$NO_HISTORIAN" = "true" ]; then
    echo -e "${BLUE}Step 1: Skipping SQL schema (--no-historian)${NC}"
else
    echo -e "${BLUE}Step 1: Initializing SQL schema...${NC}"

    if ! wait_for_timescaledb; then
        echo -e "${RED}  Cannot proceed without TimescaleDB${NC}"
        exit 1
    fi

    # Wait a moment for DB to be fully ready
    sleep 2

    # Run init-functions.sql first
    if [ -f "$WORK_DIR/sql/init-functions.sql" ]; then
        PGPASSWORD=postgres psql -h pgbouncer -U postgres -d umh < "$WORK_DIR/sql/init-functions.sql" 2>/dev/null || true
        echo -e "${GREEN}  ✓ Asset helper functions initialized${NC}"
    fi

    # Run stop schema
    if [ -f "$WORK_DIR/sql/stop-schema.sql" ]; then
        PGPASSWORD=postgres psql -h pgbouncer -U postgres -d umh < "$WORK_DIR/sql/stop-schema.sql" 2>/dev/null || true
        echo -e "${GREEN}  ✓ SQL schema initialized${NC}"
    fi

    # Run hypertable migration (creates continuous aggregates needed by views.sql)
    if [ -f "$WORK_DIR/sql/migrate-to-hypertables.sql" ]; then
        PGPASSWORD=postgres psql -h pgbouncer -U postgres -d umh < "$WORK_DIR/sql/migrate-to-hypertables.sql" 2>/dev/null || true
        echo -e "${GREEN}  ✓ Hypertables and continuous aggregates initialized${NC}"
    fi
fi

# ============================================================
# Step 2: Import dashboards into Grafana via API
# ============================================================
echo ""
if [ "$NO_GRAFANA" = "true" ]; then
    echo -e "${BLUE}Step 2: Skipping dashboard import (--no-grafana)${NC}"
elif wait_for_grafana; then
    # Create dashboard folders
    create_folder() {
        local folder_name="$1"
        local folder_response
        local folder_uid=""

        folder_response=$(curl -s -X POST \
            "http://grafana:3000/api/folders" \
            -H "Content-Type: application/json" \
            -u "admin:admin" \
            -d "{\"title\": \"$folder_name\"}" 2>/dev/null)
        folder_uid=$(echo "$folder_response" | jq -r '.uid // ""' 2>/dev/null)

        if [ -z "$folder_uid" ] || [ "$folder_uid" = "null" ]; then
            folder_response=$(curl -s "http://grafana:3000/api/folders" -u "admin:admin" 2>/dev/null)
            folder_uid=$(echo "$folder_response" | jq -r ".[] | select(.title == \"$folder_name\") | .uid // \"\"" 2>/dev/null | head -1)
        fi

        if [ -n "$folder_uid" ] && [ "$folder_uid" != "null" ]; then
            echo -e "${GREEN}  ✓ Created/found $folder_name folder${NC}" >&2
            echo "$folder_uid"
        fi
    }

    ADMIN_FOLDER_UID=$(create_folder "Admin")
    INFO_FOLDER_UID=$(create_folder "Info")
    LINES_FOLDER_UID=$(create_folder "Lines")
    MACHINES_FOLDER_UID=$(create_folder "Machines")

    DASHBOARD_COUNT=0
    DASHBOARD_FAILED=0
    for dashboard_file in "$WORK_DIR/dashboards/"*.json; do
        if [ -f "$dashboard_file" ]; then
            dashboard_name=$(basename "$dashboard_file" .json)

            FOLDER_UID=""
            if [[ "$dashboard_name" == "stop-reason-admin" ]] && [ -n "$ADMIN_FOLDER_UID" ]; then
                FOLDER_UID="$ADMIN_FOLDER_UID"
            elif [[ "$dashboard_name" == "database-info" || "$dashboard_name" == "demo-info" ]] && [ -n "$INFO_FOLDER_UID" ]; then
                FOLDER_UID="$INFO_FOLDER_UID"
            elif [[ "$dashboard_name" == *"-oee-dashboard" ]] && [ -n "$LINES_FOLDER_UID" ]; then
                FOLDER_UID="$LINES_FOLDER_UID"
            elif [[ "$dashboard_name" == *"-L"*"-dashboard" ]] && [ -n "$MACHINES_FOLDER_UID" ]; then
                FOLDER_UID="$MACHINES_FOLDER_UID"
            fi

            if [ -n "$FOLDER_UID" ]; then
                PAYLOAD=$(jq --arg fuid "$FOLDER_UID" '{dashboard: (. | .id = null), folderUid: $fuid, overwrite: true}' "$dashboard_file")
            else
                PAYLOAD=$(jq '{dashboard: (. | .id = null), overwrite: true}' "$dashboard_file")
            fi

            RESPONSE=$(curl -s -X POST \
                "http://grafana:3000/api/dashboards/db" \
                -H "Content-Type: application/json" \
                -u "admin:admin" \
                -d "$PAYLOAD" 2>/dev/null)

            STATUS=$(echo "$RESPONSE" | jq -r '.status // "error"' 2>/dev/null)
            if [ "$STATUS" = "success" ]; then
                DASHBOARD_COUNT=$((DASHBOARD_COUNT + 1))
            else
                DASHBOARD_FAILED=$((DASHBOARD_FAILED + 1))
                echo -e "${YELLOW}    Warning: Failed to import $dashboard_name${NC}"
            fi
        fi
    done

    if [ $DASHBOARD_FAILED -eq 0 ]; then
        echo -e "${GREEN}  ✓ Imported $DASHBOARD_COUNT dashboards${NC}"
    else
        echo -e "${YELLOW}  Imported $DASHBOARD_COUNT dashboards ($DASHBOARD_FAILED failed)${NC}"
    fi
else
    echo -e "${YELLOW}  Warning: Grafana not responding, skipping dashboard import${NC}"
fi

# ============================================================
# Step 3: Create SQL views (needs asset table from UMH Core)
# ============================================================
echo ""
if [ "$NO_HISTORIAN" = "true" ]; then
    echo -e "${BLUE}Step 3: Skipping SQL views (--no-historian)${NC}"
else
    echo -e "${BLUE}Step 3: Creating SQL views for dashboards...${NC}"

    if wait_for_assets; then
        if [ -f "$WORK_DIR/sql/views.sql" ]; then
            PGPASSWORD=postgres psql -h pgbouncer -U postgres -d umh < "$WORK_DIR/sql/views.sql" 2>/dev/null || true
            VIEW_COUNT=$(PGPASSWORD=postgres psql -h pgbouncer -U postgres -d umh -tAc "SELECT COUNT(*) FROM pg_views WHERE schemaname = 'public' AND viewname LIKE 'v_%'" 2>/dev/null || echo "0")
            echo -e "${GREEN}  ✓ SQL views created (${VIEW_COUNT} views)${NC}"
        fi
    else
        echo -e "${YELLOW}  Warning: Assets not found - views not created${NC}"
        echo "  Run manually: psql -h localhost -U postgres -d umh < sql/views.sql"
    fi
fi

# ============================================================
# Step 4: Generate historical data (optional)
# ============================================================
if [ "$NO_HISTORIAN" = "true" ]; then
    echo ""
    echo -e "${BLUE}Step 4: Skipping historical data (--no-historian)${NC}"
elif [ "$HISTORY_DAYS" -gt 0 ] 2>/dev/null; then
    echo ""
    echo -e "${BLUE}Step 4: Generating historical data ($HISTORY_DAYS days)...${NC}"

    if [ -f "$SCRIPTS_DIR/generate-historical-data.py" ]; then
        python3 "$SCRIPTS_DIR/generate-historical-data.py" \
            --days "$HISTORY_DAYS" \
            --factory-setup "$WORK_DIR/factory-setup.yaml" \
            --host pgbouncer

        echo -e "${GREEN}  ✓ Historical data generated ($HISTORY_DAYS days)${NC}"
    else
        echo -e "${YELLOW}  Warning: generate-historical-data.py not found${NC}"
    fi
else
    echo ""
    echo -e "${BLUE}Step 4: Historical data generation skipped (HISTORY_DAYS=0)${NC}"
fi

# ============================================================
# Step 5: Cleanup intermediate files
# ============================================================
echo ""
echo -e "${BLUE}Step 5: Cleaning up intermediate files...${NC}"

# Remove SQL dir (already applied to database)
rm -rf "$WORK_DIR/sql/"
echo -e "${GREEN}  ✓ Removed sql/ (already applied to database)${NC}"

# Remove dashboards dir (already imported to Grafana via API)
rm -rf "$WORK_DIR/dashboards/"
echo -e "${GREEN}  ✓ Removed dashboards/ (already imported to Grafana)${NC}"

# Remove factory-setup.yaml (intermediate config)
rm -f "$WORK_DIR/factory-setup.yaml"
echo -e "${GREEN}  ✓ Removed factory-setup.yaml${NC}"

# Remove umh-config workspace (config already in umh-core-data/)
rm -rf "$WORK_DIR/umh-config/"
echo -e "${GREEN}  ✓ Removed umh-config/ (config deployed to umh-core-data/)${NC}"

echo ""
echo -e "${GREEN}=== Phase 2 (Post-Init) Complete ===${NC}"
