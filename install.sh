#!/bin/bash
# Build Earshot.app and install it into /Applications/.
set -euo pipefail
cd "$(dirname "$0")"

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
echo "Done. Earshot is at /Applications/Earshot.app — open it to launch."
echo "First launch may need a right-click → Open to bypass Gatekeeper"
echo "(this build is ad-hoc-signed, not Developer ID notarized)."
