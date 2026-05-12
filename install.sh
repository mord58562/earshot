#!/bin/bash
# Build Earshot.app, ensure BlackHole 2ch is installed, and copy the
# app into /Applications/.
set -euo pipefail
cd "$(dirname "$0")"

BLACKHOLE_DRIVER="/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver"

ensure_blackhole() {
    if [ -d "$BLACKHOLE_DRIVER" ]; then
        echo "→ BlackHole 2ch already installed; skipping."
        return 0
    fi

    echo
    echo "→ BlackHole 2ch is not installed (Earshot needs it to capture system audio)."

    if command -v brew >/dev/null 2>&1; then
        echo "  Installing via Homebrew: brew install blackhole-2ch"
        echo "  (this requires admin privileges - brew may prompt you for your password)"
        # blackhole-2ch is a cask; in modern Homebrew `brew install` handles
        # both formulas and casks, so we don't need to specify --cask.
        if brew install blackhole-2ch; then
            echo "  BlackHole 2ch installed."
        else
            echo
            echo "  Homebrew install failed. Install it manually from:"
            echo "    https://existential.audio/blackhole/"
            echo "  then re-run ./install.sh."
            return 1
        fi
    else
        echo
        echo "  Homebrew is not installed, so this script can't auto-install"
        echo "  BlackHole. You have two options:"
        echo
        echo "  1. Install Homebrew (https://brew.sh), then re-run ./install.sh."
        echo "  2. Install BlackHole 2ch manually from"
        echo "     https://existential.audio/blackhole/  and re-run ./install.sh."
        return 1
    fi

    # Verify the driver is actually present now. BlackHole sometimes
    # requires the user to reboot before the HAL plugin loads; warn if so.
    if [ ! -d "$BLACKHOLE_DRIVER" ]; then
        echo
        echo "  BlackHole was installed but the driver hasn't loaded yet."
        echo "  A reboot may be required. After rebooting, re-run ./install.sh."
        return 1
    fi
}

ensure_blackhole

./build.sh

echo
echo "→ Installing Earshot.app to /Applications/"
# Stop any running Earshot before replacing the bundle, otherwise the
# overwrite leaves an open file handle pointing at the old binary.
pkill -f "Earshot.app/Contents/MacOS/Earshot" 2>/dev/null || true
rm -rf /Applications/Earshot.app
cp -R Earshot.app /Applications/Earshot.app
echo "  installed."

echo
echo "→ Launching Earshot."
open /Applications/Earshot.app

echo
echo "Done. Earshot is at /Applications/Earshot.app and should now be running."
echo "First launch may need a right-click → Open to bypass Gatekeeper"
echo "(this build is ad-hoc-signed, not Developer ID notarized)."
