#!/bin/bash
#
# Builds Resources/AppIcon.icns from the master artwork in brand/icon/AppIcon-1024.png,
# at every size macOS asks for.
#
#   ./Scripts/make-icon.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/brand/icon/AppIcon-1024.png"
ICONSET="$ROOT/build/AppIcon.iconset"

[ -f "$SOURCE" ] || { echo "missing $SOURCE" >&2; exit 1; }
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
echo "Wrote Resources/AppIcon.icns"
