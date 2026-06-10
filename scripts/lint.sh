#!/usr/bin/env bash
set -euo pipefail
echo "🔍 Running lint checks..."

# swift-format check (if installed)
if command -v swift-format &>/dev/null; then
    echo "  swift-format check..."
    swift-format lint --recursive --configuration .swift-format Sources/ Tests/ 2>&1 || true
else
    echo "  ⚠️  swift-format not installed. Install: brew install swift-format"
fi

# SwiftLint (if installed)
if command -v swiftlint &>/dev/null; then
    echo "  SwiftLint check..."
    swiftlint lint --config .swiftlint.yml 2>&1 || true
else
    echo "  ⚠️  SwiftLint not installed. Install: brew install swiftlint"
fi

echo "✅ Lint complete"
