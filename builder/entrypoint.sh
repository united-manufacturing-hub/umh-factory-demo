#!/bin/bash
set -euo pipefail

VERSION="${VERSION:-main}"
REPO="${REPO:-united-manufacturing-hub/umh-simulator}"
TMP="/tmp/templates-src"

echo "Downloading templates (v${VERSION})..."
mkdir -p "$TMP"
curl -fsSL "https://github.com/${REPO}/archive/refs/tags/v${VERSION}.tar.gz" \
  | tar -xz --strip-components=1 -C "$TMP" 2>/dev/null \
  || curl -fsSL "https://github.com/${REPO}/archive/refs/heads/${VERSION}.tar.gz" \
     | tar -xz --strip-components=1 -C "$TMP"

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
