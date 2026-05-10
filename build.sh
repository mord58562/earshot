#!/bin/bash
# Build Earshot.app
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Earshot"
BUNDLE="$APP_NAME.app"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

cp Info.plist "$BUNDLE/Contents/Info.plist"

# Generate the app icon (.icns) into Resources.
if [ ! -f "Resources/AppIcon.icns" ] || [ "Tools/MakeAppIcon.swift" -nt "Resources/AppIcon.icns" ]; then
  echo "Generating app icon…"
  swift Tools/MakeAppIcon.swift "Resources/AppIcon.icns"
fi

cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns" 2>/dev/null || true
cp Resources/presets.json   "$BUNDLE/Contents/Resources/presets.json"
cp Resources/headphones.json "$BUNDLE/Contents/Resources/headphones.json" 2>/dev/null || true

SOURCES=(
  Sources/Logging.swift
  Sources/Models.swift
  Sources/Devices.swift
  Sources/Storage.swift
  Sources/AudioRingBuffer.swift
  Sources/InputCapture.swift
  Sources/EQEngine.swift
  Sources/AutoEQFormat.swift
  Sources/HeadphoneIndex.swift
  Sources/AppState.swift
  Sources/Icon.swift
  Sources/Popover.swift
  Sources/main.swift
)

swiftc \
    "${SOURCES[@]}" \
    Sources/Vendor/TPCircularBuffer.c \
    Sources/Vendor/TPCircularBufferSwift.c \
    -import-objc-header Sources/Earshot-Bridging-Header.h \
    -o "$BUNDLE/Contents/MacOS/$APP_NAME" \
    -framework Cocoa \
    -framework AVFoundation \
    -framework CoreAudio \
    -framework SwiftUI \
    -framework Combine \
    -framework ServiceManagement \
    -O \
    -target arm64-apple-macosx13.0

# Ad-hoc sign with hardened runtime + audio-input entitlement. The
# entitlement is required because the input AUHAL reads from BlackHole
# (macOS classifies any audio input, including virtual ones, as a mic);
# without it, the render proc receives only silence.
codesign --force --deep --sign - \
         --options runtime \
         --entitlements Earshot.entitlements \
         "$BUNDLE" >/dev/null

echo "Built: $(pwd)/$BUNDLE"
