#!/bin/bash
#
# Builds Quaydeck.app.
#
#   ./Scripts/build-app.sh              universal, ad-hoc signed, for local use
#   ./Scripts/build-app.sh --install    the same, copied into /Applications and launched
#   ./Scripts/build-app.sh --release    signed with your Developer ID, hardened runtime
#
# Signing identity comes from $QUAYDECK_SIGN_IDENTITY, defaulting to the first
# "Developer ID Application" certificate in the keychain.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="Quaydeck"
BUNDLE_ID="app.quaydeck.Quaydeck"
MIN_MACOS="13.0"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD_NUMBER="${QUAYDECK_BUILD_NUMBER:-$(printf '%s' "$VERSION" | tr -d '.')}"

BUILD="$ROOT/build"
APP="$BUILD/$NAME.app"
CONTENTS="$APP/Contents"

INSTALL=false
RELEASE=false
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=true ;;
    --release) RELEASE=true ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '\033[1m→\033[0m %s\n' "$1"; }
die() { printf '\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------- build

say "Building universal binary (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64 --package-path "$ROOT"

BINARY="$ROOT/.build/apple/Products/Release/$NAME"
[ -f "$BINARY" ] || die "expected a universal binary at $BINARY"

# Poort shipped an Info.plist claiming macOS 13 around a binary built for macOS 26,
# so it crashed on launch for everyone who was not on the newest system. Never again.
say "Verifying deployment target"
ACTUAL_MIN="$(otool -l "$BINARY" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
[ -n "$ACTUAL_MIN" ] || die "could not read the binary's minimum OS version"
if [ "$(printf '%s\n%s\n' "$MIN_MACOS" "$ACTUAL_MIN" | sort -V | head -1)" != "$MIN_MACOS" ]; then
  die "binary requires macOS $ACTUAL_MIN but the bundle advertises $MIN_MACOS"
fi

ARCHS="$(lipo -archs "$BINARY")"
case "$ARCHS" in
  *arm64*x86_64*|*x86_64*arm64*) ;;
  *) die "expected a universal binary, got: $ARCHS" ;;
esac
say "  macOS $ACTUAL_MIN, architectures: $ARCHS"

# ---------------------------------------------------------------- assemble

say "Assembling $NAME.app"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"
cp "$BINARY" "$CONTENTS/MacOS/$NAME"

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
else
  say "  no AppIcon.icns yet, run: swift Scripts/make-icon.swift build/Quaydeck.iconset"
fi

SPARKLE="$(find "$ROOT/.build/artifacts" -maxdepth 6 -name 'Sparkle.framework' -type d 2>/dev/null | head -1)"
if [ -n "$SPARKLE" ]; then
  say "  embedding Sparkle"
  cp -R "$SPARKLE" "$CONTENTS/Frameworks/"
  # SwiftPM links Sparkle as @rpath/... but only emits rpaths pointing at its own
  # build layout, so a bundled framework is invisible at launch. This must happen
  # before signing, since it rewrites the binary.
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$CONTENTS/MacOS/$NAME" 2>/dev/null || true
else
  say "  Sparkle not found in build artifacts, the app will run without an updater"
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT licensed. https://github.com/quaydeck/quaydeck</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>NSAppleEventsUsageDescription</key><string>Quaydeck uses Terminal to restart a dev server, so you can watch its output.</string>
  <key>SUFeedURL</key><string>${QUAYDECK_FEED_URL:-}</string>
  <key>SUPublicEDKey</key><string>${QUAYDECK_PUBLIC_KEY:-}</string>
  <key>SUEnableInstallerLauncherService</key><false/>
</dict>
</plist>
PLIST

# ---------------------------------------------------------------- sign

if $RELEASE; then
  IDENTITY="${QUAYDECK_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | grep 'Developer ID Application' | head -1 | sed 's/.*"\(.*\)"/\1/')}"
  if [ -z "$IDENTITY" ]; then
    die "no 'Developer ID Application' certificate in the keychain.

Create one at https://developer.apple.com/account/resources/certificates
choosing 'Developer ID Application', then download and double-click it.
An 'Apple Distribution' certificate is for the App Store and will not work
for direct distribution."
  fi
  say "Signing with: $IDENTITY"
  SIGN_ARGS=(--force --options runtime --timestamp --sign "$IDENTITY")
else
  say "Signing ad-hoc (development build)"
  SIGN_ARGS=(--force --sign -)
fi

# Nested code must be signed before the thing that contains it.
if [ -d "$CONTENTS/Frameworks/Sparkle.framework" ]; then
  SPARKLE_VERSION="$CONTENTS/Frameworks/Sparkle.framework/Versions/B"
  for nested in "$SPARKLE_VERSION"/XPCServices/*.xpc "$SPARKLE_VERSION"/Updater.app; do
    [ -e "$nested" ] || continue
    codesign "${SIGN_ARGS[@]}" "$nested"
  done
  [ -e "$SPARKLE_VERSION/Autoupdate" ] && codesign "${SIGN_ARGS[@]}" "$SPARKLE_VERSION/Autoupdate"
  codesign "${SIGN_ARGS[@]}" "$CONTENTS/Frameworks/Sparkle.framework"
fi

codesign "${SIGN_ARGS[@]}" \
  --entitlements "$ROOT/Scripts/Quaydeck.entitlements" \
  --identifier "$BUNDLE_ID" \
  "$APP"

codesign --verify --deep --strict "$APP" || die "signature verification failed"
say "Signature verified"

# ---------------------------------------------------------------- install

if $INSTALL; then
  DEST="/Applications/$NAME.app"
  say "Installing to $DEST"
  # -x matches the exact process name, so this can only ever stop Quaydeck.
  pkill -x "$NAME" 2>/dev/null || true
  sleep 0.3
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  open "$DEST"
  say "Launched. Look for the sailboat in your menu bar."
else
  say "Built: $APP"
fi
