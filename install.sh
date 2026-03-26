#!/usr/bin/env bash
# install.sh - Bootstrap for UMH factory demo
# This script is version-independent. It resolves the correct version
# and downloads the version-specific quick-start.sh from that release.
set -euo pipefail

REPO="${REPO:-united-manufacturing-hub/umh-factory-demo}"
TARGET_VERSION=""
LOCAL_PATH=""
BRANCH=""

# Parse only version-related args (everything else passes through)
for arg in "$@"; do
    case "$arg" in
        --version=*) TARGET_VERSION="${arg#--version=}" ;;
        --repo=*) REPO="${arg#--repo=}" ;;
        --local=*) LOCAL_PATH="${arg#--local=}" ;;
        --local) echo "Error: --local requires a path (e.g. --local=/path/to/repo)" >&2; exit 1 ;;
        --branch=*) BRANCH="${arg#--branch=}" ;;
        --branch) echo "Error: --branch requires a name (e.g. --branch=feat/my-feature)" >&2; exit 1 ;;
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

# If --branch, download branch tarball and run as local
if [ -n "$BRANCH" ]; then
    TMPDIR=$(mktemp -d)
    trap 'rm -rf "$TMPDIR"' EXIT

    TARBALL_URL="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"
    echo "Downloading branch '${BRANCH}' from ${REPO}..."

    if ! curl -fsSL "$TARBALL_URL" -o "$TMPDIR/branch.tar.gz"; then
        echo "Error: Failed to download branch '${BRANCH}'. Does it exist?" >&2
        echo "URL: $TARBALL_URL" >&2
        exit 1
    fi

    tar xzf "$TMPDIR/branch.tar.gz" -C "$TMPDIR"
    rm "$TMPDIR/branch.tar.gz"

    # GitHub tarballs extract to a single subdirectory
    EXTRACTED=$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -type d | head -1)
    if [ -z "$EXTRACTED" ] || [ ! -f "$EXTRACTED/quick-start.sh" ]; then
        echo "Error: quick-start.sh not found in downloaded branch" >&2; exit 1
    fi

    echo "Using branch: $BRANCH"

    # Build passthrough args, replacing --branch with --local
    PASSTHROUGH_ARGS=("--local=$EXTRACTED")
    for arg in "$@"; do
        case "$arg" in
            --branch=*|--branch) ;; # replaced with --local
            *) PASSTHROUGH_ARGS+=("$arg") ;;
        esac
    done

    # Run quick-start.sh (not exec, so trap cleanup fires after)
    bash "$EXTRACTED/quick-start.sh" "${PASSTHROUGH_ARGS[@]}"
    exit $?
fi

# Resolve release tag
if [ -n "$TARGET_VERSION" ]; then
    TAG="v${TARGET_VERSION#v}"
else
    # Latest stable
    TAG=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
        | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4)
fi

echo "Using release: ${TAG}"

# Build passthrough args, replacing --version with the resolved version
PASSTHROUGH_ARGS=("--version=${TAG#v}")
for arg in "$@"; do
    case "$arg" in
        --version=*) ;; # already resolved
        *) PASSTHROUGH_ARGS+=("$arg") ;;
    esac
done

# Download and run the version-specific quick-start.sh
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/quick-start.sh"
curl -fsSL "$DOWNLOAD_URL" -o quick-start.sh
chmod +x quick-start.sh
exec bash quick-start.sh "${PASSTHROUGH_ARGS[@]}"
