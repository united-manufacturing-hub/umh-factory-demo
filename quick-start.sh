#!/usr/bin/env bash
# quick-start.sh - Single-command UMH demo setup
#
# Usage:
#   curl -fsSL https://github.com/.../releases/download/v1.0.0/quick-start.sh -o quick-start.sh && bash quick-start.sh
#   bash quick-start.sh --dev               # Use dev branch instead of release tag
#   bash quick-start.sh --branch=staging    # Use a specific branch
#   bash quick-start.sh --repo=user/repo    # Use a different template repo
#
# Prerequisites:
#   - Docker Engine + Docker Compose v2
#   - A docker-compose.yaml with umh-core service (AUTH_TOKEN + LOCATION_0 required)
#
# Optional:
#   - A logo file (any format: png, jpg, svg) in the current directory

set -euo pipefail

# ─── Parse arguments ─────────────────────────────────────────────
USE_BRANCH=""
USE_REPO=""
for arg in "$@"; do
    case "$arg" in
        --dev)  USE_BRANCH="dev" ;;
        --branch=*) USE_BRANCH="${arg#--branch=}" ;;
        --repo=*) USE_REPO="${arg#--repo=}" ;;
    esac
done

# ─── Configuration ───────────────────────────────────────────────
VERSION="${VERSION:-1.0.0}"
BUILDER_IMAGE="${BUILDER_IMAGE:-dh2k/demo-builder:v${VERSION}}"
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
        echo "Check builder logs: docker logs $BUILDER_NAME"
        echo "To clean up: docker rm -f $BUILDER_NAME 2>/dev/null; rm -rf .builder/"
    fi
}
trap cleanup EXIT

echo -e "${BLUE}=== UMH Demo Quick Start ===${NC}"
echo ""

# ─── Prerequisite checks ────────────────────────────────────────
echo "Checking prerequisites..."

if ! command -v docker &>/dev/null; then
    echo -e "${RED}Error: Docker is not installed.${NC}"
    echo "Install Docker: https://docs.docker.com/get-docker/"
    exit 1
fi

if ! docker compose version &>/dev/null; then
    echo -e "${RED}Error: Docker Compose v2 is not available.${NC}"
    echo "Docker Compose v2 comes with Docker Desktop, or install the plugin:"
    echo "  https://docs.docker.com/compose/install/"
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

echo -e "${GREEN}  ✓ Docker and Docker Compose v2 available${NC}"
echo -e "${GREEN}  ✓ docker-compose.yaml found${NC}"

# ─── Detect host IP ──────────────────────────────────────────────
echo ""
echo -e "${BLUE}Detecting host IP address...${NC}"

DETECTED_IP=""
# Try common methods to detect the primary IP
if command -v ip &>/dev/null; then
    DETECTED_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
elif command -v ifconfig &>/dev/null; then
    DETECTED_IP=$(ifconfig 2>/dev/null | awk '/inet / && !/127.0.0.1/ {print $2}' | head -1)
fi

# Fallback: try hostname
if [ -z "$DETECTED_IP" ]; then
    DETECTED_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")
fi

if [ -z "$DETECTED_IP" ]; then
    DETECTED_IP="localhost"
fi

echo "  Detected IP: $DETECTED_IP"
echo ""
echo "  Dashboards will use this IP for API calls (e.g., form panels)."
echo "  Use 'localhost' only if accessing Grafana from this same machine."
read -p "  Host IP or hostname [$DETECTED_IP]: " USER_HOST_IP
HOST_IP="${USER_HOST_IP:-$DETECTED_IP}"
echo -e "${GREEN}  ✓ Using: $HOST_IP${NC}"

# ─── Port scanning and selection ─────────────────────────────────
echo ""
echo -e "${BLUE}Checking port availability...${NC}"

# Check if a port is in use on the host
port_in_use() {
    (echo >/dev/tcp/localhost/"$1") 2>/dev/null
}

# Find next available port starting from $1
find_available_port() {
    local port=$1
    while port_in_use "$port"; do
        port=$((port + 1))
    done
    echo "$port"
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
            echo "$start"
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
OPCUA_COUNT=9

PORT_NGINX=$(find_available_port $DEFAULT_PORT_NGINX)
PORT_GRAFANA=$(find_available_port $DEFAULT_PORT_GRAFANA)
PORT_PGBOUNCER=$(find_available_port $DEFAULT_PORT_PGBOUNCER)
PORT_SIMULATOR=$(find_available_port $DEFAULT_PORT_SIMULATOR)
PORT_UMH=$(find_available_port $DEFAULT_PORT_UMH)
PORT_OPCUA_START=$(find_available_port_range $DEFAULT_PORT_OPCUA_START $OPCUA_COUNT)
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

# ─── Check for container name conflicts ───────────────────────────
echo ""
echo -e "${BLUE}Checking for container name conflicts...${NC}"

COMPOSE_SERVICES="grafana pgbouncer timescaledb machine-simulator nginx"
CONFLICTS_FOUND=false
for svc in $COMPOSE_SERVICES; do
    FULL_NAME="${PROJECT_NAME}-${svc}-1"
    if docker ps -a --format '{{.Names}}' | grep -qx "$FULL_NAME"; then
        echo -e "${YELLOW}  Container '$FULL_NAME' already exists${NC}"
        CONFLICTS_FOUND=true
    fi
done

if docker ps -a --format '{{.Names}}' | grep -qx "$BUILDER_NAME"; then
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
            docker rm -f "$FULL_NAME" 2>/dev/null || true
        done
        docker rm -f "$BUILDER_NAME" 2>/dev/null || true
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
docker pull "$BUILDER_IMAGE"

echo ""
echo -e "${BLUE}Starting builder container (Phase 1: generate)...${NC}"

# Remove any existing builder container
docker rm -f "$BUILDER_NAME" 2>/dev/null || true

docker run -d \
    --name "$BUILDER_NAME" \
    -v "$(pwd):/workspace" \
    -e PHASE=all \
    -e "VERSION=${VERSION}" \
    -e "BRANCH=${USE_BRANCH}" \
    ${USE_REPO:+-e "REPO=${USE_REPO}"} \
    -e "HISTORY_DAYS=${HISTORY_DAYS}" \
    -e "HOST_IP=${HOST_IP}" \
    -e "PORT_NGINX=${PORT_NGINX}" \
    -e "PORT_GRAFANA=${PORT_GRAFANA}" \
    -e "PORT_PGBOUNCER=${PORT_PGBOUNCER}" \
    -e "PORT_SIMULATOR=${PORT_SIMULATOR}" \
    -e "PORT_UMH=${PORT_UMH}" \
    -e "PORT_OPCUA_START=${PORT_OPCUA_START}" \
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
        echo "Check builder logs: docker logs $BUILDER_NAME"
        exit 1
    fi
    # Show progress dots every 10 seconds
    if [ $((ELAPSED % 10)) -eq 0 ]; then
        echo -n "."
    fi
done
echo ""
echo -e "${GREEN}  ✓ Phase 1 complete - all files generated${NC}"

# ─── Build and start compose services ────────────────────────────
echo ""
echo -e "${BLUE}Building Grafana container (with custom branding)...${NC}"
docker compose build grafana

echo ""
echo -e "${BLUE}Starting services with docker compose...${NC}"
docker compose up -d

echo -e "${GREEN}  ✓ Services started${NC}"

# ─── Connect builder to compose network ──────────────────────────
echo ""
echo -e "${BLUE}Connecting builder to compose network...${NC}"

# Detect compose network name: use docker compose to find the actual container, then inspect it
PGBOUNCER_CONTAINER=$(docker compose ps -q pgbouncer 2>/dev/null || true)
if [ -n "$PGBOUNCER_CONTAINER" ]; then
    COMPOSE_NETWORK=$(docker inspect "$PGBOUNCER_CONTAINER" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null | grep -v internal | head -1 || true)
fi

if [ -z "${COMPOSE_NETWORK:-}" ]; then
    # Fallback: derive from directory name
    DIR_NAME=$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
    COMPOSE_NETWORK="${DIR_NAME}_default"
fi

docker network connect "$COMPOSE_NETWORK" "$BUILDER_NAME" 2>/dev/null || true
echo -e "${GREEN}  ✓ Builder connected to network: $COMPOSE_NETWORK${NC}"

# ─── Signal Phase 2 to start ─────────────────────────────────────
echo "$(date -Iseconds 2>/dev/null || date)" > ".builder/compose-started"
echo -e "${GREEN}  ✓ Signaled compose-started${NC}"

# ─── Poll for Phase 2 completion ─────────────────────────────────
echo ""
echo -e "${BLUE}Waiting for Phase 2 (post-init) to complete...${NC}"
echo "  (SQL schema, dashboard import, historical data...)"

TIMEOUT=600
ELAPSED=0
while [ ! -f ".builder/post-init-done" ]; do
    sleep 2
    ELAPSED=$((ELAPSED + 2))
    if [ $ELAPSED -ge $TIMEOUT ]; then
        echo -e "${RED}Error: Phase 2 timed out after ${TIMEOUT}s${NC}"
        echo "Check builder logs: docker logs $BUILDER_NAME"
        exit 1
    fi
    if [ $((ELAPSED % 10)) -eq 0 ]; then
        echo -n "."
    fi
done
echo ""
echo -e "${GREEN}  ✓ Phase 2 complete${NC}"

# ─── Cleanup builder ─────────────────────────────────────────────
echo ""
echo -e "${BLUE}Cleaning up builder...${NC}"

docker stop "$BUILDER_NAME" 2>/dev/null || true
docker rm "$BUILDER_NAME" 2>/dev/null || true
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

if [ ${#CONFLICTS[@]} -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}Note: Some ports were remapped from defaults due to conflicts.${NC}"
fi

echo ""
echo "Useful commands:"
echo "  docker compose logs -f        # Watch all service logs"
echo "  docker compose ps             # Check service status"
echo "  docker compose down           # Stop all services"
echo "  ./reset-demo                  # Reset and start fresh"
