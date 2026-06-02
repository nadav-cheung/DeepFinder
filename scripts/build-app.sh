#!/bin/bash
set -euo pipefail

# Build and assemble DeepFinder.app bundle for distribution.
#
# Usage: scripts/build-app.sh
# Output: build/DeepFinder.app

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION="$(cat "$ROOT_DIR/VERSION" | tr -d '[:space:]')"
APP_NAME="DeepFinder"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_BUNDLE="$ROOT_DIR/build/$APP_NAME.app"

echo "==> Building $APP_NAME v$VERSION..."

# Build both the app and daemon executables.
swift build -c release --product deepfinder-app
swift build -c release --product deepfinder-daemon

# Remove stale bundle.
rm -rf "$APP_BUNDLE"

# Create bundle directory structure.
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy executables.
# SwiftPM product names are lowercase-hyphen; binaries match those names.
cp "$BUILD_DIR/deepfinder-app" "$APP_BUNDLE/Contents/MacOS/DeepFinderApp"
cp "$BUILD_DIR/deepfinder-daemon" "$APP_BUNDLE/Contents/MacOS/deepfinder-daemon"

# Generate Info.plist with version substituted.
sed "s/{{VERSION}}/$VERSION/g" "$ROOT_DIR/App/Info.plist" \
    > "$APP_BUNDLE/Contents/Info.plist"

# Code sign the bundle (ad-hoc signing for local use;
# replace `-` with a Developer ID for distribution/notarization).
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> $APP_BUNDLE ready ($APP_NAME v$VERSION)"
