#!/usr/bin/env bash
#
# export-dashboard.sh — Export a Grafana dashboard and templatize it
#
# Exports a dashboard from the Grafana API, reverses the substitutions that
# builder-generate.sh applied, and verifies lossless round-trip conversion.
#
# Usage: ./export-dashboard.sh [options] <dashboard-uid>
#
set -euo pipefail

# --- Defaults ---
GRAFANA_URL="${GRAFANA_URL:-http://localhost:8080}"
GRAFANA_TOKEN="${GRAFANA_TOKEN:-}"
COMPOSE_FILE="./docker-compose.yaml"
OUTPUT_FILE=""
DATASOURCE_UID="df9o2whw2o7wgb"
LINE_NAME=""
LINE_DISPLAY=""
WORKCELL_NAME=""
WORKCELL_DISPLAY=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Parse arguments ---
usage() {
    cat <<EOF
Usage: $(basename "$0") [options] <dashboard-uid>

Export a Grafana dashboard and convert it to a template.

Options:
  --url URL        Grafana URL (default: $GRAFANA_URL, or GRAFANA_URL env)
  --token TOKEN    Grafana API token (or set GRAFANA_TOKEN env var)
  --compose PATH   Path to docker-compose.yaml (default: $COMPOSE_FILE)
  --output PATH    Output file (default: ./{slug}.json in current directory)
  --line NAME      Line name lowercase (e.g. line1) for per-line dashboards
  --line-display NAME  Line display name (e.g. "Line 1")
  --workcell NAME  Workcell identifier (e.g. injection-molding-L1-01)
  --workcell-display NAME  Workcell display name (e.g. "Injection Molding (Pos 1)")
  -h, --help       Show this help message

Examples:
  # Export a simple dashboard (operator, stop-reason-admin, etc.)
  ./export-dashboard.sh operator-dashboard

  # Export a per-line dashboard
  ./export-dashboard.sh --line line1 --line-display "Line 1" line1-oee-dashboard

  # Export a per-machine dashboard
  ./export-dashboard.sh --line line1 --line-display "Line 1" \\
      --workcell injection-molding-L1-01 \\
      --workcell-display "Injection Molding (Pos 1)" \\
      injection-molding-L1-01-dashboard
EOF
    exit 1
}

DASHBOARD_UID=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --url)    GRAFANA_URL="$2"; shift 2 ;;
        --token)  GRAFANA_TOKEN="$2"; shift 2 ;;
        --compose) COMPOSE_FILE="$2"; shift 2 ;;
        --output) OUTPUT_FILE="$2"; shift 2 ;;
        --line)   LINE_NAME="$2"; shift 2 ;;
        --line-display) LINE_DISPLAY="$2"; shift 2 ;;
        --workcell) WORKCELL_NAME="$2"; shift 2 ;;
        --workcell-display) WORKCELL_DISPLAY="$2"; shift 2 ;;
        -h|--help) usage ;;
        -*)       echo -e "${RED}Unknown option: $1${NC}" >&2; usage ;;
        *)        DASHBOARD_UID="$1"; shift ;;
    esac
done

if [ -z "$DASHBOARD_UID" ]; then
    echo -e "${RED}Error: dashboard-uid is required${NC}" >&2
    usage
fi

# Try loading token from token.yaml next to the script if not already set
if [ -z "$GRAFANA_TOKEN" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    TOKEN_FILE="${SCRIPT_DIR}/token.yaml"
    if [ -f "$TOKEN_FILE" ]; then
        GRAFANA_TOKEN=$(grep -E '^GRAFANA_TOKEN=' "$TOKEN_FILE" | sed 's/^GRAFANA_TOKEN=//' | tr -d ' "'\' | head -1)
    fi
fi

if [ -z "$GRAFANA_TOKEN" ]; then
    echo -e "${RED}Error: Grafana API token is required. Set GRAFANA_TOKEN, use --token, or create token.yaml next to this script${NC}" >&2
    echo "  Create one at: ${GRAFANA_URL}/org/apikeys" >&2
    exit 1
fi

# --- Check dependencies ---
for cmd in curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${RED}Error: '$cmd' is required but not installed${NC}" >&2
        exit 1
    fi
done

# --- Read substitution values from docker-compose.yaml ---
echo -e "${BLUE}Reading configuration from ${COMPOSE_FILE}...${NC}"

if [ ! -f "$COMPOSE_FILE" ]; then
    echo -e "${RED}Error: docker-compose.yaml not found at ${COMPOSE_FILE}${NC}" >&2
    exit 1
fi

LOCATION_0=$(grep -E '^\s*-\s*LOCATION_0=' "$COMPOSE_FILE" | sed 's/.*LOCATION_0=//' | tr -d ' "'\' | head -1)
if [ -z "$LOCATION_0" ]; then
    echo -e "${RED}Error: LOCATION_0 not found in ${COMPOSE_FILE}${NC}" >&2
    exit 1
fi

LOCATION_1=$(grep -E '^\s*-\s*LOCATION_1=' "$COMPOSE_FILE" | sed 's/.*LOCATION_1=//' | tr -d ' "'\' | head -1)
if [ -z "$LOCATION_1" ]; then
    echo -e "${RED}Error: LOCATION_1 not found in ${COMPOSE_FILE}${NC}" >&2
    exit 1
fi

# Determine the API base URL (matches builder-generate.sh logic)
HOST_IP="${HOST_IP:-localhost}"
PORT_NGINX="${PORT_NGINX:-80}"
API_BASE_URL="http://${HOST_IP}:${PORT_NGINX}"

echo -e "${GREEN}  LOCATION_0: ${LOCATION_0}${NC}"
echo -e "${GREEN}  LOCATION_1: ${LOCATION_1}${NC}"
echo -e "${GREEN}  API_BASE_URL: ${API_BASE_URL}${NC}"

# --- Export dashboard from Grafana ---
echo ""
echo -e "${BLUE}Exporting dashboard '${DASHBOARD_UID}' from ${GRAFANA_URL}...${NC}"

HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" \
    "${GRAFANA_URL}/api/dashboards/uid/${DASHBOARD_UID}" \
    -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
    -H "Content-Type: application/json")

HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -1)
RESPONSE_BODY=$(echo "$HTTP_RESPONSE" | sed '$d')

if [ "$HTTP_CODE" != "200" ]; then
    echo -e "${RED}Error: Grafana API returned HTTP ${HTTP_CODE}${NC}" >&2
    echo "$RESPONSE_BODY" | jq . 2>/dev/null || echo "$RESPONSE_BODY" >&2
    exit 1
fi

# Extract .dashboard, strip .id and .version
ORIGINAL_JSON=$(echo "$RESPONSE_BODY" | jq '.dashboard | del(.id) | del(.version)')
DASHBOARD_TITLE=$(echo "$ORIGINAL_JSON" | jq -r '.title')

echo -e "${GREEN}  ✓ Exported: ${DASHBOARD_TITLE}${NC}"

# --- Determine output path ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="${SCRIPT_DIR}/../templates/dashboards"

if [ -z "$OUTPUT_FILE" ]; then
    # Convert title to slug: lowercase, spaces/special chars to hyphens
    SLUG=$(echo "$DASHBOARD_TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//')
    OUTPUT_FILE="./${SLUG}.json"
fi

echo -e "${GREEN}  Output: ${OUTPUT_FILE}${NC}"

# --- Templatize: reverse substitutions ---
echo ""
echo -e "${BLUE}Templatizing dashboard...${NC}"

# Convert to string for sed replacements, then back to JSON for pretty-print
TEMPLATE_STR=$(echo "$ORIGINAL_JSON" | jq -c '.')

# Order matters: replace longer/more-specific patterns first

# 1. API base URL → __API_BASE_URL__
TEMPLATE_STR=$(echo "$TEMPLATE_STR" | sed "s|${API_BASE_URL}|__API_BASE_URL__|g")

# 2. Datasource UID: df9o2whw2o7wgb → ${DS_POSTGRESQL}
TEMPLATE_STR=$(echo "$TEMPLATE_STR" | sed 's|'"$DATASOURCE_UID"'|${DS_POSTGRESQL}|g')

# 3. LOCATION_0 (enterprise) → __ENTERPRISE__
TEMPLATE_STR=$(echo "$TEMPLATE_STR" | sed "s|${LOCATION_0}|__ENTERPRISE__|g")

# 4. LOCATION_1 (site) → __SITE__
TEMPLATE_STR=$(echo "$TEMPLATE_STR" | sed "s|${LOCATION_1}|__SITE__|g")

# 5. Area: shopfloor → __AREA__
#    Only replace in quoted contexts to avoid false positives
TEMPLATE_STR=$(echo "$TEMPLATE_STR" | sed "s|'shopfloor'|'__AREA__'|g")
TEMPLATE_STR=$(echo "$TEMPLATE_STR" | sed 's|"shopfloor"|"__AREA__"|g')

# 6. Line display name → __LINE_DISPLAY__ (before LINE to avoid partial match)
if [ -n "$LINE_DISPLAY" ]; then
    TEMPLATE_STR=$(echo "$TEMPLATE_STR" | sed "s|${LINE_DISPLAY}|__LINE_DISPLAY__|g")
fi

# 7. Line name → __LINE__
if [ -n "$LINE_NAME" ]; then
    TEMPLATE_STR=$(echo "$TEMPLATE_STR" | sed "s|${LINE_NAME}|__LINE__|g")
fi

# 8. Workcell display name → __WORKCELL_DISPLAY__ (before WORKCELL)
if [ -n "$WORKCELL_DISPLAY" ]; then
    TEMPLATE_STR=$(echo "$TEMPLATE_STR" | sed "s|${WORKCELL_DISPLAY}|__WORKCELL_DISPLAY__|g")
fi

# 9. Workcell ID → __WORKCELL__
if [ -n "$WORKCELL_NAME" ]; then
    TEMPLATE_STR=$(echo "$TEMPLATE_STR" | sed "s|${WORKCELL_NAME}|__WORKCELL__|g")
fi

# Pretty-print
TEMPLATE_JSON=$(echo "$TEMPLATE_STR" | jq '.')

echo -e "${GREEN}  ✓ Substitutions applied${NC}"

# --- Round-trip verification ---
echo ""
echo -e "${BLUE}Verifying round-trip conversion...${NC}"

# Re-substitute: apply the same replacements as builder-generate.sh
REGENERATED_STR=$(echo "$TEMPLATE_JSON" | jq -c '.')
REGENERATED_STR=$(echo "$REGENERATED_STR" | sed \
    -e "s|__API_BASE_URL__|${API_BASE_URL}|g" \
    -e "s|__ENTERPRISE__|${LOCATION_0}|g" \
    -e "s|__SITE__|${LOCATION_1}|g" \
    -e "s|__AREA__|shopfloor|g" \
    -e 's|${DS_POSTGRESQL}|'"$DATASOURCE_UID"'|g')

# Re-substitute line/workcell values (order: display names before short names)
if [ -n "$LINE_DISPLAY" ]; then
    REGENERATED_STR=$(echo "$REGENERATED_STR" | sed "s|__LINE_DISPLAY__|${LINE_DISPLAY}|g")
fi
if [ -n "$LINE_NAME" ]; then
    REGENERATED_STR=$(echo "$REGENERATED_STR" | sed "s|__LINE__|${LINE_NAME}|g")
fi
if [ -n "$WORKCELL_DISPLAY" ]; then
    REGENERATED_STR=$(echo "$REGENERATED_STR" | sed "s|__WORKCELL_DISPLAY__|${WORKCELL_DISPLAY}|g")
fi
if [ -n "$WORKCELL_NAME" ]; then
    REGENERATED_STR=$(echo "$REGENERATED_STR" | sed "s|__WORKCELL__|${WORKCELL_NAME}|g")
fi

# Normalize both to sorted JSON for comparison
ORIGINAL_NORMALIZED=$(echo "$ORIGINAL_JSON" | jq -S '.')
REGENERATED_NORMALIZED=$(echo "$REGENERATED_STR" | jq -S '.')

VERIFY_TMPDIR=$(mktemp -d)
trap 'rm -rf "$VERIFY_TMPDIR"' EXIT
echo "$ORIGINAL_NORMALIZED" > "$VERIFY_TMPDIR/original.json"
echo "$REGENERATED_NORMALIZED" > "$VERIFY_TMPDIR/regenerated.json"

if diff -q "$VERIFY_TMPDIR/original.json" "$VERIFY_TMPDIR/regenerated.json" &>/dev/null; then
    echo -e "${GREEN}  ✓ Round-trip verification passed${NC}"
else
    echo -e "${YELLOW}  ⚠ Round-trip verification found differences:${NC}"
    echo ""
    diff --color=auto -u "$VERIFY_TMPDIR/original.json" "$VERIFY_TMPDIR/regenerated.json" | head -40 || true
    echo ""
    echo -e "${YELLOW}  The template may need manual review.${NC}"
fi

# --- Save template ---
echo ""
echo -e "${BLUE}Saving template...${NC}"

mkdir -p "$(dirname "$OUTPUT_FILE")"
echo "$TEMPLATE_JSON" > "$OUTPUT_FILE"
echo -e "${GREEN}  ✓ Saved to ${OUTPUT_FILE}${NC}"

# --- Diff against existing template ---
# Check if there was already a file at this path (before we wrote it — use git)
if command -v git &>/dev/null && git -C "$(dirname "$OUTPUT_FILE")" rev-parse --git-dir &>/dev/null 2>&1; then
    echo ""
    echo -e "${BLUE}Diff against previous version:${NC}"
    if git -C "$(dirname "$OUTPUT_FILE")" diff --stat -- "$OUTPUT_FILE" 2>/dev/null | grep -q .; then
        git -C "$(dirname "$OUTPUT_FILE")" diff -- "$OUTPUT_FILE" 2>/dev/null | head -60
    else
        echo -e "  ${GREEN}(no changes from committed version)${NC}"
    fi
fi

echo ""
echo -e "${GREEN}Done!${NC}"
