#!/usr/bin/env bash
#
# Builds build/pnow.app (universal) and signs it.
#
#   scripts/build-app.sh                  # local build, ad-hoc signed, no updates
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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN_DIR/pnow" "$APP/Contents/MacOS/pnow"
cp packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed "s/__VERSION__/$VERSION/g" packaging/Info.plist > "$APP/Contents/Info.plist"
if [ "$SIGN_IDENTITY" = "-" ]; then
  # A local build shows as "dev", and Sparkle stays off so it never replaces itself.
  plutil -replace PnowDevBuild -bool true "$APP/Contents/Info.plist"
  plutil -remove SUFeedURL "$APP/Contents/Info.plist"
fi

# Sparkle's XPC services are only for sandboxed apps, and pnow is not sandboxed.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
ditto "$BIN_DIR/Sparkle.framework" "$SPARKLE"
rm -rf "$SPARKLE/Versions/B/XPCServices" "$SPARKLE/XPCServices"

# Sign from the inside out, without --deep. Notarization needs the hardened runtime and a
# secure timestamp.
if [ "$SIGN_IDENTITY" = "-" ]; then
  SIGN=(codesign --force --sign -)
else
  SIGN=(codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY")
fi
"${SIGN[@]}" "$SPARKLE/Versions/B/Autoupdate"
"${SIGN[@]}" "$SPARKLE/Versions/B/Updater.app"
"${SIGN[@]}" "$SPARKLE"
"${SIGN[@]}" "$APP"
codesign --verify --strict --deep "$APP"

echo "Built $APP ($VERSION)"
