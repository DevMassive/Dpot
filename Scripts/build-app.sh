#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build"
PRODUCT_NAME="Dpot"
APP_BUNDLE="$BUILD_DIR/${PRODUCT_NAME}.app"
APP_BINARY="$BUILD_DIR/release/$PRODUCT_NAME"

echo "Building release binary..."
swift build -c release

if [ ! -x "$APP_BINARY" ]; then
  echo "Failed to find built binary at $APP_BINARY" >&2
  exit 1
fi

echo "Packaging $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$ROOT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$APP_BINARY" "$APP_BUNDLE/Contents/MacOS/$PRODUCT_NAME"

echo "Done."
echo "App bundle created at:"
echo "  $APP_BUNDLE"
echo "Copy it to /Applications and add to Login Items to keep it resident."
