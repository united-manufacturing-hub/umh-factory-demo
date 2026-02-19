#!/bin/bash
set -euo pipefail

VERSION="${VERSION:-}"
BRANCH="${BRANCH:-}"
REPO="${REPO:-united-manufacturing-hub/umh-factory-demo}"
LOCAL_TEMPLATES="${LOCAL_TEMPLATES:-}"
TMP="/tmp/templates-src"

mkdir -p "$TMP"

if [ -n "$LOCAL_TEMPLATES" ]; then
    echo "Using local templates from $LOCAL_TEMPLATES..."
    cp -r "$LOCAL_TEMPLATES/." "$TMP"
else
    # Auto-resolve latest release if no version specified and no branch override
    if [ -z "$VERSION" ] && [ -z "$BRANCH" ]; then
        echo "No version specified, fetching latest release..."
        VERSION=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
            | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4)
        VERSION="${VERSION#v}"
        echo "Resolved latest version: v${VERSION}"
    fi

    if [ -n "$BRANCH" ]; then
        echo "Downloading templates (branch: ${BRANCH})..."
        curl -fsSL "https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz" \
          | tar -xz --strip-components=1 -C "$TMP"
    else
        echo "Downloading templates (v${VERSION})..."
        curl -fsSL "https://github.com/${REPO}/archive/refs/tags/v${VERSION}.tar.gz" \
          | tar -xz --strip-components=1 -C "$TMP"
    fi
fi

# New structure: repo root is the templates dir
export TEMPLATES_DIR="$TMP"
export SCRIPTS_DIR="$TMP/scripts"

# Signal helpers
SIGNAL_DIR="/workspace/.builder"
mkdir -p "$SIGNAL_DIR"
signal() { echo "$(date -Iseconds)" > "$SIGNAL_DIR/$1"; }
wait_for() {
    echo "Waiting for: $1..."
    while [ ! -f "$SIGNAL_DIR/$1" ]; do sleep 1; done
    echo "Received: $1"
}

# Phase dispatch
PHASE="${PHASE:-all}"
case "$PHASE" in
    generate)
        source "$SCRIPTS_DIR/builder-generate.sh"
        signal "generate-done"
        ;;
    post-init)
        source "$SCRIPTS_DIR/builder-post-init.sh"
        signal "post-init-done"
        ;;
    all)
        source "$SCRIPTS_DIR/builder-generate.sh"
        signal "generate-done"
        wait_for "compose-started"
        source "$SCRIPTS_DIR/builder-post-init.sh"
        signal "post-init-done"
        sleep 5  # keep alive briefly so init script reads the signal
        ;;
esac
