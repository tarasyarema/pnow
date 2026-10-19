#!/usr/bin/env bash
#
# Releases pnow: a signed, notarized build on GitHub Releases, then the cask bump in the tap.
#
#   scripts/release.sh patch              # or minor, major, or an exact version like 1.2.3
#   scripts/release.sh patch --dry-run    # build, sign, notarize, staple: publish nothing
#
# Needs the "Developer ID Application" cert in your keychain and the notary profile from
#   xcrun notarytool store-credentials pnow-notary --apple-id <apple-id> --team-id 2HUBD5T348
#
# Each release also uploads appcast.xml, the feed Sparkle reads through
# https://github.com/tarasyarema/pnow/releases/latest/download/appcast.xml. Its EdDSA signing key
# is in your login keychain (from Sparkle's generate_keys).
#
set -euo pipefail
cd "$(dirname "$0")/.."

BUMP="${1:?Usage: scripts/release.sh patch|minor|major|<version> [--dry-run]}"
DRY_RUN="${2:-}"
SIGN_IDENTITY="Developer ID Application: Taras Yarema (2HUBD5T348)"
NOTARY_PROFILE=pnow-notary
REPO=tarasyarema/pnow
TAP_DIR="${TAP_DIR:-../taras-homebrew-tap}"
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin

fail() {
  echo "release: $*" >&2
  exit 1
}

LAST="$(git tag --list 'v*' --sort=-v:refname | head -n 1)"
LAST="${LAST#v}"
IFS=. read -r MAJOR MINOR PATCH <<< "${LAST:-0.0.0}"
case "$BUMP" in
  patch) VERSION="$MAJOR.$MINOR.$((PATCH + 1))" ;;
  minor) VERSION="$MAJOR.$((MINOR + 1)).0" ;;
  major) VERSION="$((MAJOR + 1)).0.0" ;;
  *) VERSION="$BUMP" ;;
esac
ZIP="build/pnow-$VERSION.zip"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "the version must look like 1.2.3."
echo "Releasing pnow $VERSION (last release: ${LAST:-none})"

if [ "$DRY_RUN" != "--dry-run" ]; then
  [ -z "$(git status --porcelain)" ] || fail "commit your changes first."
  [ "$(git branch --show-current)" = main ] || fail "release from main."
  ! git rev-parse -q --verify "refs/tags/v$VERSION" > /dev/null || fail "tag v$VERSION exists."
  [ -d "$TAP_DIR/.git" ] || fail "no tap checkout at $TAP_DIR."
  [ -z "$(git -C "$TAP_DIR" status --porcelain)" ] || fail "$TAP_DIR has uncommitted changes."
fi

VERSION="$VERSION" SIGN_IDENTITY="$SIGN_IDENTITY" scripts/build-app.sh

# Notarize, then staple the ticket to the app so Gatekeeper also passes offline.
rm -f build/pnow-notarize.zip "$ZIP"
ditto -c -k --keepParent build/pnow.app build/pnow-notarize.zip
xcrun notarytool submit build/pnow-notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > build/notary.json || true
if [ "$(plutil -extract status raw build/notary.json 2> /dev/null)" != Accepted ]; then
  cat build/notary.json >&2
  id="$(plutil -extract id raw build/notary.json 2> /dev/null || true)"
  [ -z "$id" ] || xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2
  fail "notarization failed."
fi
xcrun stapler staple build/pnow.app
spctl --assess --type execute --verbose build/pnow.app

ditto -c -k --keepParent build/pnow.app "$ZIP"
rm -f build/pnow-notarize.zip
SHA256="$(shasum -a 256 "$ZIP" | awk '{ print $1 }')"
echo "$ZIP sha256 $SHA256"

# A feed with only this release: Sparkle needs nothing older.
ED_SIGNATURE="$("$SPARKLE_BIN/sign_update" -p "$ZIP")"
cat > build/appcast.xml << FEED
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>pnow</title>
    <item>
      <title>pnow $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <link>https://github.com/$REPO/releases/tag/v$VERSION</link>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/pnow-$VERSION.zip" type="application/octet-stream" length="$(stat -f %z "$ZIP")" sparkle:edSignature="$ED_SIGNATURE"/>
    </item>
  </channel>
</rss>
FEED
xmllint --noout build/appcast.xml

if [ "$DRY_RUN" = "--dry-run" ]; then
  echo "Dry run: nothing published."
  exit 0
fi

git push origin main
git tag "v$VERSION"
git push origin "v$VERSION"
gh release create "v$VERSION" "$ZIP" build/appcast.xml --repo "$REPO" --title "pnow $VERSION" --generate-notes

mkdir -p "$TAP_DIR/Casks"
sed -e "s/__VERSION__/$VERSION/" -e "s/__SHA256__/$SHA256/" packaging/pnow.rb > "$TAP_DIR/Casks/pnow.rb"
git -C "$TAP_DIR" add Casks/pnow.rb
git -C "$TAP_DIR" commit -m "pnow $VERSION"
git -C "$TAP_DIR" push origin HEAD

echo "Released pnow $VERSION. Install: brew install --cask tarasyarema/tap/pnow"
