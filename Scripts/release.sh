#!/bin/bash
#
# Produces a signed, notarised, stapled Quaydeck DMG and the appcast entry that
# tells existing installs about it.
#
#   ./Scripts/release.sh
#
# Requires, once:
#   * a "Developer ID Application" certificate in the keychain
#     (https://developer.apple.com/account/resources/certificates, then double-click
#      the download). An "Apple Distribution" certificate is App Store only and will
#      not work here.
#   * an App Store Connect API key at ~/.appstoreconnect/private_keys/AuthKey_<id>.p8
#   * Sparkle EdDSA keys, created with the generate_keys tool (see below)
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="Quaydeck"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
APP="$BUILD/$NAME.app"
DMG="$DIST/$NAME-$VERSION.dmg"

# Local, untracked settings: App Store Connect ids, signing identity, Sparkle key.
# Copy Scripts/release-env.example to Scripts/.release-env and fill it in.
# These are account identifiers, not secrets, but they do not belong in a public repo.
# set -a exports everything the file assigns, so build-app.sh (a child process)
# sees QUAYDECK_FEED_URL, QUAYDECK_PUBLIC_KEY and QUAYDECK_SIGN_IDENTITY too.
if [ -f "$ROOT/Scripts/.release-env" ]; then
  set -a
  . "$ROOT/Scripts/.release-env"
  set +a
fi

: "${ASC_KEY_PATH:=$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID:-}.p8}"
: "${QUAYDECK_DOWNLOAD_BASE:=https://github.com/quaydeck/quaydeck/releases/download}"

say() { printf '\033[1m→\033[0m %s\n' "$1"; }
die() { printf '\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------- preflight

security find-identity -v -p codesigning | grep -q 'Developer ID Application' \
  || die "no 'Developer ID Application' certificate found.

Create one at https://developer.apple.com/account/resources/certificates
  1. click +, choose 'Developer ID Application'
  2. upload a CSR (Keychain Access → Certificate Assistant → Request a Certificate)
  3. download the .cer and double-click it

You currently hold only Apple Distribution and Apple Development certificates,
neither of which can sign an app for distribution outside the App Store."

[ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] || die "missing App Store Connect credentials.

Copy Scripts/release-env.example to Scripts/.release-env and fill in ASC_KEY_ID and
ASC_ISSUER_ID. Both are shown at https://appstoreconnect.apple.com/access/integrations/api
The file is gitignored, so it stays on this machine."

[ -f "$ASC_KEY_PATH" ] || die "App Store Connect key not found at $ASC_KEY_PATH"

command -v create-dmg >/dev/null 2>&1 && HAVE_CREATE_DMG=true || HAVE_CREATE_DMG=false

# ---------------------------------------------------------------- build

[ -n "${QUAYDECK_FEED_URL:-}" ] && [ -n "${QUAYDECK_PUBLIC_KEY:-}" ] || die "missing Sparkle settings.

Without QUAYDECK_FEED_URL and QUAYDECK_PUBLIC_KEY the build ships with no updater,
and everyone who installs it is cut off from every later release. Set both in
Scripts/.release-env. The public key must be the one earlier releases carry:
  /usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' /Applications/Quaydeck.app/Contents/Info.plist"

say "Building release $VERSION"
"$ROOT/Scripts/build-app.sh" --release

# Sparkle compares sparkle:version with the installed CFBundleVersion, not with the
# marketing version. 1.0.0 shipped as build "100", and Sparkle reads "1.1.0" as older
# than "100", so the feed must carry the build number the app itself carries.
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
EMBEDDED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")"
[ "$EMBEDDED_KEY" = "$QUAYDECK_PUBLIC_KEY" ] || die "the built app carries the wrong Sparkle key"

# ---------------------------------------------------------------- dmg

say "Creating disk image"
mkdir -p "$DIST"
rm -f "$DMG"
STAGING="$BUILD/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "$NAME" -srcfolder "$STAGING" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGING"

IDENTITY="${QUAYDECK_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | grep 'Developer ID Application' | head -1 | sed 's/.*"\(.*\)"/\1/')}"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

# ---------------------------------------------------------------- notarise

say "Submitting to Apple for notarisation (this usually takes a few minutes)"
xcrun notarytool submit "$DMG" \
  --key "$ASC_KEY_PATH" \
  --key-id "$ASC_KEY_ID" \
  --issuer "$ASC_ISSUER_ID" \
  --wait \
  || die "notarisation failed. Run:
  xcrun notarytool log <submission-id> --key $ASC_KEY_PATH --key-id $ASC_KEY_ID --issuer $ASC_ISSUER_ID"

say "Stapling the ticket"
xcrun stapler staple "$DMG"

say "Verifying as Gatekeeper would"
spctl -a -vvv -t install "$DMG" 2>&1 | sed 's/^/    /'

# ---------------------------------------------------------------- appcast

SIGN_UPDATE="$(find "$ROOT/.build/artifacts" -name 'sign_update' -type f 2>/dev/null | head -1)"
SIZE="$(stat -f%z "$DMG")"
PUBLISHED="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"

if [ -n "$SIGN_UPDATE" ]; then
  say "Signing the update for Sparkle"
  if SIGNATURE_LINE="$("$SIGN_UPDATE" "$DMG" 2>/dev/null)"; then
    # sign_update emits its own length="..." and the template below adds one
    # too, which is a duplicate attribute and therefore invalid XML.
    SIGNATURE_LINE="${SIGNATURE_LINE% length=*}"
  else
    SIGNATURE_LINE=""
    say "  no Sparkle key yet. Create one once with:"
    say "    $(dirname "$SIGN_UPDATE")/generate_keys"
    say "  then put the printed public key in QUAYDECK_PUBLIC_KEY and rebuild."
  fi
else
  SIGNATURE_LINE=""
  say "  sign_update not found, appcast will need signing by hand"
fi

cat > "$DIST/appcast-entry.xml" <<XML
<item>
  <title>$VERSION</title>
  <pubDate>$PUBLISHED</pubDate>
  <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
  <sparkle:releaseNotesLink>https://github.com/quaydeck/quaydeck/releases/tag/v$VERSION</sparkle:releaseNotesLink>
  <enclosure url="$QUAYDECK_DOWNLOAD_BASE/v$VERSION/$NAME-$VERSION.dmg"
             sparkle:version="$BUILD_NUMBER"
             sparkle:shortVersionString="$VERSION"
             length="$SIZE"
             type="application/octet-stream"
             $SIGNATURE_LINE />
</item>
XML

say "Done."
echo
echo "  DMG:     $DMG"
echo "  Appcast: $DIST/appcast-entry.xml  (paste into the <channel> of appcast.xml)"
echo
echo "Next: create a GitHub release tagged v$VERSION, attach the DMG,"
echo "      and publish the updated appcast.xml."
