#!/bin/bash
# Refresh the bundled AutoEQ catalog snapshot at Resources/headphones.json.
# The runtime refresh in HeadphoneIndex.swift keeps installed users current,
# but a fresh install ships whatever this snapshot contains - re-run when
# the AutoEQ repo restructures or you want the shipped snapshot updated.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="Resources/headphones.json"
TMP="$OUT.tmp"

python3 Tools/refresh_headphones.py > "$TMP"
mv "$TMP" "$OUT"

count=$(grep -c '"name"' "$OUT")
echo "Refreshed: $count headphones in $OUT"
