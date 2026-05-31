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
MEASURERS = [
    "oratory1990", "crinacle", "Super Review", "innerfidelity", "rtings",
    "Kuulokenurkka", "DHRME", "HypetheSonics", "jaytiss", "RikudouGoku",
    "kr0mka", "Bakkwatan", "Filk", "Harpo", "ToneDeafMonk",
    "Headphone.com Legacy", "Hi End Portable", "Ted's Squig Hoard",
    "Auriculares Argentina", "Regan Cipher", "freeryder05", "Fahryst", "Kazi",
]


# Mirror of HeadphoneEntry.deriveMetadata in Sources/HeadphoneIndex.swift so
# the bundled snapshot already carries rig / target / set fields. Loaders
# that backfill on read still work, but pre-populating saves a round of
# parsing on first launch and surfaces issues at refresh time.

def rig_from_set(set_name):
    s = set_name.lower()
    if "5128" in s: return "B&K 5128"
    if "gras 43ag-7" in s or "gras_43ag-7" in s: return "GRAS 43AG-7"
    if "gras" in s: return "GRAS 43AG"
    if "kb006x" in s: return "KB006x"
    if "ears" in s: return "EARS"
    if "hms ii" in s or "hms_ii" in s: return "HMS II.3"
    if "kemar" in s: return "KEMAR"
    if "711" in s or "in-ear" in s or "in_ear" in s: return "IEC 60318-4 (711)"
    return None


def target_from_set(set_name):
    s = set_name.lower()
    if "harman_in-ear_2019_v2" in s or "harman 2019 v2" in s: return "Harman 2019 IE v2"
    if "harman_in-ear_2019" in s or "harman 2019" in s: return "Harman 2019 IE"
    if "harman_in-ear_2017" in s or "harman 2017 ie" in s: return "Harman 2017 IE"
    if "harman_over-ear_2018" in s or "harman 2018" in s: return "Harman 2018 OE"
    if "harman_over-ear_2015" in s or "harman 2015" in s: return "Harman 2015 OE"
    if "autoeq_in-ear" in s: return "AutoEQ IE"
    if "autoeq_over-ear" in s: return "AutoEQ OE"
    if "ief" in s: return "IEF Neutral"
    if "jm-1" in s or "jm1" in s: return "JM-1"
    if "diffuse field" in s or "diffuse_field" in s: return "Diffuse Field"
    if "free field" in s or "free_field" in s: return "Free Field"
    return None


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
            entry = {"name": name, "measurer": measurer, "rawTxtURL": raw,
                     "set": set_name}
            rig = rig_from_set(set_name)
            target = target_from_set(set_name)
            if rig: entry["rig"] = rig
            if target: entry["target"] = target
            out.append(entry)
    return out


def main():
    entries = []
    # De-dupe by (name, target). The runtime refresher does the same so
    # the bundled snapshot and the live refresh produce identical sets.
    seen = set()
    for m in MEASURERS:
        try:
            for entry in gather(m):
                key = f'{entry["name"].lower()}|{(entry.get("target") or "").lower()}'
                if key in seen:
                    continue
                seen.add(key)
                entries.append(entry)
        except Exception as e:
            print(f"warn: {m} (skipped): {e}", file=sys.stderr)
            continue
    entries.sort(key=lambda e: (e["name"].lower(), e.get("target") or ""))
    json.dump(entries, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    print(f"wrote {len(entries)} entries", file=sys.stderr)


if __name__ == "__main__":
    main()
