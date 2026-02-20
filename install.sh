#!/usr/bin/env bash
# install.sh - Bootstrap for UMH factory demo
# This script is version-independent. It resolves the correct version
# and downloads the version-specific quick-start.sh from that release.
set -euo pipefail

REPO="${REPO:-united-manufacturing-hub/umh-factory-demo}"
USE_DEV=false
TARGET_VERSION=""
LOCAL_PATH=""

# Parse only version-related args (everything else passes through)
for arg in "$@"; do
    case "$arg" in
        --dev) USE_DEV=true ;;
        --version=*) TARGET_VERSION="${arg#--version=}" ;;
        --repo=*) REPO="${arg#--repo=}" ;;
        --local=*) LOCAL_PATH="${arg#--local=}" ;;
        --local) echo "Error: --local requires a path (e.g. --local=/path/to/repo)" >&2; exit 1 ;;
    esac
done

# If --local, skip download and run local quick-start.sh directly
if [ -n "$LOCAL_PATH" ]; then
    if [ ! -f "$LOCAL_PATH/quick-start.sh" ]; then
        echo "Error: $LOCAL_PATH/quick-start.sh not found" >&2; exit 1
    fi
    echo "Using local source: $LOCAL_PATH"
    exec bash "$LOCAL_PATH/quick-start.sh" "$@"
fi

# Resolve release tag
if [ -n "$TARGET_VERSION" ]; then
    TAG="v${TARGET_VERSION#v}"
elif [ "$USE_DEV" = true ]; then
    # Find latest dev prerelease
    TAG=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases" \
        | grep -o '"tag_name": *"[^"]*-dev\.[^"]*"' | head -1 | cut -d'"' -f4)
    if [ -z "$TAG" ]; then
        echo "Error: No dev release found" >&2; exit 1
    fi
else
    # Latest stable
    TAG=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
        | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4)
fi

echo "Using release: ${TAG}"

# Build passthrough args, replacing --dev/--version with the resolved version
PASSTHROUGH_ARGS=("--version=${TAG#v}")
for arg in "$@"; do
    case "$arg" in
        --dev|--version=*) ;; # already resolved
        *) PASSTHROUGH_ARGS+=("$arg") ;;
    esac
done

# Download and run the version-specific quick-start.sh
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/quick-start.sh"
curl -fsSL "$DOWNLOAD_URL" -o quick-start.sh
chmod +x quick-start.sh
exec bash quick-start.sh "${PASSTHROUGH_ARGS[@]}"
