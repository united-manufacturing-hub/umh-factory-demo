#!/bin/bash
# builder-generate.sh - Phase 1: Generate all config files in /workspace
#
# This script runs INSIDE the builder container where Python, jq,
# imagemagick, and psql are pre-installed. It reads ENV vars set by
# the host-side quick-start.sh for port mappings and options.
#
# Env vars expected:
#   TEMPLATES_DIR  - path to downloaded repo root
#   SCRIPTS_DIR    - path to downloaded repo scripts/
#   PORT_NGINX, PORT_GRAFANA, PORT_PGBOUNCER, PORT_SIMULATOR, PORT_UMH, PORT_OPCUA_START, PORT_MODBUS
#
# Working directory: /workspace (bind-mounted from host)

set -euo pipefail

WORK_DIR="/workspace"
LOG_FILE="${WORK_DIR}/builder-generate.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Port defaults (overridden by ENV from quick-start.sh)
PORT_NGINX="${PORT_NGINX:-80}"
PORT_GRAFANA="${PORT_GRAFANA:-8080}"
PORT_PGBOUNCER="${PORT_PGBOUNCER:-5432}"
PORT_SIMULATOR="${PORT_SIMULATOR:-8081}"
PORT_UMH="${PORT_UMH:-8090}"
PORT_OPCUA_START="${PORT_OPCUA_START:-4840}"
PORT_MODBUS="${PORT_MODBUS:-502}"
SELECTED_LINES="${SELECTED_LINES:-automotive-welding:1}"

DEFAULT_PORT_NGINX=80
DEFAULT_PORT_GRAFANA=8080
DEFAULT_PORT_PGBOUNCER=5432
DEFAULT_PORT_SIMULATOR=8081
DEFAULT_PORT_UMH=8090
DEFAULT_PORT_OPCUA_START=4840
DEFAULT_PORT_MODBUS=502

echo -e "${BLUE}=== Builder Phase 1: Generate ===${NC}"
echo ""

# ============================================================
# Load machine metadata from machines/*.yaml
# ============================================================
declare -A META_DISPLAY_NAME
declare -A META_TYPE_TAGS  # machine-name -> "tag1|unit1;;tag2|unit2;;..."

load_metadata() {
    local machines_dir="$TEMPLATES_DIR/machines"
    if [ ! -d "$machines_dir" ]; then
        echo -e "${RED}Error: machines dir not found: $machines_dir${NC}"
        exit 1
    fi

    for machine_file in "$machines_dir"/*.yaml; do
        [ -f "$machine_file" ] || continue
        local machine_info
        machine_info=$(python3 -c "
import sys
from ruamel.yaml import YAML
yaml = YAML()
with open('$machine_file') as f:
    d = yaml.load(f)
print(d.get('name',''))
print(d.get('display_name',''))
# Extract type-specific tags (exclude base tags)
base_tags = {'state', 'cycle_count', 'good_count', 'scrap_count', 'cycle_time_ms', 'blocked_by_buffer'}
tags = []
for m in d.get('addressMappings', []):
    tag_name = m.get('TagName', '')
    unit = m.get('Unit', 'raw')
    if tag_name and tag_name not in base_tags:
        tags.append(f'{tag_name}|{unit}')
print(';;'.join(tags))
")
        local name display type_tags
        IFS=$'\n' read -r name display type_tags <<< "$machine_info"

        if [ -n "$name" ]; then
            META_DISPLAY_NAME["$name"]="$display"
            if [ -n "$type_tags" ]; then
                META_TYPE_TAGS["$name"]="$type_tags"
            fi
        fi
    done

    echo -e "${GREEN}  ✓ Loaded metadata for ${#META_DISPLAY_NAME[@]} machine types${NC}"
}

machine_display_name() {
    echo "${META_DISPLAY_NAME[$1]:-$1}"
}

echo "Loading machine metadata..."
load_metadata

# ============================================================
# Step 1: Validate existing docker-compose.yaml
# ============================================================
echo -e "${BLUE}Step 1: Validating docker-compose.yaml...${NC}"

if [ ! -f "$WORK_DIR/docker-compose.yaml" ]; then
    echo -e "${RED}Error: docker-compose.yaml not found in $WORK_DIR${NC}"
    exit 1
fi

# Check if umh or umh-core service exists (also handle already-renamed services from previous runs)
PROJECT_NAME="${PROJECT_NAME:-}"
UMH_SERVICE=""
if grep -q "^\s*umh:" "$WORK_DIR/docker-compose.yaml"; then
    UMH_SERVICE="umh"
elif grep -q "^\s*umh-core:" "$WORK_DIR/docker-compose.yaml"; then
    UMH_SERVICE="umh-core"
elif [ -n "$PROJECT_NAME" ] && grep -q "^\s*${PROJECT_NAME}-umh-core:" "$WORK_DIR/docker-compose.yaml"; then
    # Already renamed from a previous run
    UMH_SERVICE="umh-core"
elif [ -n "$PROJECT_NAME" ] && grep -q "^\s*${PROJECT_NAME}-umh:" "$WORK_DIR/docker-compose.yaml"; then
    # Already renamed from a previous run
    UMH_SERVICE="umh"
else
    echo -e "${RED}Error: 'umh' or 'umh-core' service not found in docker-compose.yaml${NC}"
    exit 1
fi

# Compute project-prefixed service name for multi-demo isolation
if [ -n "$PROJECT_NAME" ]; then
    NEW_UMH_SERVICE="${PROJECT_NAME}-${UMH_SERVICE}"
else
    NEW_UMH_SERVICE="$UMH_SERVICE"
fi

# Rename the service key in docker-compose.yaml if needed
if ! grep -q "^\s*${NEW_UMH_SERVICE}:" "$WORK_DIR/docker-compose.yaml"; then
    echo "  Renaming service '$UMH_SERVICE' -> '$NEW_UMH_SERVICE'..."
    python3 -c "
from ruamel.yaml import YAML
yaml = YAML()
yaml.preserve_quotes = True
with open('$WORK_DIR/docker-compose.yaml') as f:
    compose = yaml.load(f)
services = compose['services']
old_name = '$UMH_SERVICE'
new_name = '$NEW_UMH_SERVICE'
if old_name in services:
    # Preserve insertion order: rebuild with new key
    from ruamel.yaml.comments import CommentedMap
    new_services = CommentedMap()
    for k, v in services.items():
        if k == old_name:
            new_services[new_name] = v
            # Remove container_name to avoid conflicts between demos
            if 'container_name' in v:
                del v['container_name']
        else:
            new_services[k] = v
    compose['services'] = new_services
with open('$WORK_DIR/docker-compose.yaml', 'w') as f:
    yaml.dump(compose, f)
"
    echo -e "${GREEN}  ✓ Service renamed to $NEW_UMH_SERVICE${NC}"
else
    echo -e "${GREEN}  ✓ Service already named $NEW_UMH_SERVICE${NC}"
    # Still remove container_name if present (from older runs)
    python3 -c "
from ruamel.yaml import YAML
yaml = YAML()
yaml.preserve_quotes = True
with open('$WORK_DIR/docker-compose.yaml') as f:
    compose = yaml.load(f)
svc = compose['services'].get('$NEW_UMH_SERVICE', {})
if 'container_name' in svc:
    del svc['container_name']
    with open('$WORK_DIR/docker-compose.yaml', 'w') as f:
        yaml.dump(compose, f)
"
fi

echo -e "${GREEN}  ✓ docker-compose.yaml found with $UMH_SERVICE service (using as: $NEW_UMH_SERVICE)${NC}"

# ============================================================
# Step 2: Extract configuration from docker-compose.yaml
# ============================================================
echo -e "${BLUE}Step 2: Extracting configuration from docker-compose.yaml...${NC}"

LOCATION_0=$(grep -E '^\s*-\s*LOCATION_0=' "$WORK_DIR/docker-compose.yaml" | sed 's/.*LOCATION_0=//' | tr -d ' "'\' | head -1)
if [ -z "$LOCATION_0" ]; then
    LOCATION_0="UMH"
    echo -e "${YELLOW}  Warning: LOCATION_0 not found, using default: $LOCATION_0${NC}"
else
    echo -e "${GREEN}  ✓ LOCATION_0: $LOCATION_0${NC}"
fi

LOCATION_1=$(grep -E '^\s*-\s*LOCATION_1=' "$WORK_DIR/docker-compose.yaml" | sed 's/.*LOCATION_1=//' | tr -d ' "'\' | head -1)

AUTH_TOKEN=$(grep -E '^\s*-\s*AUTH_TOKEN=' "$WORK_DIR/docker-compose.yaml" | sed 's/.*AUTH_TOKEN=//' | tr -d ' "'\' | head -1)
if [ -z "$AUTH_TOKEN" ]; then
    echo -e "${RED}  Error: AUTH_TOKEN not found in docker-compose.yaml${NC}"
    exit 1
else
    echo -e "${GREEN}  ✓ AUTH_TOKEN: ${AUTH_TOKEN:0:8}...${NC}"
fi

RELEASE_CHANNEL=$(grep -E '^\s*-\s*RELEASE_CHANNEL=' "$WORK_DIR/docker-compose.yaml" | sed 's/.*RELEASE_CHANNEL=//' | tr -d ' "'\' | head -1)
if [ -z "$RELEASE_CHANNEL" ]; then
    RELEASE_CHANNEL="stable"
fi
echo -e "${GREEN}  ✓ RELEASE_CHANNEL: $RELEASE_CHANNEL${NC}"

API_URL=$(grep -E '^\s*-\s*API_URL=' "$WORK_DIR/docker-compose.yaml" | sed 's/.*API_URL=//' | tr -d ' "'\' | head -1)
if [ -z "$API_URL" ]; then
    API_URL="https://management.umh.app/api"
fi
echo -e "${GREEN}  ✓ API_URL: $API_URL${NC}"

# ============================================================
# Step 3: Dynamic factory configuration from SELECTED_LINES
# ============================================================
echo ""
echo -e "${BLUE}Step 3: Setting up factory layout from line selection...${NC}"
echo ""

declare -a LINE_NAMES
declare -a LINE_MACHINES
declare -a STANDALONE_MACHINES
STANDALONE_MACHINES=()

SIMULATOR_PROFILE=""
LINE_CONFIG_DIR="$TEMPLATES_DIR/config/simulator-config/lines"

# Parse SELECTED_LINES env var (format: "line-name:count,line-name:count,..." or "__profile__:name")
if [[ "$SELECTED_LINES" == "__profile__:"* ]]; then
    SIMULATOR_PROFILE="${SELECTED_LINES#__profile__:}"
    echo "  Using simulator profile: $SIMULATOR_PROFILE"

    # Read profile to get line templates
    PROFILE_FILE="$TEMPLATES_DIR/config/simulator-config/profiles/${SIMULATOR_PROFILE}.yaml"
    if [ ! -f "$PROFILE_FILE" ]; then
        echo -e "${RED}  Error: Profile not found: $PROFILE_FILE${NC}"
        exit 1
    fi

    # Parse profile YAML to get line selections
    SELECTED_LINES=$(python3 -c "
from ruamel.yaml import YAML
yaml = YAML()
with open('$PROFILE_FILE') as f:
    p = yaml.load(f)
parts = []
for l in p.get('lines', []):
    parts.append(f\"{l['template']}:{l.get('instances', 1)}\")
print(','.join(parts))
")
    echo "  Resolved lines: $SELECTED_LINES"
fi

# Parse line selections and read machine sequences from line template YAMLs
LINE_IDX=0
TOTAL_MACHINES=0
IFS=',' read -ra LINE_ENTRIES <<< "$SELECTED_LINES"

# Sort entries alphabetically by template name for deterministic port assignment
# (must match simulator's sorted line ordering in LoadFromLineEnvVars)
IFS=$'\n' LINE_ENTRIES=($(sort <<<"${LINE_ENTRIES[*]}")); unset IFS

for entry in "${LINE_ENTRIES[@]}"; do
    LINE_TEMPLATE="${entry%%:*}"
    LINE_COUNT="${entry##*:}"
    LINE_COUNT="${LINE_COUNT:-1}"

    # Find line template YAML
    LINE_YAML=$(find "$LINE_CONFIG_DIR" -name "*.yaml" -exec grep -l "name: \"${LINE_TEMPLATE}\"" {} \; | head -1)
    if [ -z "$LINE_YAML" ]; then
        echo -e "${RED}  Error: Line template not found: $LINE_TEMPLATE${NC}"
        exit 1
    fi

    # Extract machine types from line template
    MACHINES_CSV=$(python3 -c "
from ruamel.yaml import YAML
yaml = YAML()
with open('$LINE_YAML') as f:
    d = yaml.load(f)
types = [m['type'].replace('_', '-') for m in d.get('machines', [])]
print(','.join(types))
")

    IFS=',' read -ra MACHINE_LIST <<< "$MACHINES_CSV"
    MACHINE_COUNT=${#MACHINE_LIST[@]}

    for ((inst=1; inst<=LINE_COUNT; inst++)); do
        BASE_DISPLAY=$(echo "$LINE_TEMPLATE" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1))substr($i,2)}1' | tr ' ' '-')
        if [ "$LINE_COUNT" -eq 1 ]; then
            LINE_DISPLAY_NAME="$BASE_DISPLAY"
        else
            LINE_DISPLAY_NAME="${BASE_DISPLAY}-${inst}"
        fi

        LINE_NAMES+=("$LINE_DISPLAY_NAME")
        LINE_MACHINES[$LINE_IDX]="$MACHINES_CSV"
        LINE_IDX=$((LINE_IDX + 1))
        TOTAL_MACHINES=$((TOTAL_MACHINES + MACHINE_COUNT))

        echo "  Line $LINE_IDX: $LINE_DISPLAY_NAME ($MACHINE_COUNT machines)"
        echo "    Machines: $(echo "$MACHINES_CSV" | tr ',' ' -> ')"
    done
done

OPCUA_COUNT=$TOTAL_MACHINES
OPCUA_END=$((PORT_OPCUA_START + OPCUA_COUNT - 1))

echo ""
echo -e "${GREEN}Factory configuration: ${#LINE_NAMES[@]} lines, $TOTAL_MACHINES machines total${NC}"

# ============================================================
# Step 4: Merge additional services into docker-compose.yaml
# ============================================================
echo ""
echo -e "${BLUE}Step 4: Merging additional services into docker-compose.yaml...${NC}"

SERVICES_TO_ADD=()
for svc in grafana pgbouncer timescaledb machine-simulator nginx; do
    if ! grep -q "^\s*$svc:" "$WORK_DIR/docker-compose.yaml"; then
        SERVICES_TO_ADD+=("$svc")
    else
        echo -e "${YELLOW}  Service '$svc' already exists, skipping${NC}"
    fi
done

if [ ${#SERVICES_TO_ADD[@]} -gt 0 ]; then
    echo "  Adding services: ${SERVICES_TO_ADD[*]}"

    # Create backup
    cp "$WORK_DIR/docker-compose.yaml" "$WORK_DIR/docker-compose.yaml.backup"
    echo -e "${BLUE}  Backup created: docker-compose.yaml.backup${NC}"

    # YAML-aware merge using Python
    python3 -c "
from ruamel.yaml import YAML
yaml = YAML()
yaml.preserve_quotes = True

with open('$WORK_DIR/docker-compose.yaml') as f:
    user = yaml.load(f)
with open('$TEMPLATES_DIR/config/docker-compose.yaml') as f:
    template = yaml.load(f)

# Merge services
if 'services' not in user:
    user['services'] = {}
for svc, cfg in template.get('services', {}).items():
    if svc not in user['services']:
        user['services'][svc] = cfg

# Merge networks
for net, cfg in template.get('networks', {}).items():
    if 'networks' not in user:
        user['networks'] = {}
    if net not in user['networks']:
        user['networks'][net] = cfg

# Remove top-level named volumes (replaced by local bind mounts)
if 'volumes' in user:
    del user['volumes']

with open('$WORK_DIR/docker-compose.yaml', 'w') as f:
    yaml.dump(user, f)
"

    echo -e "${GREEN}  ✓ Services merged${NC}"
else
    echo -e "${GREEN}  ✓ All services already present${NC}"
fi

# ============================================================
# Step 5: Replace named volume with local volume
# ============================================================
echo ""
echo -e "${BLUE}Step 5: Checking for named volume configuration...${NC}"

if grep -E -- '- [a-zA-Z][a-zA-Z0-9_-]*:/data' "$WORK_DIR/docker-compose.yaml" | grep -qv '\./'; then
    echo "  Found named volume, converting to local..."

    if [ ! -f "$WORK_DIR/docker-compose.yaml.backup" ]; then
        cp "$WORK_DIR/docker-compose.yaml" "$WORK_DIR/docker-compose.yaml.backup"
    fi

    sed -i 's/\(- \)[a-zA-Z][a-zA-Z0-9_-]*:\/data/\1.\/umh-core-data:\/data/g' "$WORK_DIR/docker-compose.yaml"

    echo -e "${GREEN}  ✓ Replaced with local volume ./umh-core-data:/data${NC}"
else
    echo -e "${GREEN}  ✓ Already using local volume or no volume configured${NC}"
fi

# ============================================================
# Step 6: Copy required runtime directories
# ============================================================
echo ""
echo -e "${BLUE}Step 6: Copying required runtime directories...${NC}"

# Copy grafana-provisioning from config/
if [ -d "$TEMPLATES_DIR/config/grafana-provisioning" ]; then
    mkdir -p "$WORK_DIR/grafana-provisioning"
    cp -r "$TEMPLATES_DIR/config/grafana-provisioning/"* "$WORK_DIR/grafana-provisioning/"
    echo -e "${GREEN}  ✓ Copied: grafana-provisioning/${NC}"
fi

# Copy nginx config from config/
if [ -f "$TEMPLATES_DIR/config/nginx.conf" ]; then
    mkdir -p "$WORK_DIR/configs"
    cp "$TEMPLATES_DIR/config/nginx.conf" "$WORK_DIR/configs/nginx.conf"
    echo -e "${GREEN}  ✓ Copied: configs/nginx.conf${NC}"
fi

# Copy SQL files
if [ -d "$TEMPLATES_DIR/sql" ]; then
    mkdir -p "$WORK_DIR/sql"
    cp "$TEMPLATES_DIR/sql/"*.sql "$WORK_DIR/sql/"
    echo -e "${GREEN}  ✓ Copied: sql/${NC}"
fi

# Update dashboard provisioning (disable file-based, use API import)
if [ -d "$WORK_DIR/grafana-provisioning/dashboards" ]; then
    cp "$TEMPLATES_DIR/config/grafana-provisioning/dashboards/default.yaml" "$WORK_DIR/grafana-provisioning/dashboards/default.yaml"
fi

# Substitute __UMH_SERVICE__ placeholder in nginx config with the actual service name
if [ -f "$WORK_DIR/configs/nginx.conf" ]; then
    sed -i "s|__UMH_SERVICE__|${NEW_UMH_SERVICE}|g" "$WORK_DIR/configs/nginx.conf"
    echo -e "${GREEN}  ✓ Updated nginx.conf to use service name: $NEW_UMH_SERVICE${NC}"
fi

# ============================================================
# Step 7: Create directories
# ============================================================
echo ""
echo -e "${BLUE}Step 7: Creating required directories...${NC}"

mkdir -p "$WORK_DIR/umh-core-data/backups"
mkdir -p "$WORK_DIR/umh-config/backups"
mkdir -p "$WORK_DIR/grafana"
mkdir -p "$WORK_DIR/grafana-data"
mkdir -p "$WORK_DIR/timescaledb-data"
mkdir -p "$WORK_DIR/simulator-data"
mkdir -p "$WORK_DIR/dashboards"
mkdir -p "$WORK_DIR/simulator-config"
echo -e "${GREEN}  ✓ All directories created${NC}"

# Copy reset-demo script
if [ -f "$TEMPLATES_DIR/reset-demo" ]; then
    cp "$TEMPLATES_DIR/reset-demo" "$WORK_DIR/reset-demo"
    chmod +x "$WORK_DIR/reset-demo"
    echo -e "${GREEN}  ✓ Copied: reset-demo${NC}"
fi

# Copy simulator config directory
if [ -d "$TEMPLATES_DIR/config/simulator-config" ]; then
    cp -r "$TEMPLATES_DIR/config/simulator-config/"* "$WORK_DIR/simulator-config/"
    LINE_COUNT=$(find "$WORK_DIR/simulator-config/lines" -name "*.yaml" 2>/dev/null | wc -l)
    echo -e "${GREEN}  ✓ Simulator config copied (${LINE_COUNT} line templates)${NC}"
else
    echo -e "${RED}  Error: Simulator config not found${NC}"
    exit 1
fi

# ============================================================
# Step 8: Setup Grafana branding
# ============================================================
echo ""
echo -e "${BLUE}Step 8: Setting up Grafana branding...${NC}"

# Image conversion helpers (using local imagemagick, not Docker)
convert_svg_to_png() {
    local input="$1"
    local output="$2"
    convert "$input" -resize 512x512 -background none "$output" 2>/dev/null
}

convert_to_png() {
    local input="$1"
    local output="$2"
    convert "$input" -resize 512x512 "$output" 2>/dev/null
}

embed_raster_in_svg() {
    local input="$1"
    local output="$2"

    local dims
    dims=$(identify -format "%wx%h" "$input" 2>/dev/null || echo "512x512")
    local width="${dims%x*}"
    local height="${dims#*x}"

    if [ -z "$width" ] || [ -z "$height" ]; then
        width=512
        height=512
    fi

    local mime_type="image/png"
    local input_lower
    input_lower=$(echo "$input" | tr '[:upper:]' '[:lower:]')
    case "$input_lower" in
        *.jpg|*.jpeg) mime_type="image/jpeg" ;;
        *.bmp) mime_type="image/bmp" ;;
    esac

    local base64_data
    base64_data=$(base64 < "$input" | tr -d '\n')

    cat > "$output" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
     width="$width" height="$height" viewBox="0 0 $width $height">
  <image width="$width" height="$height" xlink:href="data:$mime_type;base64,$base64_data"/>
</svg>
EOF
}

prepare_logo_images() {
    local img_dir="$1"
    local output_dir="$2"

    if [ -f "$img_dir/logo.svg" ] && [ -f "$img_dir/logo.png" ]; then
        cp "$img_dir/logo.svg" "$output_dir/logo.svg"
        cp "$img_dir/logo.png" "$output_dir/logo.png"
        echo "    Using existing logo.svg and logo.png pair"
        return 0
    fi

    local source_image=""
    for ext in svg png jpg jpeg bmp; do
        source_image=$(find "$img_dir" -maxdepth 1 -type f -iname "*.$ext" 2>/dev/null | head -1)
        [ -n "$source_image" ] && break
    done

    if [ -z "$source_image" ]; then
        return 1
    fi

    local ext="${source_image##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    local source_name
    source_name=$(basename "$source_image")

    echo "    Found source image: $source_name"

    case "$ext" in
        svg)
            cp "$source_image" "$output_dir/logo.svg"
            echo "    Converting SVG to PNG..."
            if convert_svg_to_png "$source_image" "$output_dir/logo.png"; then
                echo "    ✓ Created logo.png from SVG"
            else
                return 1
            fi
            ;;
        png)
            cp "$source_image" "$output_dir/logo.png"
            echo "    Embedding PNG in SVG wrapper..."
            embed_raster_in_svg "$source_image" "$output_dir/logo.svg"
            echo "    ✓ Created logo.svg from PNG"
            ;;
        jpg|jpeg|bmp)
            echo "    Converting $ext to PNG..."
            if convert_to_png "$source_image" "$output_dir/logo.png"; then
                echo "    ✓ Created logo.png from $ext"
                echo "    Embedding in SVG wrapper..."
                embed_raster_in_svg "$output_dir/logo.png" "$output_dir/logo.svg"
                echo "    ✓ Created logo.svg"
            else
                return 1
            fi
            ;;
    esac

    return 0
}

echo "  Preparing logo images..."
mkdir -p "$WORK_DIR/grafana"

LOGO_PREPARED=false
# Check factory root directory first
if prepare_logo_images "$WORK_DIR" "$WORK_DIR/grafana"; then
    echo -e "${GREEN}  ✓ Logo prepared from workspace root${NC}"
    LOGO_PREPARED=true
elif [ -d "$WORK_DIR/img" ] && prepare_logo_images "$WORK_DIR/img" "$WORK_DIR/grafana"; then
    echo -e "${GREEN}  ✓ Logo prepared from workspace img/${NC}"
    LOGO_PREPARED=true
elif [ -d "$TEMPLATES_DIR/img" ] && prepare_logo_images "$TEMPLATES_DIR/img" "$WORK_DIR/grafana"; then
    echo -e "${GREEN}  ✓ Logo prepared from templates${NC}"
    LOGO_PREPARED=true
else
    echo -e "${YELLOW}  Using default UMH logo${NC}"
    cp "$TEMPLATES_DIR/img/umh.svg" "$WORK_DIR/grafana/logo.svg"
    cp "$TEMPLATES_DIR/img/umh.png" "$WORK_DIR/grafana/logo.png"
    LOGO_PREPARED=true
fi

# Create Grafana Dockerfile with branding
cat > "$WORK_DIR/grafana/Dockerfile" << EOF
FROM management.umh.app/oci/grafana/grafana:12.3.0

# Change Grafana title to "${LOCATION_0}"
RUN find /usr/share/grafana/public/build/ -name '*.js' -exec sed -i 's|AppTitle="Grafana"|AppTitle="${LOCATION_0}"|g' {} \;

# Change "Welcome to Grafana" to "Welcome to ${LOCATION_0}"
RUN find /usr/share/grafana/public/build/ -name '*.js' -exec sed -i 's|Welcome to Grafana|Welcome to ${LOCATION_0}|g' {} \;

# Copy custom logos and icons
COPY logo.svg /usr/share/grafana/public/img/grafana_icon.svg
COPY logo.svg /usr/share/grafana/public/img/g8_login_dark.svg
COPY logo.svg /usr/share/grafana/public/img/g8_login_light.svg
COPY logo.svg /usr/share/grafana/public/img/grafana_typelogo.svg
COPY logo.svg /usr/share/grafana/public/img/grafana_com_auth_icon.svg
COPY logo.svg /usr/share/grafana/public/img/icons/mono/grafana.svg
COPY fav32.png /usr/share/grafana/public/img/fav32.png
COPY apple-touch-icon.png /usr/share/grafana/public/img/apple-touch-icon.png

# Copy to build directory
COPY logo.svg /usr/share/grafana/public/build/img/grafana_icon.svg
RUN find /usr/share/grafana/public/build/static/img -name 'grafana_icon*.svg' -exec cp /usr/share/grafana/public/build/img/grafana_icon.svg {} \;
EOF

# Generate favicon and touch-icon using local imagemagick
echo "  Generating favicon and touch-icon..."
if [ -f "$WORK_DIR/grafana/logo.png" ]; then
    convert "$WORK_DIR/grafana/logo.png" -resize 32x32 "$WORK_DIR/grafana/fav32.png" 2>/dev/null \
        || cp "$WORK_DIR/grafana/logo.png" "$WORK_DIR/grafana/fav32.png"
    convert "$WORK_DIR/grafana/logo.png" -resize 180x180 "$WORK_DIR/grafana/apple-touch-icon.png" 2>/dev/null \
        || cp "$WORK_DIR/grafana/logo.png" "$WORK_DIR/grafana/apple-touch-icon.png"
else
    convert "$WORK_DIR/grafana/logo.svg" -resize 32x32 "$WORK_DIR/grafana/fav32.png" 2>/dev/null || true
    convert "$WORK_DIR/grafana/logo.svg" -resize 180x180 "$WORK_DIR/grafana/apple-touch-icon.png" 2>/dev/null || true
fi

# Ensure favicon files exist (create minimal placeholder if needed)
if [ ! -f "$WORK_DIR/grafana/fav32.png" ]; then
    printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n-\xb4\x00\x00\x00\x00IEND\xaeB`\x82' > "$WORK_DIR/grafana/fav32.png"
fi
if [ ! -f "$WORK_DIR/grafana/apple-touch-icon.png" ]; then
    cp "$WORK_DIR/grafana/fav32.png" "$WORK_DIR/grafana/apple-touch-icon.png"
fi
echo -e "${GREEN}  ✓ Grafana branding configured for: $LOCATION_0${NC}"

# Generate ref IDs for Grafana targets: A-Z, then AA, AB, etc.
gen_ref_id() {
    local idx=$1
    if [ $idx -lt 26 ]; then
        printf "\\$(printf '%03o' $((65 + idx)))"
    else
        local first=$(( (idx / 26) - 1 ))
        local second=$(( idx % 26 ))
        printf "\\$(printf '%03o' $((65 + first)))\\$(printf '%03o' $((65 + second)))"
    fi
}

# ============================================================
# Step 8b: Generate Grafana dashboards
# ============================================================
echo ""
echo -e "${BLUE}Step 8b: Generating Grafana dashboards...${NC}"

mkdir -p "$WORK_DIR/dashboards"
rm -f "$WORK_DIR/dashboards/"*.json 2>/dev/null || true

AREA="shopfloor"

# --- Generate per-line OEE dashboards ---
LINE_NUM=0
for ((i=0; i<${#LINE_NAMES[@]}; i++)); do
    LINE_NUM=$((i + 1))
    LINE_NAME="${LINE_NAMES[$i]}"
    LINE_LOWER=$(echo "$LINE_NAME" | tr '[:upper:]' '[:lower:]')
    LINE_DISPLAY="Line ${LINE_NUM}"

    echo "  Generating dashboard for $LINE_DISPLAY ($LINE_NAME)..."

    IFS=',' read -ra MACHINES <<< "${LINE_MACHINES[$i]}"

    # Build state timeline targets JSON
    TARGETS_JSON="["
    for ((m=0; m<${#MACHINES[@]}; m++)); do
        MACHINE="${MACHINES[$m]}"
        POS=$((m + 1))
        WORKCELL=$(printf "%s-L%d-%02d" "$MACHINE" "$LINE_NUM" "$POS")
        DISPLAY="$(machine_display_name "$MACHINE") (Pos ${POS})"

        if [ $m -gt 0 ]; then
            TARGETS_JSON+=","
        fi
        REF=$(gen_ref_id $m)
        DISPLAY_ESC=$(echo "$DISPLAY" | sed 's/"/\\"/g')
        TARGETS_JSON+="
        {
          \"datasource\": {\"type\": \"grafana-postgresql-datasource\", \"uid\": \"df9o2whw2o7wgb\"},
          \"editorMode\": \"code\",
          \"format\": \"time_series\",
          \"rawQuery\": true,
          \"rawSql\": \"SELECT time, value as \\\"${DISPLAY_ESC}\\\" FROM get_state_timeline('${LOCATION_0}', '${LOCATION_1}', '${AREA}', '${LINE_LOWER}', '${WORKCELL}', \$__timeFrom(), \$__timeTo())\",
          \"refId\": \"${REF}\"
        }"
    done
    TARGETS_JSON+="]"

    # Read template, replace placeholders, inject state timeline targets
    sed \
        -e "s|__ENTERPRISE__|${LOCATION_0}|g" \
        -e "s|__SITE__|${LOCATION_1}|g" \
        -e "s|__AREA__|${AREA}|g" \
        -e "s|__LINE__|${LINE_LOWER}|g" \
        -e "s|__LINE_DISPLAY__|${LINE_DISPLAY}|g" \
        "$TEMPLATES_DIR/templates/dashboards/line-oee-dashboard.json" \
        > "$WORK_DIR/dashboards/${LINE_LOWER}-oee-dashboard.json.tmp"

    echo "$TARGETS_JSON" > "$WORK_DIR/dashboards/.targets_tmp.json"
    jq --slurpfile targets "$WORK_DIR/dashboards/.targets_tmp.json" \
        '(.panels[] | select(.targets == "__STATE_TIMELINE_TARGETS__")).targets = $targets[0]' \
        "$WORK_DIR/dashboards/${LINE_LOWER}-oee-dashboard.json.tmp" \
        > "$WORK_DIR/dashboards/${LINE_LOWER}-oee-dashboard.json"
    rm -f "$WORK_DIR/dashboards/${LINE_LOWER}-oee-dashboard.json.tmp"
    rm -f "$WORK_DIR/dashboards/.targets_tmp.json"
    echo -e "${GREEN}    ✓ ${LINE_LOWER}-oee-dashboard.json${NC}"

    # --- Generate per-workcell machine dashboards ---
    for ((m=0; m<${#MACHINES[@]}; m++)); do
        MACHINE="${MACHINES[$m]}"
        POS=$((m + 1))
        WORKCELL=$(printf "%s-L%d-%02d" "$MACHINE" "$LINE_NUM" "$POS")
        WC_DISPLAY="$(machine_display_name "$MACHINE") (Pos ${POS})"
        WC_DISPLAY_ESCAPED="${WC_DISPLAY//&/\\&}"

        # Apply standard sed replacements
        sed \
            -e "s|__ENTERPRISE__|${LOCATION_0}|g" \
            -e "s|__SITE__|${LOCATION_1}|g" \
            -e "s|__AREA__|${AREA}|g" \
            -e "s|__LINE__|${LINE_LOWER}|g" \
            -e "s|__LINE_DISPLAY__|${LINE_DISPLAY}|g" \
            -e "s|__WORKCELL__|${WORKCELL}|g" \
            -e "s|__MACHINE_DISPLAY__|${WC_DISPLAY_ESCAPED}|g" \
            "$TEMPLATES_DIR/templates/dashboards/machine-dashboard.json" \
            > "$WORK_DIR/dashboards/${LINE_LOWER}-${WORKCELL}-dashboard.json.tmp"

        # Generate type-specific panels from machine metadata
        TYPE_TAGS="${META_TYPE_TAGS[$MACHINE]:-}"
        if [ -n "$TYPE_TAGS" ]; then
            PANELS_JSON=$(python3 -c "
import json, sys
tags_str = '''${TYPE_TAGS}'''
enterprise = '${LOCATION_0}'
site = '${LOCATION_1}'
area = '${AREA}'
line = '${LINE_LOWER}'
workcell = '${WORKCELL}'
wc_display = '${WC_DISPLAY}'

panels = []
tag_entries = [t for t in tags_str.split(';;') if t]
for idx, entry in enumerate(tag_entries):
    parts = entry.split('|', 1)
    tag_name = parts[0]
    unit = parts[1] if len(parts) > 1 else 'raw'

    # Generate display name: press_force_kn -> Press Force (kN)
    # Extract unit hint from tag name suffix
    name_parts = tag_name.split('_')
    # Check if last part is a unit suffix
    unit_suffixes = {'kn': 'kN', 'bar': 'bar', 'c': chr(176)+'C', 'mm': 'mm', 'pct': '%',
                     's': 's', 'a': 'A', 'db': 'dB', 'kwh': 'kWh', 'rpm': 'RPM',
                     'hz': 'Hz', 'v': 'V', 'w': 'W', 'pa': 'Pa', 'lpm': 'L/min',
                     'ms': 'ms', 'um': chr(181)+'m', 'deg': chr(176), 'mpa': 'MPa',
                     'mp': 'MP', 'lux': 'lux', 'ml': 'mL'}
    display_unit = unit if unit != 'raw' else ''
    title_words = [w.capitalize() for w in name_parts]
    # Remove unit suffix from title if last word matches
    if name_parts[-1].lower() in unit_suffixes:
        display_unit = unit_suffixes[name_parts[-1].lower()]
        title_words = title_words[:-1]
    # Also handle two-word unit suffixes like mm_s
    if len(name_parts) >= 2:
        combo = name_parts[-2].lower() + '_' + name_parts[-1].lower()
        if combo in ('mm_s',):
            display_unit = 'mm/s'
            title_words = title_words[:-2]
        elif combo in ('cm2_s',):
            display_unit = 'cm'+chr(178)+'/s'
            title_words = title_words[:-2]

    title = ' '.join(title_words)
    if display_unit:
        title += f' ({display_unit})'

    col = idx % 2
    row = idx // 2
    x = col * 12
    y = 10 + row * 8

    sql = f\"SELECT time, value as \\\"{tag_name}\\\" FROM get_tag_timeseries(get_asset_id_immutable('{enterprise}', '{site}', '{area}', '{line}', '{workcell}'), '{tag_name}', \$__timeFrom(), \$__timeTo())\"

    panel = {
        'datasource': {'type': 'grafana-postgresql-datasource', 'uid': 'df9o2whw2o7wgb'},
        'fieldConfig': {
            'defaults': {
                'color': {'mode': 'palette-classic'},
                'custom': {
                    'axisBorderShow': False, 'axisCenteredZero': False,
                    'axisColorMode': 'text', 'axisLabel': '', 'axisPlacement': 'auto',
                    'barAlignment': 0, 'barWidthFactor': 0.6, 'drawStyle': 'line',
                    'fillOpacity': 0, 'gradientMode': 'none',
                    'hideFrom': {'legend': False, 'tooltip': False, 'viz': False},
                    'insertNulls': False, 'lineInterpolation': 'linear', 'lineWidth': 1,
                    'pointSize': 5, 'scaleDistribution': {'type': 'linear'},
                    'showPoints': 'auto', 'showValues': False, 'spanNulls': False,
                    'stacking': {'group': 'A', 'mode': 'none'},
                    'thresholdsStyle': {'mode': 'off'}
                },
                'mappings': [],
                'thresholds': {'mode': 'absolute', 'steps': [{'color': 'green', 'value': 0}]}
            },
            'overrides': []
        },
        'gridPos': {'h': 8, 'w': 12, 'x': x, 'y': y},
        'id': None,
        'options': {
            'legend': {'calcs': [], 'displayMode': 'list', 'placement': 'bottom', 'showLegend': True},
            'tooltip': {'hideZeros': False, 'mode': 'single', 'sort': 'none'}
        },
        'pluginVersion': '12.3.0',
        'targets': [{
            'editorMode': 'code', 'format': 'time_series', 'rawQuery': True,
            'rawSql': sql, 'refId': 'A'
        }],
        'title': title,
        'type': 'timeseries'
    }
    panels.append(panel)

print(json.dumps(panels))
")
        else
            PANELS_JSON="[]"
        fi

        # Use jq to replace the __TYPE_SPECIFIC_PANELS__ placeholder with generated panels
        echo "$PANELS_JSON" > "$WORK_DIR/dashboards/.type_panels_tmp.json"
        jq --slurpfile type_panels "$WORK_DIR/dashboards/.type_panels_tmp.json" \
            '[.panels[] | if . == "__TYPE_SPECIFIC_PANELS__" then $type_panels[0][] else . end] as $new_panels | .panels = $new_panels' \
            "$WORK_DIR/dashboards/${LINE_LOWER}-${WORKCELL}-dashboard.json.tmp" \
            > "$WORK_DIR/dashboards/${LINE_LOWER}-${WORKCELL}-dashboard.json"
        rm -f "$WORK_DIR/dashboards/${LINE_LOWER}-${WORKCELL}-dashboard.json.tmp"
        rm -f "$WORK_DIR/dashboards/.type_panels_tmp.json"
        echo -e "${GREEN}    ✓ ${LINE_LOWER}-${WORKCELL}-dashboard.json${NC}"
    done
done

# --- Generate factory overview dashboard ---
echo "  Generating factory overview dashboard..."

FACTORY_TARGETS_JSON="["
TARGET_IDX=0
for ((i=0; i<${#LINE_NAMES[@]}; i++)); do
    F_LINE_NUM=$((i + 1))
    LINE_NAME="${LINE_NAMES[$i]}"
    LINE_LOWER=$(echo "$LINE_NAME" | tr '[:upper:]' '[:lower:]')
    LINE_DISPLAY="Line ${F_LINE_NUM}"
    IFS=',' read -ra MACHINES <<< "${LINE_MACHINES[$i]}"
    for ((m=0; m<${#MACHINES[@]}; m++)); do
        MACHINE="${MACHINES[$m]}"
        POS=$((m + 1))
        WORKCELL=$(printf "%s-L%d-%02d" "$MACHINE" "$F_LINE_NUM" "$POS")
        DISPLAY="${LINE_DISPLAY}: $(machine_display_name "$MACHINE") (Pos ${POS})"

        if [ $TARGET_IDX -gt 0 ]; then
            FACTORY_TARGETS_JSON+=","
        fi
        REF=$(gen_ref_id $TARGET_IDX)
        DISPLAY_ESC=$(echo "$DISPLAY" | sed 's/"/\\"/g')
        FACTORY_TARGETS_JSON+="
        {
          \"datasource\": {\"type\": \"grafana-postgresql-datasource\", \"uid\": \"df9o2whw2o7wgb\"},
          \"editorMode\": \"code\",
          \"format\": \"time_series\",
          \"rawQuery\": true,
          \"rawSql\": \"SELECT time, value as \\\"${DISPLAY_ESC}\\\" FROM get_state_timeline('${LOCATION_0}', '${LOCATION_1}', '${AREA}', '${LINE_LOWER}', '${WORKCELL}', \$__timeFrom(), \$__timeTo())\",
          \"refId\": \"${REF}\"
        }"
        TARGET_IDX=$((TARGET_IDX + 1))
    done
done
FACTORY_TARGETS_JSON+="]"

# Copy dashboards that don't need placeholders
cp "$TEMPLATES_DIR/templates/dashboards/site-leader-board.json" "$WORK_DIR/dashboards/site-leader-board.json"
echo -e "${GREEN}    ✓ site-leader-board.json${NC}"

cp "$TEMPLATES_DIR/templates/dashboards/production-manager-view.json" "$WORK_DIR/dashboards/production-manager-view.json"
echo -e "${GREEN}    ✓ production-manager-view.json${NC}"

cp "$TEMPLATES_DIR/templates/dashboards/andon-board.json" "$WORK_DIR/dashboards/andon-board.json"
echo -e "${GREEN}    ✓ andon-board.json${NC}"

cp "$TEMPLATES_DIR/templates/dashboards/margin-leakage-dashboard.json" "$WORK_DIR/dashboards/margin-leakage-dashboard.json"
echo -e "${GREEN}    ✓ margin-leakage-dashboard.json${NC}"

# --- Generate factory line setup dashboard ---
echo "  Generating factory line setup dashboard..."

SETUP_SVG="<div style='font-family: sans-serif; padding: 10px;'>"

LINE_NUM=0
for ((i=0; i<${#LINE_NAMES[@]}; i++)); do
    LINE_NUM=$((i + 1))
    LINE_NAME="${LINE_NAMES[$i]}"
    IFS=',' read -ra MACHINES <<< "${LINE_MACHINES[$i]}"

    SETUP_SVG+="<div style='margin-bottom: 16px;'>"
    SETUP_SVG+="<div style='font-size: 14px; font-weight: bold; margin-bottom: 8px; color: #58A6FF;'>Line ${LINE_NUM}: ${LINE_NAME} (${#MACHINES[@]} machines)</div>"
    SETUP_SVG+="<div style='display: flex; align-items: center; gap: 4px; flex-wrap: wrap;'>"

    for ((m=0; m<${#MACHINES[@]}; m++)); do
        MACHINE="${MACHINES[$m]}"
        WC_DISPLAY="$(machine_display_name "$MACHINE")"

        if [ $m -gt 0 ]; then
            SETUP_SVG+="<div style='font-size: 20px; color: #47A0B5;'>&#x2192;</div>"
        fi

        SETUP_SVG+="<div style='border: 2px solid #47A0B5; border-radius: 8px; padding: 8px 14px; background: #21262D; text-align: center; min-width: 100px;'>"
        SETUP_SVG+="<div style='font-size: 12px; font-weight: bold; color: #E6EDF3;'>${WC_DISPLAY}</div>"
        SETUP_SVG+="<div style='font-size: 10px; color: #8B949E;'>Pos $((m+1))</div>"
        SETUP_SVG+="</div>"
    done

    SETUP_SVG+="</div></div>"
done

if [ ${#STANDALONE_MACHINES[@]} -gt 0 ]; then
    SETUP_SVG+="<div style='margin-bottom: 16px;'>"
    SETUP_SVG+="<div style='font-size: 14px; font-weight: bold; margin-bottom: 8px; color: #D29922;'>Standalone Machines</div>"
    SETUP_SVG+="<div style='display: flex; align-items: center; gap: 8px; flex-wrap: wrap;'>"
    for machine in "${STANDALONE_MACHINES[@]}"; do
        WC_DISPLAY="$(machine_display_name "$machine")"
        SETUP_SVG+="<div style='border: 2px solid #D29922; border-radius: 8px; padding: 8px 14px; background: #21262D; text-align: center; min-width: 100px;'>"
        SETUP_SVG+="<div style='font-size: 12px; font-weight: bold; color: #E6EDF3;'>${WC_DISPLAY}</div>"
        SETUP_SVG+="</div>"
    done
    SETUP_SVG+="</div></div>"
fi

SETUP_SVG+="</div>"

ASSET_FILTER="get_asset_ids_stable('${LOCATION_0}', '${LOCATION_1}', '', '', '')"
MACHINE_STATUS_SQL="SELECT * FROM get_machine_status_table('${LOCATION_0}', '${LOCATION_1}', '', '', '')"

sed \
    -e "s|__ENTERPRISE__|${LOCATION_0}|g" \
    "$TEMPLATES_DIR/templates/dashboards/factory-line-setup-dashboard.json" \
    > "$WORK_DIR/dashboards/factory-line-setup-dashboard.json.tmp"

echo "$FACTORY_TARGETS_JSON" > "$WORK_DIR/dashboards/.targets_tmp.json"
jq --slurpfile targets "$WORK_DIR/dashboards/.targets_tmp.json" \
    --arg svg "$SETUP_SVG" \
    --arg sql "$MACHINE_STATUS_SQL" \
    '(.panels[] | select(.id == 1)).options.content = $svg |
     (.panels[] | select(.id == 2) | .targets[] | select(.rawSql == "__MACHINE_STATUS_SQL__")).rawSql = $sql |
     (.panels[] | select(.targets == "__SETUP_STATE_TIMELINE_TARGETS__")).targets = $targets[0]' \
    "$WORK_DIR/dashboards/factory-line-setup-dashboard.json.tmp" \
    > "$WORK_DIR/dashboards/factory-line-setup-dashboard.json"
rm -f "$WORK_DIR/dashboards/factory-line-setup-dashboard.json.tmp"
rm -f "$WORK_DIR/dashboards/.targets_tmp.json"
echo -e "${GREEN}    ✓ factory-line-setup-dashboard.json${NC}"

# ============================================================
# Step 9c: Apply port remappings to docker-compose.yaml
# ============================================================
echo ""
echo -e "${BLUE}Step 9c: Applying port remappings to docker-compose.yaml...${NC}"

if [ "$PORT_NGINX" != "$DEFAULT_PORT_NGINX" ]; then
    sed -i "s|\"80:80\"|\"${PORT_NGINX}:80\"|g" "$WORK_DIR/docker-compose.yaml"
    echo -e "${GREEN}  ✓ Nginx: $DEFAULT_PORT_NGINX -> $PORT_NGINX${NC}"
fi
if [ "$PORT_GRAFANA" != "$DEFAULT_PORT_GRAFANA" ]; then
    sed -i "s|\"8080:3000\"|\"${PORT_GRAFANA}:3000\"|g" "$WORK_DIR/docker-compose.yaml"
    sed -i "s|8080:3000|${PORT_GRAFANA}:3000|g" "$WORK_DIR/docker-compose.yaml"
    echo -e "${GREEN}  ✓ Grafana: $DEFAULT_PORT_GRAFANA -> $PORT_GRAFANA${NC}"
fi
if [ "$PORT_PGBOUNCER" != "$DEFAULT_PORT_PGBOUNCER" ]; then
    sed -i "s|\"5432:5432\"|\"${PORT_PGBOUNCER}:5432\"|g" "$WORK_DIR/docker-compose.yaml"
    sed -i "s|5432:5432|${PORT_PGBOUNCER}:5432|g" "$WORK_DIR/docker-compose.yaml"
    echo -e "${GREEN}  ✓ PostgreSQL: $DEFAULT_PORT_PGBOUNCER -> $PORT_PGBOUNCER${NC}"
fi
if [ "$PORT_SIMULATOR" != "$DEFAULT_PORT_SIMULATOR" ]; then
    sed -i "s|\"8081:8081\"|\"${PORT_SIMULATOR}:8081\"|g" "$WORK_DIR/docker-compose.yaml"
    echo -e "${GREEN}  ✓ Machine Simulator: $DEFAULT_PORT_SIMULATOR -> $PORT_SIMULATOR${NC}"
fi
if [ "$PORT_UMH" != "$DEFAULT_PORT_UMH" ]; then
    sed -i "s|\"8090:8090\"|\"${PORT_UMH}:8090\"|g" "$WORK_DIR/docker-compose.yaml"
    echo -e "${GREEN}  ✓ UMH Core: $DEFAULT_PORT_UMH -> $PORT_UMH${NC}"
fi
COMPOSE_OPCUA_END=$((4840 + OPCUA_COUNT - 1))
# Replace the default range in docker-compose with actual range needed
sed -i "s|\"4840-4880:4840-4880\"|\"${PORT_OPCUA_START}-$((PORT_OPCUA_START + OPCUA_COUNT - 1)):4840-${COMPOSE_OPCUA_END}\"|g" "$WORK_DIR/docker-compose.yaml"
if [ "$PORT_OPCUA_START" != "$DEFAULT_PORT_OPCUA_START" ]; then
    echo -e "${GREEN}  ✓ OPC-UA: $DEFAULT_PORT_OPCUA_START -> $PORT_OPCUA_START (range: $OPCUA_COUNT ports)${NC}"
else
    echo -e "${GREEN}  ✓ OPC-UA: range adjusted to $OPCUA_COUNT ports ($PORT_OPCUA_START-$OPCUA_END)${NC}"
fi
if [ "$PORT_MODBUS" != "$DEFAULT_PORT_MODBUS" ]; then
    sed -i "s|\"502:502\"|\"${PORT_MODBUS}:502\"|g" "$WORK_DIR/docker-compose.yaml"
    echo -e "${GREEN}  ✓ Modbus TCP: $DEFAULT_PORT_MODBUS -> $PORT_MODBUS${NC}"
fi

echo -e "${GREEN}  ✓ Port remappings applied${NC}"

# Inject simulator line env vars into docker-compose.yaml
# The simulator expects SIMULATOR_LINE_<TEMPLATE_UPPER>=<count> or SIMULATOR_PROFILE=<name>
python3 -c "
from ruamel.yaml import YAML
yaml = YAML()
yaml.preserve_quotes = True
with open('$WORK_DIR/docker-compose.yaml') as f:
    compose = yaml.load(f)
sim = compose['services']['machine-simulator']
env = sim.get('environment', [])

profile = '$SIMULATOR_PROFILE'
selected = '$SELECTED_LINES'

if profile:
    # Replace the placeholder with actual profile name
    env = [e for e in env if not (isinstance(e, str) and 'SIMULATOR_PROFILE' in e)]
    env.append('SIMULATOR_PROFILE=' + profile)
else:
    # Remove the empty SIMULATOR_PROFILE line
    env = [e for e in env if not (isinstance(e, str) and 'SIMULATOR_PROFILE' in e)]
    # Convert SELECTED_LINES to SIMULATOR_LINE_* env vars
    # Format: template-name:count,template-name:count
    for entry in selected.split(','):
        parts = entry.split(':')
        template = parts[0]
        count = parts[1] if len(parts) > 1 else '1'
        env_name = 'SIMULATOR_LINE_' + template.upper().replace('-', '_')
        env.append(env_name + '=' + count)

# Add webhook env vars pointing to erp-receiver inside umh-core
umh_service = '$NEW_UMH_SERVICE'
env.append(f'SIMULATOR_WEBHOOK_ENABLED=true')
env.append(f'SIMULATOR_WEBHOOK_TARGET_URL=http://{umh_service}:8090/api/v1/')

sim['environment'] = env
with open('$WORK_DIR/docker-compose.yaml', 'w') as f:
    yaml.dump(compose, f)
"
echo -e "${GREEN}  ✓ Simulator line env vars injected${NC}"

# Determine API base URL for form panels
HOST_IP="${HOST_IP:-localhost}"
API_BASE_URL="http://${HOST_IP}:${PORT_NGINX}"

# Generate stop-reason and operator dashboards (need API_BASE_URL)
echo ""
echo -e "${BLUE}Step 9d: Generating API-dependent dashboards...${NC}"
for dashboard in stop-reason-admin.json operator-dashboard.json; do
    if [ -f "$TEMPLATES_DIR/templates/dashboards/$dashboard" ]; then
        sed \
            -e "s|__API_BASE_URL__|${API_BASE_URL}|g" \
            -e "s|__ENTERPRISE__|${LOCATION_0}|g" \
            -e "s|__SITE__|${LOCATION_1}|g" \
            -e "s|__AREA__|shopfloor|g" \
            -e "s|__LINE__||g" \
            "$TEMPLATES_DIR/templates/dashboards/$dashboard" \
            > "$WORK_DIR/dashboards/$dashboard"
        echo -e "${GREEN}  ✓ $dashboard${NC}"
    fi
done

echo -e "${GREEN}  ✓ All dashboards generated${NC}"

# ============================================================
# Step 13: Generate factory setup file and new config
# ============================================================
echo ""
echo -e "${BLUE}Step 13: Generating new config...${NC}"

FACTORY_SETUP_FILE="$WORK_DIR/factory-setup.yaml"

echo "  Creating factory setup file..."
cat > "$FACTORY_SETUP_FILE" << EOF
# Factory configuration generated by builder
enterprise: "${LOCATION_0:-Enterprise}"
site: "${LOCATION_1:-Site}"
simulator_host: "machine-simulator"

EOF

if [ ${#LINE_NAMES[@]} -gt 0 ]; then
    echo "lines:" >> "$FACTORY_SETUP_FILE"
    for ((i=0; i<${#LINE_NAMES[@]}; i++)); do
        echo "  - name: \"${LINE_NAMES[$i]}\"" >> "$FACTORY_SETUP_FILE"
        echo "    enabled: true" >> "$FACTORY_SETUP_FILE"
        echo "    machines:" >> "$FACTORY_SETUP_FILE"
        IFS=',' read -ra MACHINES <<< "${LINE_MACHINES[$i]}"
        for machine in "${MACHINES[@]}"; do
            echo "      - $machine" >> "$FACTORY_SETUP_FILE"
        done
        echo "    buffer_size: 10" >> "$FACTORY_SETUP_FILE"
    done
    echo "" >> "$FACTORY_SETUP_FILE"
fi

if [ ${#STANDALONE_MACHINES[@]} -gt 0 ]; then
    echo "standalone:" >> "$FACTORY_SETUP_FILE"
    for machine in "${STANDALONE_MACHINES[@]}"; do
        echo "  - $machine" >> "$FACTORY_SETUP_FILE"
    done
fi

echo -e "${GREEN}  ✓ Factory setup file created${NC}"

# Generate config using local Python (pre-installed in builder)
mkdir -p "$WORK_DIR/umh-config"
echo "  Generating UMH config from factory setup..."

python3 "$SCRIPTS_DIR/generate-config.py" \
    --from-file "$FACTORY_SETUP_FILE" \
    --output-dir "$WORK_DIR/umh-config" \
    --templates-dir "$TEMPLATES_DIR/templates" \
    --machines-dir "$TEMPLATES_DIR/machines"

if [ ! -f "$WORK_DIR/umh-config/config.yaml" ]; then
    echo -e "${RED}  Error: Config generation failed${NC}"
    exit 1
fi
echo -e "${GREEN}  ✓ UMH-core config generated${NC}"

# Validate generated config
echo "  Validating generated config..."
if python3 "$SCRIPTS_DIR/validate-config.py" "$WORK_DIR/umh-config/config.yaml"; then
    echo -e "${GREEN}  ✓ Config validation passed${NC}"
else
    echo -e "${RED}  Config validation FAILED${NC}"
    exit 1
fi

# ============================================================
# Step 14: Verify agent section
# ============================================================
echo ""
echo -e "${BLUE}Step 14: Verifying agent section in config...${NC}"

if grep -q "^agent:" "$WORK_DIR/umh-config/config.yaml"; then
    echo -e "${GREEN}  ✓ Agent section present in config${NC}"
else
    echo -e "${RED}  Error: Agent section missing from config!${NC}"
    exit 1
fi

# ============================================================
# Step 15: Copy config to umh-core-data
# ============================================================
echo ""
echo -e "${BLUE}Step 15: Deploying config to umh-core-data...${NC}"

cp "$WORK_DIR/umh-config/config.yaml" "$WORK_DIR/umh-core-data/config.yaml"
echo -e "${GREEN}  ✓ Config copied to: umh-core-data/config.yaml${NC}"

# ============================================================
# Summary
# ============================================================
echo ""
echo -e "${GREEN}=== Phase 1 (Generate) Complete ===${NC}"
echo ""
echo "Summary:"
echo "  - Enterprise:  ${LOCATION_0:-Enterprise}"
echo "  - Site:        ${LOCATION_1:-Site}"
echo "  - Machines:    $TOTAL_MACHINES"
echo "  - Ports:"
echo "    Nginx:             ${PORT_NGINX}"
echo "    Grafana:           ${PORT_GRAFANA}"
echo "    PostgreSQL:        ${PORT_PGBOUNCER}"
echo "    Machine Simulator: ${PORT_SIMULATOR}"
echo "    UMH Core:          ${PORT_UMH}"
echo "    OPC-UA:            ${PORT_OPCUA_START}-${OPCUA_END}"
echo "    Modbus TCP:        ${PORT_MODBUS}"
echo ""
echo "Files generated in /workspace:"
echo "  - docker-compose.yaml (merged)"
echo "  - grafana/Dockerfile (branding)"
echo "  - dashboards/ (all dashboard JSON)"
echo "  - umh-core-data/config.yaml (UMH config)"
echo "  - grafana-provisioning/ (datasource config)"
echo "  - configs/ (nginx)"
echo "  - sql/ (schema init)"
echo "  - simulator-config/ (machine definitions)"
echo ""
