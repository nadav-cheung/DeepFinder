#!/usr/bin/env bash
set -euo pipefail
echo "🧪 Running tests..."
swift test 2>&1 | tee /tmp/deepfinder-test-output.txt
echo "✅ Tests complete"
