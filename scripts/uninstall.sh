#!/bin/bash
#
# DeepFinder — Complete Uninstall Script
#
# Removes all DeepFinder components from this Mac:
#   - Running daemon (stopped)
#   - LaunchAgent plist (auto-start on login)
#   - Data directory (~/.deep-finder) — index, config, logs, history, secrets
#   - Installed binaries (/usr/local/bin/deepfinder, deepfinder-daemon)
#   - App bundle (/Applications/DeepFinder.app)
#   - UserDefaults entries
#
# Usage:
#   bash scripts/uninstall.sh          # interactive (prompts before each step)
#   bash scripts/uninstall.sh --yes    # non-interactive (removes everything)
#   bash uninstall.sh --keep-data      # remove app but keep ~/.deep-finder
#
set -euo pipefail

# --- Constants (keep in sync with Sources/Index/ProductConfig.swift) ---

BUNDLE_ID="cn.com.nadav.deepfinder"
DAEMON_LABEL="${BUNDLE_ID}.daemon"
DATA_DIR="${HOME}/.deep-finder"
LAUNCHAGENT_PLIST="${HOME}/Library/LaunchAgents/${DAEMON_LABEL}.plist"
CLI_BIN="/usr/local/bin/deepfinder"
DAEMON_BIN="/usr/local/bin/deepfinder-daemon"
APP_BUNDLE="/Applications/DeepFinder.app"

# --- Helpers ---

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'

step()    { printf "\n${BOLD}==>${RESET} $1\n"; }
ok()      { printf "  ${GREEN}✓${RESET} $1\n"; }
skip()    { printf "  ${YELLOW}⊘${RESET} $1\n"; }
warn()    { printf "  ${YELLOW}⚠${RESET} $1\n" >&2; }
err()     { printf "  ${RED}✗${RESET} $1\n" >&2; }

confirm() {
    local desc="$1"
    if [[ "${YES:-}" == "1" ]]; then
        return 0
    fi
    printf "  Remove ${BOLD}${desc}${RESET}? [y/N] "
    read -r answer
    [[ "${answer}" =~ ^[Yy]$ ]]
}

# --- Parse arguments ---

YES=0
KEEP_DATA=0

for arg in "$@"; do
    case "${arg}" in
        -y|--yes)   YES=1 ;;
        --keep-data) KEEP_DATA=1 ;;
        -h|--help)
            echo "Usage: $(basename "$0") [--yes] [--keep-data]"
            echo ""
            echo "  --yes        Remove everything without prompting"
            echo "  --keep-data  Keep ~/.deep-finder data directory"
            exit 0
            ;;
        *)
            err "Unknown option: ${arg}"
            exit 1
            ;;
    esac
done

printf "${BOLD}DeepFinder Uninstaller${RESET}\n"
printf "This will remove all DeepFinder components from this Mac.\n"

# --- Step 1: Stop daemon ---

step "Stopping daemon"

PID_FILE="${DATA_DIR}/session/daemon.pid"
if [[ -f "${PID_FILE}" ]]; then
    DAEMON_PID=$(cat "${PID_FILE}" 2>/dev/null || true)
    if [[ -n "${DAEMON_PID}" ]] && kill -0 "${DAEMON_PID}" 2>/dev/null; then
        kill "${DAEMON_PID}" 2>/dev/null || true
        # Give it a moment to shut down gracefully
        sleep 1
        if kill -0 "${DAEMON_PID}" 2>/dev/null; then
            kill -9 "${DAEMON_PID}" 2>/dev/null || true
            warn "Force-killed daemon (PID ${DAEMON_PID})"
        else
            ok "Daemon stopped (PID ${DAEMON_PID})"
        fi
    else
        skip "Daemon not running (stale PID file)"
    fi
else
    # Try finding the daemon process by name
    DAEMON_PID=$(pgrep -f "deepfinder-daemon" 2>/dev/null || true)
    if [[ -n "${DAEMON_PID}" ]]; then
        kill "${DAEMON_PID}" 2>/dev/null || true
        sleep 1
        ok "Daemon stopped (PID ${DAEMON_PID})"
    else
        skip "Daemon not running"
    fi
fi

# --- Step 2: Unload LaunchAgent ---

step "Unloading LaunchAgent"

if [[ -f "${LAUNCHAGENT_PLIST}" ]]; then
    launchctl bootout "gui/$(id -u)/${DAEMON_LABEL}" 2>/dev/null || true
    if confirm "LaunchAgent plist (${LAUNCHAGENT_PLIST})"; then
        rm -f "${LAUNCHAGENT_PLIST}"
        ok "LaunchAgent plist removed"
    else
        skip "LaunchAgent plist kept"
    fi
else
    skip "LaunchAgent plist not found"
fi

# Also unload in case plist was already removed but service is still loaded
launchctl bootout "gui/$(id -u)/${DAEMON_LABEL}" 2>/dev/null || true

# --- Step 3: Remove data directory ---

step "Removing data directory"

if [[ "${KEEP_DATA}" == "1" ]]; then
    skip "Data directory kept (--keep-data)"
else
    if [[ -d "${DATA_DIR}" ]]; then
        # Show what we're about to remove
        SIZE=$(du -sh "${DATA_DIR}" 2>/dev/null | cut -f1 || echo "?")
        if confirm "${DATA_DIR} (${SIZE})"; then
            rm -rf "${DATA_DIR}"
            ok "Data directory removed (${SIZE} freed)"
        else
            skip "Data directory kept"
        fi
    else
        skip "Data directory not found"
    fi
fi

# --- Step 4: Remove installed binaries ---

step "Removing CLI binaries"

for bin in "${CLI_BIN}" "${DAEMON_BIN}"; do
    if [[ -f "${bin}" ]]; then
        if confirm "${bin}"; then
            rm -f "${bin}"
            ok "Removed ${bin}"
        else
            skip "Kept ${bin}"
        fi
    else
        skip "${bin} not found"
    fi
done

# --- Step 5: Remove app bundle ---

step "Removing app bundle"

if [[ -d "${APP_BUNDLE}" ]]; then
    SIZE=$(du -sh "${APP_BUNDLE}" 2>/dev/null | cut -f1 || echo "?")
    if confirm "${APP_BUNDLE} (${SIZE})"; then
        rm -rf "${APP_BUNDLE}"
        ok "App bundle removed"
    else
        skip "App bundle kept"
    fi
else
    skip "App bundle not found in /Applications"
fi

# --- Step 6: Remove UserDefaults ---

step "Clearing UserDefaults"

if defaults read "${BUNDLE_ID}" &>/dev/null; then
    if confirm "UserDefaults domain ${BUNDLE_ID}"; then
        defaults delete "${BUNDLE_ID}" 2>/dev/null || true
        ok "UserDefaults cleared"
    else
        skip "UserDefaults kept"
    fi
else
    skip "No UserDefaults found for ${BUNDLE_ID}"
fi

# --- Step 7: Remind about system permissions ---

step "System permissions (manual)"

printf "  The following require manual removal in ${BOLD}System Settings${RESET}:\n"
printf "    1. ${BOLD}Privacy & Security → Full Disk Access${RESET} — remove DeepFinder\n"
printf "    2. ${BOLD}Privacy & Security → Accessibility${RESET} — remove DeepFinder (if granted)\n"
printf "\n  System permissions cannot be revoked from the command line.\n"

# --- Done ---

printf "\n${GREEN}${BOLD}Done.${RESET} "
if [[ "${YES}" == "1" ]]; then
    printf "DeepFinder has been fully removed.\n"
else
    printf "Review the output above for any items you chose to keep.\n"
fi
printf "\n"
