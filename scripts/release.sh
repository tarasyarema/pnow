#!/usr/bin/env bash
#
# Releases pnow: a signed, notarized build on GitHub Releases, then the cask bump in the tap.
#
#   scripts/release.sh 0.1.0
#   scripts/release.sh 0.1.0 --dry-run    # build, sign, notarize, staple: publish nothing
#
# Needs the "Developer ID Application" cert in your keychain and the notary profile from
#   xcrun notarytool store-credentials pnow-notary --apple-id <apple-id> --team-id 2HUBD5T348
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?Usage: scripts/release.sh <version> [--dry-run]}"
DRY_RUN="${2:-}"
SIGN_IDENTITY="Developer ID Application: Taras Yarema (2HUBD5T348)"
NOTARY_PROFILE=pnow-notary
REPO=tarasyarema/pnow
TAP_DIR="${TAP_DIR:-../taras-homebrew-tap}"
ZIP="build/pnow-$VERSION.zip"

fail() {
  echo "release: $*" >&2
  exit 1
}

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "the version must look like 1.2.3."

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

if [ "$DRY_RUN" = "--dry-run" ]; then
  echo "Dry run: nothing published."
  exit 0
fi

git push origin main
git tag "v$VERSION"
git push origin "v$VERSION"
gh release create "v$VERSION" "$ZIP" --repo "$REPO" --title "pnow $VERSION" --generate-notes

mkdir -p "$TAP_DIR/Casks"
sed -e "s/__VERSION__/$VERSION/" -e "s/__SHA256__/$SHA256/" packaging/pnow.rb > "$TAP_DIR/Casks/pnow.rb"
git -C "$TAP_DIR" add Casks/pnow.rb
git -C "$TAP_DIR" commit -m "pnow $VERSION"
git -C "$TAP_DIR" push origin HEAD

echo "Released pnow $VERSION. Install: brew install --cask tarasyarema/tap/pnow"
