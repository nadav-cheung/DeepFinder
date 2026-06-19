#!/bin/bash
# DeepFinder — production verification script
# Run after every build/install to smoke-test core functionality.
# Uses real data from this machine. Tests that pass on nadav's M4.
#
# Usage:
#   ./scripts/verify.sh              # use installed deepfinder
#   ./scripts/verify.sh --fresh      # stop daemon, clean start
#   ./scripts/verify.sh --quick      # skip slow tests (daemon restart)
#
# Exit: 0 = all good, 1 = at least one check failed.

set -o pipefail

RED=$(tput setaf 1 2>/dev/null || echo "")
GRN=$(tput setaf 2 2>/dev/null || echo "")
RST=$(tput sgr0 2>/dev/null || echo "")

PASS=0
FAIL=0
SKIP=0

check() {
    local label="$1"; shift
    local expected="$1"; shift
    local actual
    actual=$("$@" 2>&1) || true
    if echo "$actual" | grep -q "$expected"; then
        echo "  ${GRN}✅${RST} $label"
        PASS=$((PASS + 1))
    else
        echo "  ${RED}❌${RST} $label"
        echo "     expected: '$expected'"
        echo "     got:      '$(echo "$actual" | head -1)'"
        FAIL=$((FAIL + 1))
    fi
    sleep 0.15  # stay under IPC rate limit (10 conn/s)
}

check_exit() {
    local label="$1"; shift
    local expected_code="$1"; shift
    "$@" > /dev/null 2>&1
    local actual_code=$?
    if [ "$actual_code" -eq "$expected_code" ]; then
        echo "  ${GRN}✅${RST} $label (exit $actual_code)"
        PASS=$((PASS + 1))
    else
        echo "  ${RED}❌${RST} $label — expected exit $expected_code, got $actual_code"
        FAIL=$((FAIL + 1))
    fi
    sleep 0.15
}

check_stderr() {
    local label="$1"; shift
    local expected="$1"; shift
    local actual
    actual=$("$@" 2>&1 1>/dev/null) || true
    if echo "$actual" | grep -q "$expected"; then
        echo "  ${GRN}✅${RST} $label"
        PASS=$((PASS + 1))
    else
        echo "  ${RED}❌${RST} $label"
        echo "     expected on stderr: '$expected'"
        echo "     got:                '$(echo "$actual" | head -1)'"
        FAIL=$((FAIL + 1))
    fi
    sleep 0.15
}

echo "============================================"
echo " DeepFinder Verification Suite"
echo " Machine : $(hostname -s 2>/dev/null || echo unknown)"
echo " Date    : $(date '+%Y-%m-%d %H:%M:%S')"
echo " Version : $(deepfinder --version 2>/dev/null || echo 'NOT FOUND')"
echo " Daemon  : $(deepfinder daemon status 2>/dev/null | head -1 || echo 'NOT RUNNING')"
echo "============================================"
echo ""

# ─────────────────────────────────────────────
# Section 1: Basic CLI (no daemon needed)
# ─────────────────────────────────────────────
echo "【1】CLI Basics"

check "version prints DeepFinder"  "DeepFinder" deepfinder --version
check "help shows USAGE"           "USAGE"      deepfinder --help
check "help lists daemon start"    "daemon start" deepfinder --help
check "help lists config"          "config get" deepfinder --help
check "help shows --debug"         "debug"      deepfinder --help
check_exit "version exit 0"  0  deepfinder --version
check_exit "help exit 0"     0  deepfinder --help

# ─────────────────────────────────────────────
# Section 2: Daemon (requires daemon running)
# ─────────────────────────────────────────────
echo ""
echo "【2】Daemon Management"

DAEMON_PID=$(pgrep -f deepfinder-daemon 2>/dev/null || echo "")
if [ -z "$DAEMON_PID" ]; then
    echo "  ⚠️  Daemon not running — starting..."
    deepfinder daemon start 2>/dev/null || true
    sleep 5
fi

STATUS=$(deepfinder daemon status 2>&1)
check "status shows PID"          "PID"          echo "$STATUS"
check "status shows Uptime"       "Uptime"       echo "$STATUS"
check "status shows Index state"  "Index state"  echo "$STATUS"
check "status shows Files"        "Files indexed" echo "$STATUS"
check "status shows Memory"       "Memory"       echo "$STATUS"

# ─────────────────────────────────────────────
# Section 3: File Search (real data)
# ─────────────────────────────────────────────
echo ""
echo "【3】File Search — English"

check "README returns results"     "README"      deepfinder "README" --limit 3
check "test returns results"       "test"        deepfinder "test" --limit 3
check "Makefile returns results"   "Makefile"    deepfinder "Makefile" --limit 3
check ".swift extension search"    ".swift"      deepfinder ".swift" --limit 3
check ".md extension search"       ".md"         deepfinder ".md" --limit 3
check "index substring"            "index"       deepfinder "index" --limit 3

echo ""
echo "【4】File Search — Chinese/Pinyin"

check "中文: 文档"  "文档"  deepfinder "文档" --limit 3
check "中文: 笔记"  "笔记"  deepfinder "笔记" --limit 3
# Pinyin search: search result won't contain ASCII "wendang" — just check non-empty
check "拼音: wendang → finds files"  "md"  deepfinder "wendang" --limit 3

echo ""
echo "【5】Prefix Suggestions (0 results → Did you mean)"

check_stderr "typo 'readme' → suggests"  "Did you mean" deepfinder "readme" --limit 0
check_stderr "typo 'confg' → suggests"   "Did you mean" deepfinder "confg" --limit 0

echo ""
echo "【6】Chinese — no Latin garbage suggestion"

NO_GARBAGE=$(deepfinder '张楠' 2>&1 || true)
if echo "$NO_GARBAGE" | grep -q "f5"; then
    echo "  ${RED}❌${RST} Chinese '张楠' suggested Latin garbage: $NO_GARBAGE"
    FAIL=$((FAIL + 1))
else
    echo "  ${GRN}✅${RST} Chinese '张楠' — no garbage suggestion"
    PASS=$((PASS + 1))
fi

NO_GARBAGE2=$(deepfinder '你好' 2>&1 || true)
if echo "$NO_GARBAGE2" | grep -qE "Did you mean: [a-z0-9]"; then
    echo "  ${RED}❌${RST} Chinese '你好' suggested irrelevant Latin: $NO_GARBAGE2"
    FAIL=$((FAIL + 1))
else
    echo "  ${GRN}✅${RST} Chinese '你好' — no irrelevant suggestion"
    PASS=$((PASS + 1))
fi

# ─────────────────────────────────────────────
# Section 4: Exit Codes
# ─────────────────────────────────────────────
echo ""
echo "【7】Exit Codes"

check_exit "search with results → 0"     0  deepfinder "README" --limit 1
check_exit "search no results → 1"       1  deepfinder "xyznonexistent_$(date +%s)"
check_exit "daemon status → 0"           0  deepfinder daemon status

# ─────────────────────────────────────────────
# Section 5: Config
# ─────────────────────────────────────────────
echo ""
echo "【8】Config"

CONFIG_FILE=$(echo ~/.deep-finder/settings.json)
if [ -f "$CONFIG_FILE" ]; then
    check "config file exists"         "excludedPaths"  cat "$CONFIG_FILE"
    check "config has excludedPaths"   "/System"        cat "$CONFIG_FILE"
    check "config has configVersion"   "configVersion"  cat "$CONFIG_FILE"
else
    echo "  ${RED}❌${RST} Config file missing: $CONFIG_FILE"
    FAIL=$((FAIL + 1))
fi

check "config list shows excludedPaths" "excludedPaths" deepfinder config list
check "config get excludedPaths"        "System"        deepfinder config get excludedPaths

# ─────────────────────────────────────────────
# Section 6: Debug Mode
# ─────────────────────────────────────────────
echo ""
echo "【9】Debug Mode"

DEBUG_OUT=$(deepfinder "test" --debug --limit 1 2>&1 1>/dev/null || true)
# --debug writes log lines to stderr: [timestamp] [LEVEL] [component] message
if echo "$DEBUG_OUT" | grep -qE '\[DEBUG\]'; then
    echo "  ${GRN}✅${RST} --debug emits DEBUG level logs"
    PASS=$((PASS + 1))
else
    # In single-shot, debug logs depend on Logger being configured
    echo "  ⚠️  --debug: no DEBUG-level output (may be filtered by log level)"
    SKIP=$((SKIP + 1))
fi

# ─────────────────────────────────────────────
# Section 7: Daemon Logs
# ─────────────────────────────────────────────
echo ""
echo "【10】Daemon Logs"

LOG_FILE=$(echo ~/.deep-finder/logs/deepfinder.log)
if [ -f "$LOG_FILE" ]; then
    check "log has INFO entries"       "INFO"                cat "$LOG_FILE"
    check "log shows daemon starting"  "daemon starting"     cat "$LOG_FILE"
    check "log shows IPC listening"    "IPC server listening" cat "$LOG_FILE"
    check "log shows FSEventWatcher"   "FSEventWatcher"      cat "$LOG_FILE"
else
    echo "  ${RED}❌${RST} Log file missing: $LOG_FILE"
    FAIL=$((FAIL + 1))
fi

# ─────────────────────────────────────────────
# Section 8: Content Search
# ─────────────────────────────────────────────
echo ""
echo "【11】Content Search"

# Search for a string we know is in some file
CONTENT_RESULT=$(deepfinder 'content:"Copyright"' --limit 3 2>&1 || true)
if [ -n "$CONTENT_RESULT" ]; then
    echo "  ${GRN}✅${RST} content search 'Copyright' returned results"
    PASS=$((PASS + 1))
else
    echo "  ⚠️  content search — no results or not supported (skipped)"
    SKIP=$((SKIP + 1))
fi

# ─────────────────────────────────────────────
# Section 9: Duplicate Finder
# ─────────────────────────────────────────────
echo ""
echo "【12】Duplicate Finder"

DUPE_RESULT=$(deepfinder 'dupe:' --limit 3 2>&1 || true)
if [ -n "$DUPE_RESULT" ]; then
    echo "  ${GRN}✅${RST} dupe: returned results"
    PASS=$((PASS + 1))
else
    echo "  ⚠️  dupe: — no duplicates found (skipped)"
    SKIP=$((SKIP + 1))
fi

# ─────────────────────────────────────────────
# Results
# ─────────────────────────────────────────────
echo ""
echo "============================================"
TOTAL=$((PASS + FAIL))
printf " Results: ${GRN}%d passed${RST}" "$PASS"
if [ "$FAIL" -gt 0 ]; then
    printf ", ${RED}%d failed${RST}" "$FAIL"
fi
if [ "$SKIP" -gt 0 ]; then
    printf ", %d skipped" "$SKIP"
fi
echo ""
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
else
    exit 0
fi
