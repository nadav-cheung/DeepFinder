#!/usr/bin/env bash
# run-tests.sh — Run all DeepFinder test suites in batches.
#
# Workaround for Swift Testing SIGSEGV when running many concurrent @MainActor
# test suites. Each suite passes individually; the crash only occurs when too
# many suites run in a single process.
#
# Usage:
#   ./scripts/run-tests.sh          # Run all suites
#   ./scripts/run-tests.sh --quick  # Skip slow suites (DaemonTests, CLITests)
#
# Exit code: 0 if all pass, 1 if any fail.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RESET='\033[0m'

quick=false
if [[ "${1:-}" == "--quick" ]]; then
    quick=true
fi

# Test suites ordered by dependency layer.
# Run each as a separate swift test invocation to avoid Swift Testing SIGSEGV
# from too many concurrent @MainActor suites in a single process.
suites=(
    IndexTests
    SearchTests
    FSTests
    PersistTests
    AITests
    MediaTests
    ServicesTests
    "GUITests:AccessHistory"
    "GUITests:AppDelegate"
    "GUITests:GlobalHotkey"
    "GUITests:IntelligenceGlow"
    "GUITests:QuickLook"
    "GUITests:Result"
    "GUITests:Search"
    "GUITests:Settings"
    "GUITests:SpeechOverlay"
    "GUITests:StatusBar"
)

if [[ "$quick" == false ]]; then
    suites+=(DaemonTests CLITests)
fi

failed=()
passed=0
total_tests=0

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " DeepFinder Test Suite — $(date)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

for entry in "${suites[@]}"; do
    # Split on colon — "GUITests:AccessHistory" → filter "AccessHistory"
    if [[ "$entry" == *":"* ]]; then
        label="${entry#*:}"
        filter="$label"
    else
        label="$entry"
        filter="$entry"
    fi

    printf "Running %-30s ... " "$label"
    if output=$(swift test --filter "$filter" 2>&1); then
        # Extract test count: "Test run with 107 tests in 8 suites passed"
        line=$(echo "$output" | grep "Test run with" | head -1)
        num=$(echo "$line" | sed -n 's/.*with \([0-9]*\) tests.*/\1/p')
        num=${num:-0}
        printf "${GREEN}✔${RESET} %s tests\n" "$num"
        total_tests=$((total_tests + num))
        passed=$((passed + 1))
    else
        printf "${RED}✘${RESET} FAILED\n"
        failed+=("$label")
        # Show the failure details
        echo "$output" | grep -E "✘|failed|error:" | head -5 | sed 's/^/  /'
    fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ ${#failed[@]} -eq 0 ]]; then
    echo -e " ${GREEN}All $passed batches passed${RESET} ($total_tests tests)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 0
else
    echo -e " ${RED}${#failed[@]} batch(es) failed:${RESET} ${failed[*]}"
    echo -e " ${GREEN}$passed batch(es) passed${RESET} ($total_tests tests)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 1
fi
