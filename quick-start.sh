#!/usr/bin/env bash
# quick-start.sh - Single-command UMH demo setup
#
# Usage (via install.sh bootstrap):
#   bash install.sh                         # Latest stable release
#   bash install.sh --dev                   # Latest dev prerelease
#   bash install.sh --version=1.0.0         # Specific version
#
# Direct usage:
#   bash quick-start.sh --repo=user/repo    # Use a different template repo
#   bash quick-start.sh --version=1.0.0     # Use a specific version
#   bash quick-start.sh --profile=demo-mixed # Use a simulator profile (skip line selection)
#
# Prerequisites:
#   - Docker Engine + Docker Compose v2, or Podman + podman-compose
#   - A docker-compose.yaml with umh-core service (AUTH_TOKEN + LOCATION_0 required)
#
# Optional:
#   - A logo file (any format: png, jpg, svg) in the current directory
#
# Development:
#   bash quick-start.sh --local=/path/to/repo  # Use local templates (skip GitHub download)

set -euo pipefail

# ─── Parse arguments ─────────────────────────────────────────────
USE_REPO=""
CLI_VERSION=""
SIMULATOR_PROFILE=""
LOCAL_TEMPLATES=""
for arg in "$@"; do
    case "$arg" in
        --repo=*) USE_REPO="${arg#--repo=}" ;;
        --version=*) CLI_VERSION="${arg#--version=}" ;;
        --profile=*) SIMULATOR_PROFILE="${arg#--profile=}" ;;
        --local=*) LOCAL_TEMPLATES="${arg#--local=}" ;;
        --local) echo "Error: --local requires a path (e.g. --local=/path/to/repo)"; exit 1 ;;
    esac
done

if [ -n "$LOCAL_TEMPLATES" ] && [ ! -d "$LOCAL_TEMPLATES" ]; then
    echo -e "${RED:-}Error: --local path does not exist: $LOCAL_TEMPLATES${NC:-}"
    exit 1
fi

# ─── Configuration ───────────────────────────────────────────────
# Resolve template version: --version flag > VERSION env var > auto-detect latest in builder
TEMPLATE_VERSION="${CLI_VERSION:-${VERSION:-}}"
BUILDER_IMAGE="${BUILDER_IMAGE:-dh2k/demo-builder:v1.0.0}"
PROJECT_NAME=$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
BUILDER_NAME="${PROJECT_NAME}-umh-builder"
WORK_DIR="$(pwd)"

# ─── Colors ──────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─── Cleanup handler ────────────────────────────────────────────
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo ""
        echo -e "${RED}Setup failed (exit code: $exit_code).${NC}"
        echo "Check builder logs: $CONTAINER_CMD logs $BUILDER_NAME"
        echo "To clean up: $CONTAINER_CMD rm -f $BUILDER_NAME 2>/dev/null; rm -rf .builder/"
    fi
}
trap cleanup EXIT

echo -e "${BLUE}=== UMH Demo Quick Start ===${NC}"
echo ""

# ─── Prerequisite checks ────────────────────────────────────────
echo "Checking prerequisites..."

# Detect container runtime
if command -v docker &>/dev/null && docker compose version &>/dev/null; then
    CONTAINER_CMD="docker"
    COMPOSE_CMD="docker compose"
elif command -v podman &>/dev/null && podman compose version &>/dev/null; then
    CONTAINER_CMD="podman"
    COMPOSE_CMD="podman compose"
else
    echo -e "${RED}Error: Neither Docker nor Podman (with compose) is installed.${NC}"
    echo "Install Docker: https://docs.docker.com/get-docker/"
    echo "Install Podman: https://podman.io/getting-started/installation"
    exit 1
fi

if [ ! -f "$WORK_DIR/docker-compose.yaml" ] && [ ! -f "$WORK_DIR/docker-compose.yml" ]; then
    echo -e "${RED}Error: No docker-compose.yaml found in current directory.${NC}"
    echo ""
    echo "Create one first with your UMH Core service configuration:"
    echo ""
    echo "  services:"
    echo "    umh:"
    echo "      image: management.umh.app/oci/united-manufacturing-hub/umh-core:v0.44.2"
    echo "      restart: unless-stopped"
    echo "      ports:"
    echo "        - \"8090:8090\""
    echo "      volumes:"
    echo "        - ./umh-core-data:/data"
    echo "      environment:"
    echo "        - AUTH_TOKEN=your-token-from-management-console"
    echo "        - LOCATION_0=YourFactory"
    echo "        - LOCATION_1=YourSite"
    echo "        - RELEASE_CHANNEL=stable"
    echo "        - API_URL=https://management.umh.app/api"
    exit 1
fi

echo -e "${GREEN}  ✓ Using: $CONTAINER_CMD${NC}"
echo -e "${GREEN}  ✓ docker-compose.yaml found${NC}"

# ─── Detect host IP ──────────────────────────────────────────────
echo ""
echo -e "${BLUE}Detecting host IP address...${NC}"

# Collect candidate IPs
IP_OPTIONS=()
IP_LABELS=()

# 1) localhost (always available)
IP_OPTIONS+=("localhost")
IP_LABELS+=("localhost (this machine only)")

# 2) Container bridge network gateway
BRIDGE_IP=$($CONTAINER_CMD network inspect bridge 2>/dev/null \
    | grep -o '"Gateway": *"[^"]*"' | head -1 | cut -d'"' -f4 || true)
if [ -z "$BRIDGE_IP" ]; then
    BRIDGE_IP=$($CONTAINER_CMD network inspect podman 2>/dev/null \
        | grep -o '"gateway": *"[^"]*"' | head -1 | cut -d'"' -f4 || true)
fi
if [ -n "$BRIDGE_IP" ]; then
    IP_OPTIONS+=("$BRIDGE_IP")
    IP_LABELS+=("$BRIDGE_IP (container bridge)")
fi

# 3) Local/LAN IP (Wi-Fi, Ethernet, VPN, etc.)
LOCAL_IP=""
if command -v ip &>/dev/null; then
    LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
elif command -v ifconfig &>/dev/null; then
    LOCAL_IP=$(ifconfig 2>/dev/null | awk '/inet / && !/127.0.0.1/ {print $2}' | head -1)
fi
if [ -z "$LOCAL_IP" ]; then
    LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
fi
if [ -n "$LOCAL_IP" ]; then
    IP_OPTIONS+=("$LOCAL_IP")
    IP_LABELS+=("$LOCAL_IP (LAN)")
fi

# 4) Tailscale IP (try CLI first, then check network interfaces)
TAILSCALE_IP=""
if command -v tailscale &>/dev/null; then
    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || true)
elif [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
    TAILSCALE_IP=$(/Applications/Tailscale.app/Contents/MacOS/Tailscale ip -4 2>/dev/null || true)
fi
if [ -z "$TAILSCALE_IP" ]; then
    # Fallback: look for 100.x.x.x (CGNAT) on tailscale0 (Linux) or utun interfaces (macOS)
    if command -v ip &>/dev/null; then
        TAILSCALE_IP=$(ip -4 addr show tailscale0 2>/dev/null | awk '/inet 100\./{print $2}' | cut -d/ -f1 | head -1)
    fi
    if [ -z "$TAILSCALE_IP" ] && command -v ifconfig &>/dev/null; then
        TAILSCALE_IP=$(ifconfig 2>/dev/null | awk '/inet 100\./{print $2}' | head -1)
    fi
fi
if [ -n "$TAILSCALE_IP" ]; then
    IP_OPTIONS+=("$TAILSCALE_IP")
    IP_LABELS+=("$TAILSCALE_IP (Tailscale)")
fi

# 5) External/public IP
EXTERNAL_IP=$(curl -s --max-time 3 https://ifconfig.me 2>/dev/null \
    || curl -s --max-time 3 https://api.ipify.org 2>/dev/null || true)
if [ -n "$EXTERNAL_IP" ]; then
    IP_OPTIONS+=("$EXTERNAL_IP")
    IP_LABELS+=("$EXTERNAL_IP (external/public)")
fi

echo ""
echo "  Dashboards will use this IP for API calls (e.g., form panels)."
echo "  Use 'localhost' only if accessing Grafana from this same machine."
echo ""

for i in "${!IP_OPTIONS[@]}"; do
    echo "    $((i + 1))) ${IP_LABELS[$i]}"
done
echo "    $((${#IP_OPTIONS[@]} + 1))) Enter manually"
echo ""

# Default to LAN IP if available, otherwise localhost
DEFAULT_IDX=1
if [ -n "${LOCAL_IP:-}" ]; then
    for i in "${!IP_OPTIONS[@]}"; do
        if [ "${IP_OPTIONS[$i]}" = "$LOCAL_IP" ]; then
            DEFAULT_IDX=$((i + 1))
            break
        fi
    done
fi

read -p "  Select IP [${DEFAULT_IDX}]: " IP_CHOICE
IP_CHOICE="${IP_CHOICE:-$DEFAULT_IDX}"

MANUAL_IDX=$((${#IP_OPTIONS[@]} + 1))
if [ "$IP_CHOICE" -eq "$MANUAL_IDX" ] 2>/dev/null; then
    read -p "  Enter IP or hostname: " HOST_IP
    HOST_IP="${HOST_IP:-localhost}"
elif [ "$IP_CHOICE" -ge 1 ] 2>/dev/null && [ "$IP_CHOICE" -le "${#IP_OPTIONS[@]}" ] 2>/dev/null; then
    HOST_IP="${IP_OPTIONS[$((IP_CHOICE - 1))]}"
else
    echo -e "${YELLOW}  Invalid selection, using default${NC}"
    HOST_IP="${IP_OPTIONS[$((DEFAULT_IDX - 1))]}"
fi

echo -e "${GREEN}  ✓ Using: $HOST_IP${NC}"

# ─── Port scanning and selection ─────────────────────────────────
echo ""
echo -e "${BLUE}Checking port availability...${NC}"

# Track ports we've already allocated in this run
ALLOCATED_PORTS=""

# Check if a port is in use on the host or already allocated by this script
port_in_use() {
    # Check if we already allocated this port
    echo "$ALLOCATED_PORTS" | grep -qw "$1" && return 0
    # Check for active listeners
    (echo >/dev/tcp/localhost/"$1") 2>/dev/null && return 0
    # Check for containers binding this port (including stopped ones)
    $CONTAINER_CMD ps -a --format '{{.Ports}}' 2>/dev/null | grep -q "0.0.0.0:$1->" && return 0
    return 1
}

# Find next available port starting from $1 and mark it as allocated
find_available_port() {
    local port=$1
    while port_in_use "$port"; do
        port=$((port + 1))
    done
    ALLOCATED_PORTS="$ALLOCATED_PORTS $port"
    FOUND_PORT=$port
}

# Find a contiguous block of $2 available ports starting from $1
find_available_port_range() {
    local start=$1
    local count=$2
    while true; do
        local all_free=true
        for ((p=start; p<start+count; p++)); do
            if port_in_use "$p"; then
                all_free=false
                start=$((p + 1))
                break
            fi
        done
        if $all_free; then
            for ((p=start; p<start+count; p++)); do
                ALLOCATED_PORTS="$ALLOCATED_PORTS $p"
            done
            FOUND_PORT=$start
            return
        fi
    done
}

DEFAULT_PORT_NGINX=80
DEFAULT_PORT_GRAFANA=8080
DEFAULT_PORT_PGBOUNCER=5432
DEFAULT_PORT_SIMULATOR=8081
DEFAULT_PORT_UMH=8090
DEFAULT_PORT_OPCUA_START=4840
DEFAULT_PORT_MODBUS=502
OPCUA_COUNT=41  # Up to 41 ports for dynamic line selection (4840-4880)

find_available_port $DEFAULT_PORT_NGINX;    PORT_NGINX=$FOUND_PORT
find_available_port $DEFAULT_PORT_GRAFANA;  PORT_GRAFANA=$FOUND_PORT
find_available_port $DEFAULT_PORT_PGBOUNCER; PORT_PGBOUNCER=$FOUND_PORT
find_available_port $DEFAULT_PORT_SIMULATOR; PORT_SIMULATOR=$FOUND_PORT
find_available_port $DEFAULT_PORT_UMH;      PORT_UMH=$FOUND_PORT
find_available_port $DEFAULT_PORT_MODBUS;   PORT_MODBUS=$FOUND_PORT
find_available_port_range $DEFAULT_PORT_OPCUA_START $OPCUA_COUNT; PORT_OPCUA_START=$FOUND_PORT
OPCUA_END=$((PORT_OPCUA_START + OPCUA_COUNT - 1))

# Check for conflicts
CONFLICTS=()
[ "$PORT_NGINX" != "$DEFAULT_PORT_NGINX" ] && \
    CONFLICTS+=("Nginx:             $DEFAULT_PORT_NGINX -> $PORT_NGINX")
[ "$PORT_GRAFANA" != "$DEFAULT_PORT_GRAFANA" ] && \
    CONFLICTS+=("Grafana:           $DEFAULT_PORT_GRAFANA -> $PORT_GRAFANA")
[ "$PORT_PGBOUNCER" != "$DEFAULT_PORT_PGBOUNCER" ] && \
    CONFLICTS+=("PostgreSQL:        $DEFAULT_PORT_PGBOUNCER -> $PORT_PGBOUNCER")
[ "$PORT_SIMULATOR" != "$DEFAULT_PORT_SIMULATOR" ] && \
    CONFLICTS+=("Machine Simulator: $DEFAULT_PORT_SIMULATOR -> $PORT_SIMULATOR")
[ "$PORT_UMH" != "$DEFAULT_PORT_UMH" ] && \
    CONFLICTS+=("UMH Core:          $DEFAULT_PORT_UMH -> $PORT_UMH")
[ "$PORT_OPCUA_START" != "$DEFAULT_PORT_OPCUA_START" ] && \
    CONFLICTS+=("OPC-UA:            $DEFAULT_PORT_OPCUA_START-$((DEFAULT_PORT_OPCUA_START + OPCUA_COUNT - 1)) -> $PORT_OPCUA_START-$OPCUA_END")
[ "$PORT_MODBUS" != "$DEFAULT_PORT_MODBUS" ] && \
    CONFLICTS+=("Modbus TCP:        $DEFAULT_PORT_MODBUS -> $PORT_MODBUS")

if [ ${#CONFLICTS[@]} -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}Port conflicts detected - proposed remapping:${NC}"
    for conflict in "${CONFLICTS[@]}"; do
        echo "  $conflict"
    done
    echo ""
    read -p "Accept these ports? [Y/n]: " ACCEPT_PORTS

    if [[ -n "$ACCEPT_PORTS" && ! "$ACCEPT_PORTS" =~ ^[Yy] ]]; then
        # Per-service prompts for each conflicted port
        if [ "$PORT_NGINX" != "$DEFAULT_PORT_NGINX" ]; then
            while true; do
                read -p "  Port for Nginx (default $DEFAULT_PORT_NGINX in use, suggested: $PORT_NGINX): " USER_PORT
                USER_PORT=${USER_PORT:-$PORT_NGINX}
                if port_in_use "$USER_PORT"; then
                    echo -e "${YELLOW}    Port $USER_PORT is also in use${NC}"
                else
                    PORT_NGINX=$USER_PORT; break
                fi
            done
        fi
        if [ "$PORT_GRAFANA" != "$DEFAULT_PORT_GRAFANA" ]; then
            while true; do
                read -p "  Port for Grafana (default $DEFAULT_PORT_GRAFANA in use, suggested: $PORT_GRAFANA): " USER_PORT
                USER_PORT=${USER_PORT:-$PORT_GRAFANA}
                if port_in_use "$USER_PORT"; then
                    echo -e "${YELLOW}    Port $USER_PORT is also in use${NC}"
                else
                    PORT_GRAFANA=$USER_PORT; break
                fi
            done
        fi
        if [ "$PORT_PGBOUNCER" != "$DEFAULT_PORT_PGBOUNCER" ]; then
            while true; do
                read -p "  Port for PostgreSQL (default $DEFAULT_PORT_PGBOUNCER in use, suggested: $PORT_PGBOUNCER): " USER_PORT
                USER_PORT=${USER_PORT:-$PORT_PGBOUNCER}
                if port_in_use "$USER_PORT"; then
                    echo -e "${YELLOW}    Port $USER_PORT is also in use${NC}"
                else
                    PORT_PGBOUNCER=$USER_PORT; break
                fi
            done
        fi
        if [ "$PORT_SIMULATOR" != "$DEFAULT_PORT_SIMULATOR" ]; then
            while true; do
                read -p "  Port for Machine Simulator (default $DEFAULT_PORT_SIMULATOR in use, suggested: $PORT_SIMULATOR): " USER_PORT
                USER_PORT=${USER_PORT:-$PORT_SIMULATOR}
                if port_in_use "$USER_PORT"; then
                    echo -e "${YELLOW}    Port $USER_PORT is also in use${NC}"
                else
                    PORT_SIMULATOR=$USER_PORT; break
                fi
            done
        fi
        if [ "$PORT_UMH" != "$DEFAULT_PORT_UMH" ]; then
            while true; do
                read -p "  Port for UMH Core (default $DEFAULT_PORT_UMH in use, suggested: $PORT_UMH): " USER_PORT
                USER_PORT=${USER_PORT:-$PORT_UMH}
                if port_in_use "$USER_PORT"; then
                    echo -e "${YELLOW}    Port $USER_PORT is also in use${NC}"
                else
                    PORT_UMH=$USER_PORT; break
                fi
            done
        fi
        if [ "$PORT_OPCUA_START" != "$DEFAULT_PORT_OPCUA_START" ]; then
            while true; do
                read -p "  Start port for OPC-UA range of $OPCUA_COUNT (default $DEFAULT_PORT_OPCUA_START in use, suggested: $PORT_OPCUA_START): " USER_PORT
                USER_PORT=${USER_PORT:-$PORT_OPCUA_START}
                RANGE_OK=true
                for ((p=USER_PORT; p<USER_PORT+OPCUA_COUNT; p++)); do
                    if port_in_use "$p"; then
                        echo -e "${YELLOW}    Port $p is in use${NC}"
                        RANGE_OK=false; break
                    fi
                done
                if $RANGE_OK; then
                    PORT_OPCUA_START=$USER_PORT
                    OPCUA_END=$((PORT_OPCUA_START + OPCUA_COUNT - 1))
                    break
                fi
            done
        fi
        if [ "$PORT_MODBUS" != "$DEFAULT_PORT_MODBUS" ]; then
            while true; do
                read -p "  Port for Modbus TCP (default $DEFAULT_PORT_MODBUS in use, suggested: $PORT_MODBUS): " USER_PORT
                USER_PORT=${USER_PORT:-$PORT_MODBUS}
                if port_in_use "$USER_PORT"; then
                    echo -e "${YELLOW}    Port $USER_PORT is also in use${NC}"
                else
                    PORT_MODBUS=$USER_PORT; break
                fi
            done
        fi
    fi
    echo -e "${GREEN}  ✓ Ports selected${NC}"
else
    echo -e "${GREEN}  ✓ All default ports available${NC}"
fi

# ─── Historical data prompt ──────────────────────────────────────
echo ""
HISTORY_DAYS=0
read -p "Generate historical data? [y/N]: " GENERATE_HISTORY
if [[ "$GENERATE_HISTORY" =~ ^[Yy] ]]; then
    read -p "  Number of days (1-7, default: 7): " HISTORY_DAYS
    HISTORY_DAYS=${HISTORY_DAYS:-7}
    if [ "$HISTORY_DAYS" -gt 7 ] 2>/dev/null; then
        echo -e "${YELLOW}  Capping to 7 days${NC}"
        HISTORY_DAYS=7
    fi
    echo -e "${GREEN}  ✓ Will generate $HISTORY_DAYS days of history${NC}"
fi

# ─── Production line selection ────────────────────────────────────
echo ""
SELECTED_LINES=""

if [ -n "$SIMULATOR_PROFILE" ]; then
    echo -e "${GREEN}  ✓ Using simulator profile: $SIMULATOR_PROFILE${NC}"
    SELECTED_LINES="__profile__:${SIMULATOR_PROFILE}"
else
    echo -e "${BLUE}Available production line templates:${NC}"
    echo ""
    echo "  Automotive:"
    echo "    1) automotive-welding       - Body welding (metal forming → spot welder → robot welder → pick & place)"
    echo "    2) automotive-assembly      - Door assembly and painting"
    echo "  Electronics:"
    echo "    3) electronics-smt          - Surface-mount technology assembly"
    echo "    4) electronics-through-hole - Through-hole component assembly"
    echo "  Food & Beverage:"
    echo "    5) food-beverage-filling    - High-speed filling and labeling"
    echo "  Pharma:"
    echo "    6) pharma-batch             - Batch processing and filling"
    echo "  Window:"
    echo "    7) window-frame             - Frame fabrication and glazing"
    echo "  Furniture:"
    echo "    8) furniture-assembly       - Panel machining and assembly"
    echo "  Metal Parts:"
    echo "    9) metal-parts-fabrication  - Sheet metal processing"
    echo "  Plastic Parts:"
    echo "   10) plastic-parts-molding    - Extrusion and molding"
    echo ""

    LINE_TEMPLATES=(
        "automotive-welding"
        "automotive-assembly"
        "electronics-smt"
        "electronics-through-hole"
        "food-beverage-filling"
        "pharma-batch"
        "window-frame"
        "furniture-assembly"
        "metal-parts-fabrication"
        "plastic-parts-molding"
    )

    read -p "Select lines (comma-separated, e.g., 1,3,5) [1]: " LINE_SELECTION
    LINE_SELECTION="${LINE_SELECTION:-1}"

    IFS=',' read -ra SELECTIONS <<< "$LINE_SELECTION"
    PARTS=()
    for sel in "${SELECTIONS[@]}"; do
        sel=$(echo "$sel" | tr -d ' ')
        if [ "$sel" -ge 1 ] 2>/dev/null && [ "$sel" -le 10 ] 2>/dev/null; then
            LINE_NAME="${LINE_TEMPLATES[$((sel - 1))]}"
            read -p "How many '${LINE_NAME}' lines? [1]: " LINE_COUNT
            LINE_COUNT="${LINE_COUNT:-1}"
            PARTS+=("${LINE_NAME}:${LINE_COUNT}")
            echo -e "${GREEN}  ✓ ${LINE_NAME} x${LINE_COUNT}${NC}"
        else
            echo -e "${YELLOW}  Skipping invalid selection: $sel${NC}"
        fi
    done

    if [ ${#PARTS[@]} -eq 0 ]; then
        echo -e "${YELLOW}  No valid lines selected, defaulting to automotive-welding x1${NC}"
        PARTS=("automotive-welding:1")
    fi

    SELECTED_LINES=$(IFS=','; echo "${PARTS[*]}")
    echo ""
    echo -e "${GREEN}  ✓ Selected lines: $SELECTED_LINES${NC}"
fi

# ─── Logo / branding image ─────────────────────────────────────────
echo ""
echo -e "${BLUE}Checking for custom logo...${NC}"

LOGO_FOUND=false
for f in "$WORK_DIR"/logo.{png,jpg,jpeg,svg} "$WORK_DIR"/img/logo.{png,jpg,jpeg,svg}; do
    if [ -f "$f" ]; then
        echo -e "${GREEN}  ✓ Found logo: $f${NC}"
        LOGO_FOUND=true
        break
    fi
done

# Also check for any image file in workspace root (the builder accepts any image)
if ! $LOGO_FOUND; then
    for f in "$WORK_DIR"/*.png "$WORK_DIR"/*.jpg "$WORK_DIR"/*.jpeg "$WORK_DIR"/*.svg; do
        if [ -f "$f" ]; then
            echo -e "${GREEN}  ✓ Found image: $(basename "$f")${NC}"
            LOGO_FOUND=true
            break
        fi
    done
fi

if ! $LOGO_FOUND; then
    echo -e "${YELLOW}  No logo image found in current directory.${NC}"
    echo "  The builder will use the default UMH logo unless you provide one."
    echo ""
    read -p "  Paste a URL to a logo image (or press Enter to skip): " LOGO_URL

    if [ -n "$LOGO_URL" ]; then
        # Derive filename from URL, fallback to logo.png
        LOGO_FILENAME=$(basename "$LOGO_URL" | sed 's/[?#].*//')
        case "$LOGO_FILENAME" in
            *.png|*.jpg|*.jpeg|*.svg) ;; # keep extension
            *) LOGO_FILENAME="logo.png" ;;
        esac

        echo "  Downloading logo..."
        if curl -fsSL --max-time 15 "$LOGO_URL" -o "$WORK_DIR/$LOGO_FILENAME"; then
            echo -e "${GREEN}  ✓ Saved as $LOGO_FILENAME${NC}"
        else
            echo -e "${YELLOW}  Download failed — continuing with default logo${NC}"
        fi
    else
        echo "  Skipping — will use default UMH logo."
    fi
fi

# ─── Check for container name conflicts ───────────────────────────
echo ""
echo -e "${BLUE}Checking for container name conflicts...${NC}"

COMPOSE_SERVICES="grafana pgbouncer timescaledb machine-simulator nginx"
CONFLICTS_FOUND=false
for svc in $COMPOSE_SERVICES; do
    FULL_NAME="${PROJECT_NAME}-${svc}-1"
    if $CONTAINER_CMD ps -a --format '{{.Names}}' | grep -qx "$FULL_NAME"; then
        echo -e "${YELLOW}  Container '$FULL_NAME' already exists${NC}"
        CONFLICTS_FOUND=true
    fi
done

if $CONTAINER_CMD ps -a --format '{{.Names}}' | grep -qx "$BUILDER_NAME"; then
    echo -e "${YELLOW}  Builder container '$BUILDER_NAME' already exists${NC}"
    CONFLICTS_FOUND=true
fi

if $CONFLICTS_FOUND; then
    echo ""
    echo -e "${YELLOW}Existing containers found from a previous run.${NC}"
    read -p "Remove them and continue? [Y/n]: " REMOVE_EXISTING
    if [[ -z "$REMOVE_EXISTING" || "$REMOVE_EXISTING" =~ ^[Yy] ]]; then
        for svc in $COMPOSE_SERVICES; do
            FULL_NAME="${PROJECT_NAME}-${svc}-1"
            $CONTAINER_CMD rm -f "$FULL_NAME" 2>/dev/null || true
        done
        $CONTAINER_CMD rm -f "$BUILDER_NAME" 2>/dev/null || true
        echo -e "${GREEN}  ✓ Existing containers removed${NC}"
    else
        echo -e "${RED}Aborting to avoid conflicts.${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}  ✓ No conflicts${NC}"
fi

# ─── Pull and run builder container ──────────────────────────────
echo ""
echo -e "${BLUE}Pulling builder image...${NC}"
$CONTAINER_CMD pull "$BUILDER_IMAGE"

echo ""
echo -e "${BLUE}Starting builder container (Phase 1: generate)...${NC}"

# Remove any existing builder container
$CONTAINER_CMD rm -f "$BUILDER_NAME" 2>/dev/null || true

$CONTAINER_CMD run -d \
    --name "$BUILDER_NAME" \
    -v "$(pwd):/workspace" \
    ${LOCAL_TEMPLATES:+-v "$LOCAL_TEMPLATES:/local-templates:ro"} \
    -e PHASE=all \
    ${TEMPLATE_VERSION:+-e "VERSION=${TEMPLATE_VERSION}"} \
    ${USE_REPO:+-e "REPO=${USE_REPO}"} \
    ${LOCAL_TEMPLATES:+-e "LOCAL_TEMPLATES=/local-templates"} \
    -e "HISTORY_DAYS=${HISTORY_DAYS}" \
    -e "SELECTED_LINES=${SELECTED_LINES}" \
    -e "HOST_IP=${HOST_IP}" \
    -e "PORT_NGINX=${PORT_NGINX}" \
    -e "PORT_GRAFANA=${PORT_GRAFANA}" \
    -e "PORT_PGBOUNCER=${PORT_PGBOUNCER}" \
    -e "PORT_SIMULATOR=${PORT_SIMULATOR}" \
    -e "PORT_UMH=${PORT_UMH}" \
    -e "PORT_OPCUA_START=${PORT_OPCUA_START}" \
    -e "PORT_MODBUS=${PORT_MODBUS}" \
    -e "PROJECT_NAME=${PROJECT_NAME}" \
    "$BUILDER_IMAGE"

echo -e "${GREEN}  ✓ Builder started${NC}"

# ─── Poll for Phase 1 completion ─────────────────────────────────
echo ""
echo -e "${BLUE}Waiting for Phase 1 (generate) to complete...${NC}"

TIMEOUT=300
ELAPSED=0
while [ ! -f ".builder/generate-done" ]; do
    sleep 2
    ELAPSED=$((ELAPSED + 2))
    if [ $ELAPSED -ge $TIMEOUT ]; then
        echo -e "${RED}Error: Phase 1 timed out after ${TIMEOUT}s${NC}"
        echo "Check builder logs: $CONTAINER_CMD logs $BUILDER_NAME"
        exit 1
    fi
    # Show progress dots every 10 seconds
    if [ $((ELAPSED % 10)) -eq 0 ]; then
        echo -n "."
    fi
done
echo ""
echo -e "${GREEN}  ✓ Phase 1 complete - all files generated${NC}"

# ─── Fix file ownership from builder container ───────────────────
# The builder runs as root, so all generated files are root-owned.
# Fix ownership so the host user can write (e.g., signal files)
# and services can write to their data dirs.
docker run --rm -v "$(pwd):/workspace" alpine sh -c \
    "chown -R $(id -u):$(id -g) /workspace/.builder \
     && chown -R 472:0 /workspace/grafana-data \
     && chown -R 1000:1000 /workspace/umh-core-data"

# ─── Build and start compose services ────────────────────────────
echo ""
echo -e "${BLUE}Building Grafana container (with custom branding)...${NC}"
$COMPOSE_CMD build grafana

echo ""
echo -e "${BLUE}Starting services...${NC}"
$COMPOSE_CMD up -d

echo -e "${GREEN}  ✓ Services started${NC}"

# ─── Connect builder to compose network ──────────────────────────
echo ""
echo -e "${BLUE}Connecting builder to compose network...${NC}"

# Derive compose network from project name (compose convention)
COMPOSE_PROJECT=$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
COMPOSE_NETWORK="${COMPOSE_PROJECT}_default"

$CONTAINER_CMD network connect "$COMPOSE_NETWORK" "$BUILDER_NAME" 2>/dev/null || true
echo -e "${GREEN}  ✓ Builder connected to network: $COMPOSE_NETWORK${NC}"

# ─── Signal Phase 2 to start ─────────────────────────────────────
echo "$(date -Iseconds 2>/dev/null || date)" > ".builder/compose-started"
echo -e "${GREEN}  ✓ Signaled compose-started${NC}"

# ─── Stream Phase 2 progress ──────────────────────────────────────
echo ""
echo -e "${BLUE}Running Phase 2 (post-init): SQL schema, dashboards, historical data...${NC}"
echo ""

# Stream builder logs in background (from current point onward)
LAST_LOG_LINE=$($CONTAINER_CMD logs "$BUILDER_NAME" 2>&1 | wc -l)
$CONTAINER_CMD logs -f "$BUILDER_NAME" 2>&1 | tail -n +"$((LAST_LOG_LINE + 1))" &
LOG_PID=$!

TIMEOUT=1800
ELAPSED=0
while [ ! -f ".builder/post-init-done" ]; do
    sleep 2
    ELAPSED=$((ELAPSED + 2))

    # Check if builder container is still running
    if ! $CONTAINER_CMD ps --format '{{.Names}}' | grep -q "^${BUILDER_NAME}$"; then
        kill "$LOG_PID" 2>/dev/null || true
        wait "$LOG_PID" 2>/dev/null || true
        echo ""
        echo -e "${RED}Error: Builder container exited unexpectedly${NC}"
        echo "Check logs: $CONTAINER_CMD logs $BUILDER_NAME"
        exit 1
    fi

    if [ $ELAPSED -ge $TIMEOUT ]; then
        kill "$LOG_PID" 2>/dev/null || true
        wait "$LOG_PID" 2>/dev/null || true
        echo ""
        echo -e "${RED}Error: Phase 2 timed out after ${TIMEOUT}s${NC}"
        echo "Check builder logs: $CONTAINER_CMD logs $BUILDER_NAME"
        exit 1
    fi
done

# Stop log streaming
kill "$LOG_PID" 2>/dev/null || true
wait "$LOG_PID" 2>/dev/null || true
echo ""
echo -e "${GREEN}  ✓ Phase 2 complete${NC}"

# ─── Cleanup builder ─────────────────────────────────────────────
echo ""
echo -e "${BLUE}Cleaning up builder...${NC}"

$CONTAINER_CMD stop "$BUILDER_NAME" 2>/dev/null || true
$CONTAINER_CMD rm "$BUILDER_NAME" 2>/dev/null || true
rm -rf .builder/

echo -e "${GREEN}  ✓ Builder removed${NC}"

# ─── Print access URLs ───────────────────────────────────────────
echo ""
echo -e "${GREEN}=== Setup Complete ===${NC}"
echo ""
echo "Access points:"
echo "  Grafana:           http://${HOST_IP}:${PORT_GRAFANA}  (admin/admin)"
echo "  Machine Simulator: http://${HOST_IP}:${PORT_SIMULATOR}"
echo "  UMH Core:          http://${HOST_IP}:${PORT_UMH}"
echo "  PostgreSQL:        ${HOST_IP}:${PORT_PGBOUNCER}  (postgres/postgres)"
echo "  Nginx:             http://${HOST_IP}:${PORT_NGINX}"
echo "  OPC-UA:            ${HOST_IP}:${PORT_OPCUA_START}-${OPCUA_END}"
echo "  Modbus TCP:        ${HOST_IP}:${PORT_MODBUS}"

if [ ${#CONFLICTS[@]} -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}Note: Some ports were remapped from defaults due to conflicts.${NC}"
fi

echo ""
echo "Useful commands:"
echo "  $COMPOSE_CMD logs -f        # Watch all service logs"
echo "  $COMPOSE_CMD ps             # Check service status"
echo "  $COMPOSE_CMD down           # Stop all services"
echo "  ./reset-demo                  # Reset and start fresh"
