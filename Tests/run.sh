#!/bin/bash
# Compile-and-run a tiny test binary. No XCTest, no project file.
set -euo pipefail
cd "$(dirname "$0")/.."

swiftc \
    Sources/Logging.swift \
    Sources/Models.swift \
    Sources/Devices.swift \
    Sources/Storage.swift \
    Sources/AutoEQFormat.swift \
    Tests/main.swift \
    -o /tmp/earshot-tests \
    -framework Cocoa \
    -framework AVFoundation \
    -framework CoreAudio \
    -target arm64-apple-macosx13.0

/tmp/earshot-tests
