#!/bin/bash
# package.sh — build/WokyisPanel.app → dist/WokyisPanel-<CFBundleShortVersionString>.dmg (drag-to-Applications disk
# image: the app + an /Applications link) and its .sha256. Offline, Apple tools only (hdiutil, ditto, shasum).
# Runs scripts/build.sh first (SKIP_TOOLS=1) unless SKIP_BUILD=1. The app is ad-hoc signed (no Developer ID / notarization).
# bash 3.2 compatible.
set -euo pipefail
cd "$(dirname "$0")/.."
[ "${SKIP_BUILD:-0}" = 1 ] || SKIP_TOOLS=1 scripts/build.sh
APP=build/WokyisPanel.app
ver=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
codesign --verify --strict --verbose=2 "$APP"
mkdir -p dist
work=$(mktemp -d "${TMPDIR:-/tmp}/wokyis-dmg.XXXXXX")
trap 'rm -rf "$work"' EXIT
stage="$work/stage"; mkdir "$stage"; chmod 755 "$stage"      # becomes the volume root
ditto --norsrc --noextattr "$APP" "$stage/WokyisPanel.app"
codesign --verify --strict "$stage/WokyisPanel.app"   # the copied bundle keeps its signature
ln -s /Applications "$stage/Applications"
name="WokyisPanel-$ver.dmg"
# built and checked outside dist/, then moved in together: dist/ never holds a DMG with another run's .sha256
hdiutil create -quiet -volname "Wokyis Panel $ver" -srcfolder "$stage" -fs HFS+ -format UDZO "$work/$name"
hdiutil verify -quiet "$work/$name"
(cd "$work" && shasum -a 256 "$name" > "$name.sha256")
mv -f "$work/$name" "$work/$name.sha256" dist/
echo "dist/$name ($(du -h "dist/$name" | cut -f1 | tr -d ' '))"
cat "dist/$name.sha256"
