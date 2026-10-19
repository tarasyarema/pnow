#!/usr/bin/env bash
#
# Builds build/pnow.app (universal) and signs it.
#
#   scripts/build-app.sh                  # dev build, ad-hoc signed
#   VERSION=0.1.0 SIGN_IDENTITY="Developer ID Application: ..." scripts/build-app.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.0.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP=build/pnow.app

swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/pnow" "$APP/Contents/MacOS/pnow"
sed "s/__VERSION__/$VERSION/g" packaging/Info.plist > "$APP/Contents/Info.plist"

if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP"
else
  # Notarization needs the hardened runtime and a secure timestamp.
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"

echo "Built $APP ($VERSION)"
