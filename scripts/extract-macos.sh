#!/bin/bash
set -euo pipefail

# Extract macOS Intent.app → app.asar + app.asar.unpacked
# Usage: extract-macos.sh <path-to-Intent.dmg> <output-dir>

DMG="$1"
OUTDIR="$2"

TMPMOUNT=$(mktemp -d)
hdiutil attach "$DMG" -mountpoint "$TMPMOUNT" -nobrowse -quiet

APP=$(find "$TMPMOUNT" -maxdepth 2 -name "*.app" -type d | head -1)
if [ -z "$APP" ]; then
  echo "ERROR: no .app found in DMG"
  hdiutil detach "$TMPMOUNT" -quiet
  exit 1
fi

RESOURCES="$APP/Contents/Resources"

mkdir -p "$OUTDIR"

# Core files
cp "$RESOURCES/app.asar" "$OUTDIR/"
cp "$RESOURCES/app-update.yml" "$OUTDIR/" 2>/dev/null || true
cp "$RESOURCES/icon.icns" "$OUTDIR/" 2>/dev/null || true

# Unpacked directory (native modules + renderer + resources)
if [ -d "$RESOURCES/app.asar.unpacked" ]; then
  cp -R "$RESOURCES/app.asar.unpacked" "$OUTDIR/"
fi

hdiutil detach "$TMPMOUNT" -quiet
rm -rf "$TMPMOUNT"

echo "Extracted to $OUTDIR"
ls -la "$OUTDIR/"
