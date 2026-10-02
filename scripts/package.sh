#!/bin/bash
# package.sh — build/WokyisPanel.app → dist/WokyisPanel-<CFBundleShortVersionString>.dmg and its .sha256: a
# drag-to-Applications disk image whose Finder window shows a classic-Macintosh copy-window background
# (Resources/dmg/make_background.swift), the app on the left and an /Applications link on the right
# (Resources/dmg/layout.applescript), and the app icon as the volume icon. Offline, Apple tools only (hdiutil, ditto,
# tiffutil, SetFile, osascript, shasum). Runs scripts/build.sh first (SKIP_TOOLS=1) unless SKIP_BUILD=1.
# Needs: no volume named "Wokyis Panel <version>" mounted (Finder addresses the image by that name); permission for
# the terminal to control Finder (asked on the first run: System Settings > Privacy & Security > Automation).
# TITLE_BAR=<pt> overrides the Finder title-bar height (default 32, measured on macOS 27). The app is ad-hoc signed
# (no Developer ID / notarization). bash 3.2 compatible.
set -euo pipefail
cd "$(dirname "$0")/.."
[ "${SKIP_BUILD:-0}" = 1 ] || SKIP_TOOLS=1 scripts/build.sh
APP=build/WokyisPanel.app
ver=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
vol="Wokyis Panel $ver"
codesign --verify --strict --verbose=2 "$APP"
if [ -e "/Volumes/$vol" ]; then
  echo "package.sh: /Volumes/$vol is mounted; eject it first (hdiutil detach \"/Volumes/$vol\")" >&2; exit 1
fi
mkdir -p dist
work=$(mktemp -d "${TMPDIR:-/tmp}/wokyis-dmg.XXXXXX")
mnt=""
cleanup() { [ -n "$mnt" ] && hdiutil detach -quiet -force "$mnt" 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT
stage="$work/stage"; mkdir -p "$stage/.background"; chmod 755 "$stage"      # becomes the volume root
ditto --norsrc --noextattr "$APP" "$stage/WokyisPanel.app"
codesign --verify --strict "$stage/WokyisPanel.app"   # the copied bundle keeps its signature
ln -s /Applications "$stage/Applications"
swift Resources/dmg/make_background.swift "$work" > /dev/null
tiffutil -cathidpicheck "$work/background.png" "$work/background@2x.png" -out "$stage/.background/background.tiff" > /dev/null 2>&1
# read-write image → Finder lays the window out (it writes the volume's .DS_Store) → compressed read-only image
hdiutil create -quiet -volname "$vol" -srcfolder "$stage" -fs HFS+ -format UDRW -size 16m "$work/rw.dmg"
mnt=$(hdiutil attach -readwrite -noverify -noautoopen "$work/rw.dmg" 2>/dev/null | awk -F'\t' '/\/Volumes\//{print $NF}')
[ "$mnt" = "/Volumes/$vol" ] || { echo "package.sh: mounted at '$mnt', expected /Volumes/$vol" >&2; exit 1; }
osascript Resources/dmg/layout.applescript "$vol" WokyisPanel.app "${TITLE_BAR:-32}"
osascript -e "tell application \"Finder\" to close (every window whose name is \"$vol\")" > /dev/null 2>&1 || true
# volume icon only after the layout: Finder's layout pass removed .VolumeIcon.icns and cleared the custom-icon flag
# (seen 2026-10-02); hdiutil -srcfolder does not carry the file over either
cp Resources/AppIcon.icns "$mnt/.VolumeIcon.icns"
SetFile -a C "$mnt"
sync
[ -s "$mnt/.DS_Store" ] || { echo "package.sh: Finder did not write $mnt/.DS_Store" >&2; exit 1; }
hdiutil detach -quiet "$mnt"; mnt=""
name="WokyisPanel-$ver.dmg"
# built and checked outside dist/, then moved in together: dist/ never holds a DMG with another run's .sha256
hdiutil convert -quiet "$work/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$work/$name"
hdiutil verify -quiet "$work/$name"
(cd "$work" && shasum -a 256 "$name" > "$name.sha256")
mv -f "$work/$name" "$work/$name.sha256" dist/
echo "dist/$name ($(du -h "dist/$name" | cut -f1 | tr -d ' '))"
cat "dist/$name.sha256"
