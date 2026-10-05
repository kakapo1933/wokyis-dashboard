#!/bin/bash
# build.sh — offline build of build/WokyisPanel.app (spec §1). No sudo, no network, Apple toolchain only.
# bash 3.2 compatible. Steps: swiftc (Swift 5 language mode, explicit source list) → Info.plist → ad-hoc codesign
# → codesign --verify → --selftest (non-zero fails the build) → tools/build.sh.
# Owner: core (skeleton step). Set SKIP_TOOLS=1 to skip tools/build.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/WokyisPanel.app
mkdir -p "$APP/Contents/MacOS"
SRC=(
  Sources/App/main.swift Sources/App/AppController.swift Sources/App/DisplayLocator.swift Sources/App/PanelView.swift
  Sources/App/Signals.swift Sources/App/StatusMenu.swift Sources/App/HotKeys.swift
  Sources/Render/PanelModel.swift Sources/Render/PanelRenderer.swift Sources/Render/StateBuilder.swift
  Sources/Render/L10n.swift Sources/Render/PanelRenderer+Views.swift Sources/Render/RenderSelfTest.swift
  Sources/System/CPUSource.swift Sources/System/NetSource.swift Sources/System/SystemSampler.swift
  Sources/System/ProcNetSource.swift
  Sources/Memory/SysctlTable.swift Sources/Memory/MemoryFormulas.swift Sources/Memory/MemorySampler.swift
  Sources/Memory/HostAudit.swift Sources/Memory/AMFormat.swift Sources/Memory/PressureHistory.swift
  Sources/Battery/HIDSource.swift Sources/Battery/AccessorySource.swift Sources/Battery/BTProfilerSource.swift
  Sources/Battery/BatteryAggregator.swift Sources/Battery/BatteryMonitor.swift
  Sources/Core/SourceID.swift Sources/Core/Types.swift Sources/Core/Config.swift Sources/Core/Injector.swift
  Sources/Core/EventLog.swift Sources/Core/Support.swift Sources/Core/Headless.swift Sources/Core/Store.swift
  Sources/Core/Settings.swift
  Sources/Evidence/Snapshot.swift Sources/Evidence/SelfTest.swift
  Sources/Evidence/GoldenFixture.swift Sources/Evidence/Golden.swift Sources/Evidence/GoldenPin.swift
)
echo "swiftc: ${#SRC[@]} files"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 "${SRC[@]}" \
  -framework AppKit -framework IOKit -framework CoreText -framework Carbon -o "$APP/Contents/MacOS/WokyisPanel"
cp Resources/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources" && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # icon: Resources/icon/make_icon.swift
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose=2 "$APP"
"$APP/Contents/MacOS/WokyisPanel" --selftest
if [ "${SKIP_TOOLS:-0}" != "1" ]; then
  tools/build.sh
fi
echo "build ok: $APP"
