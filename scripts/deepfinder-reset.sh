#!/bin/bash
# deepfinder-reset — clean all caches and reinstall
# Usage: ./scripts/deepfinder-reset.sh [--keep-config]

set -euo pipefail

KEEP_CONFIG=false
if [[ "${1:-}" == "--keep-config" ]]; then
    KEEP_CONFIG=true
fi

DF_DIR="$HOME/.deep-finder"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/cn.com.nadav.deepfinder.daemon.plist"

echo "=== DeepFinder Reset ==="
echo

# ── 1. Stop daemon ──────────────────────────────────────────
echo "[1/5] Stopping daemon..."
if command -v deepfinder &>/dev/null; then
    deepfinder daemon stop 2>/dev/null || true
    sleep 2
fi
# Force-kill any remaining daemon processes
pkill -f deepfinder-daemon 2>/dev/null || true
sleep 1
echo "  Done."

# ── 2. Uninstall LaunchAgent ────────────────────────────────
echo "[2/5] Removing LaunchAgent..."
if [[ -f "$LAUNCH_AGENT" ]]; then
    launchctl unload "$LAUNCH_AGENT" 2>/dev/null || true
    rm -f "$LAUNCH_AGENT"
    echo "  Removed."
else
    echo "  Not installed."
fi

# ── 3. Clean caches ─────────────────────────────────────────
echo "[3/5] Cleaning caches..."
if $KEEP_CONFIG; then
    # Keep settings.json, bookmarks.json, filters.json
    rm -rf "$DF_DIR/cache" "$DF_DIR/session" "$DF_DIR/history" 2>/dev/null || true
    echo "  Caches cleared (config kept)."
else
    rm -rf "$DF_DIR/cache" "$DF_DIR/session" "$DF_DIR/history" \
           "$DF_DIR/settings.json" "$DF_DIR/bookmarks.json" \
           "$DF_DIR/filters.json" 2>/dev/null || true
    echo "  All data cleared."
fi

# ── 4. Reinstall LaunchAgent ────────────────────────────────
echo "[4/5] Installing LaunchAgent..."
if command -v deepfinder &>/dev/null; then
    deepfinder install 2>/dev/null || echo "  (install skipped — run 'deepfinder install' manually)"
else
    echo "  deepfinder not in PATH — skipping LaunchAgent install"
fi

# ── 5. Start daemon ─────────────────────────────────────────
echo "[5/5] Starting daemon..."
if command -v deepfinder &>/dev/null; then
    deepfinder daemon start 2>/dev/null || true
    sleep 4
    echo
    deepfinder daemon status 2>/dev/null || echo "  (daemon starting — check back in a few seconds)"
else
    echo "  deepfinder not in PATH — start daemon manually"
fi

echo
echo "=== Reset complete ==="
echo "Verify: deepfinder daemon status"
