#!/bin/bash
set -euo pipefail

# Extract macOS Intent.app → Resources + version
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

# Detect version from Info.plist (while DMG is still mounted)
VER="unknown"
if [ -f "$APP/Contents/Info.plist" ]; then
  VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo "unknown")
fi
echo "$VER" > "$OUTDIR/version.txt"
echo "Detected version: $VER"

# Unpacked directory (native modules + renderer + resources)
# Use tar to preserve all files including dotfiles
if [ -d "$RESOURCES/app.asar.unpacked" ]; then
  cd "$RESOURCES"
  tar cf "$OUTDIR/app.asar.unpacked.tar" "app.asar.unpacked"
  cd "$OUTDIR"
  tar xf "app.asar.unpacked.tar"
  rm "app.asar.unpacked.tar"
  cd /
fi

hdiutil detach "$TMPMOUNT" -quiet
rm -rf "$TMPMOUNT"

echo "Extracted to $OUTDIR"
ls -la "$OUTDIR/"
