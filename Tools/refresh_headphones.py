#!/usr/bin/env python3
"""Regenerate Resources/headphones.json from the live AutoEQ catalog.

Run from the repo root via Tools/refresh-headphones.sh, or directly:

    python3 Tools/refresh_headphones.py > Resources/headphones.json

The script mirrors HeadphoneIndex.refreshFromNetwork() (in
Sources/HeadphoneIndex.swift) so the dev-time snapshot and the runtime
refresh produce identical entries. We bundle the snapshot so a fresh
install works offline with a current catalog; the runtime refresh keeps
things fresh after that. The AutoEQ repo has restructured before (e.g.
`harman_over-ear_2018` -> `over-ear`), which invalidates bundled URLs
silently. Re-run this whenever you want the shipped snapshot updated.

Each measurer accepted by AutoEQ has the same shape:

    results/<measurer>/<measurement-set>/<headphone>/<headphone> ParametricEQ.txt

so we enumerate everything under the measurer's root and emit one entry
per headphone folder.
"""

import json
import sys
import urllib.parse
import urllib.request

API_BASE = "https://api.github.com/repos/jaakkopasanen/AutoEq/contents/results"
RAW_BASE = "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results"
HEADERS = {
    "Accept": "application/vnd.github+json",
    "User-Agent": "earshot-refresh",
}

# Measurers to include in the bundled snapshot. Order matters for de-dupe:
# the first measurer that has a given headphone wins, so put the most
# trusted source first.
MEASURERS = ["oratory1990", "crinacle"]


def fetch(url):
    req = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(req, timeout=30) as r:
        if r.status == 403:
            raise RuntimeError("GitHub rate-limited (HTTP 403). Try again later.")
        return json.load(r)


def quote(s):
    return urllib.parse.quote(s, safe="")


def gather(measurer):
    sets = fetch(f"{API_BASE}/{quote(measurer)}")
    out = []
    for s in sets:
        if s.get("type") != "dir":
            continue
        set_name = s["name"]
        try:
            headphones = fetch(f"{API_BASE}/{quote(measurer)}/{quote(set_name)}")
        except Exception as e:
            print(f"warn: {measurer}/{set_name}: {e}", file=sys.stderr)
            continue
        for h in headphones:
            if h.get("type") != "dir":
                continue
            name = h["name"]
            raw = (f"{RAW_BASE}/{quote(measurer)}/{quote(set_name)}/"
                   f"{quote(name)}/{quote(name)}%20ParametricEQ.txt")
            out.append({"name": name, "measurer": measurer, "rawTxtURL": raw})
    return out


def main():
    entries = []
    seen = set()
    for m in MEASURERS:
        for entry in gather(m):
            key = entry["name"].lower()
            if key in seen:
                continue
            seen.add(key)
            entries.append(entry)
    entries.sort(key=lambda e: e["name"].lower())
    json.dump(entries, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    print(f"wrote {len(entries)} entries", file=sys.stderr)


if __name__ == "__main__":
    main()
