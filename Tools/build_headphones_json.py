#!/usr/bin/env python3
"""Build Resources/headphones.json from a treeless AutoEq clone.

Faster than the API-walking refresh script and immune to GitHub's
60-req/hr unauthenticated rate limit. Walks `git ls-tree -r HEAD
results/` to enumerate every `* ParametricEQ.txt`, derives
(measurer, set, name) from the path, and emits one JSON entry per
hit. De-duped on (name, target) to match the runtime refresh.

Usage:
    git clone --filter=tree:0 --no-checkout --depth=1 \\
        https://github.com/jaakkopasanen/AutoEq.git /tmp/autoeq-tree
    python3 /tmp/build_headphones_json.py \\
        /tmp/autoeq-tree > Resources/headphones.json
"""

import json, subprocess, sys, urllib.parse

RAW_BASE = "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results"


def rig_from_set(s):
    s = s.lower()
    if "5128" in s: return "B&K 5128"
    if "gras 43ag-7" in s or "gras_43ag-7" in s: return "GRAS 43AG-7"
    if "gras" in s: return "GRAS 43AG"
    if "kb006x" in s: return "KB006x"
    if "ears" in s: return "EARS"
    if "hms ii" in s or "hms_ii" in s: return "HMS II.3"
    if "kemar" in s: return "KEMAR"
    if "711" in s or "in-ear" in s or "in_ear" in s: return "IEC 60318-4 (711)"
    return None


def target_from(measurer, set_name):
    """Infer the target curve AutoEQ tuned this PEQ against.

    AutoEQ folder names encode RIG, not target. The target is convention
    per (measurer, rig): oratory1990 hand-tunes against Harman, AutoEQ
    auto-fits against Harman 2018/2019 for over-ear/in-ear by default
    on rigs that have a Harman target, and against JM-1/IEF on the 5128
    where Crinacle pinned those as the modern defaults. This mirrors
    the same inference HeadphoneIndex.swift does at load time.
    """
    s = set_name.lower()
    m = measurer.lower()

    # 5128-based sets. Crinacle's modern primary uses JM-1 for IEMs;
    # AutoEQ's mirror predates that and used IEF Neutral, so default
    # to JM-1 only when the measurer is Crinacle.
    if "5128" in s:
        if "in-ear" in s or "iem" in s:
            return "JM-1" if "crinacle" in m else "IEF Neutral"
        if "over-ear" in s:
            return "Harman 2018 OE"
        if "earbud" in s:
            return None
    if "ief" in s: return "IEF Neutral"
    if "jm-1" in s or "jm1" in s: return "JM-1"

    # 711 IEMs (incl. AutoEQ's bare "in-ear" sets which are 711-couplered).
    if "711" in s or "in-ear" in s:
        return "Harman 2019 IE"

    # Over-ear rigs default to Harman 2018 OE - that's what AutoEQ tunes
    # to and what oratory1990 hand-tunes to in practice.
    if ("over-ear" in s or "gras" in s or "kemar" in s
            or "hms" in s or "ears" in s):
        return "Harman 2018 OE"

    return None


# Preference order for the (name, target) de-dupe - earlier wins.
# Match Swift's measurers list so the bundled snapshot and the runtime
# refresh agree on which measurement wins when nothing distinguishes
# them by target curve.
MEASURER_PRIORITY = {
    "oratory1990": 0, "crinacle": 1, "Super Review": 2, "Innerfidelity": 3,
    "Rtings": 4, "Kuulokenurkka": 5, "DHRME": 6, "HypetheSonics": 7,
    "Jaytiss": 8, "RikudouGoku": 9, "kr0mka": 10, "Bakkwatan": 11,
    "Filk": 12, "Harpo": 13, "ToneDeafMonk": 14, "Headphone.com Legacy": 15,
    "Hi End Portable": 16, "Ted's Squig Hoard": 17,
    "Auriculares Argentina": 18, "Regan Cipher": 19, "freeryder05": 20,
    "Fahryst": 21, "Kazi": 22,
}


def main():
    repo = sys.argv[1] if len(sys.argv) > 1 else "/tmp/autoeq-tree"
    out_lines = subprocess.check_output(
        ["git", "-C", repo, "ls-tree", "-r", "--name-only", "HEAD", "results/"],
        text=True,
    ).splitlines()

    raw_entries = []
    for path in out_lines:
        if not path.endswith(" ParametricEQ.txt"):
            continue
        parts = path.split("/")
        # results/<measurer>/<set>/<headphone>/<headphone> ParametricEQ.txt
        if len(parts) != 5:
            continue
        _, measurer, set_name, folder, fname = parts
        # The headphone name is the folder name, not the fname stem - some
        # entries have ` ParametricEQ.txt` appended to a name that also ends
        # with spaces, and the folder name is the cleaner source of truth.
        name = folder
        raw = (
            f"{RAW_BASE}/{urllib.parse.quote(measurer)}/{urllib.parse.quote(set_name)}/"
            f"{urllib.parse.quote(folder)}/{urllib.parse.quote(fname)}"
        )
        entry = {"name": name, "measurer": measurer, "rawTxtURL": raw, "set": set_name}
        rig = rig_from_set(set_name)
        target = target_from(measurer, set_name)
        if rig: entry["rig"] = rig
        if target: entry["target"] = target
        raw_entries.append(entry)

    # Sort by measurer priority FIRST so the de-dupe keeps the highest-
    # priority entry per (name, target) bucket. Unknown measurers go to
    # the end - they still ship, just lose ties.
    def prio(e):
        return MEASURER_PRIORITY.get(e["measurer"], 99)
    raw_entries.sort(key=prio)

    seen = set()
    deduped = []
    for e in raw_entries:
        key = (e["name"].lower(), (e.get("target") or "").lower())
        if key in seen: continue
        seen.add(key)
        deduped.append(e)

    deduped.sort(key=lambda e: (e["name"].lower(), e.get("target") or ""))
    json.dump(deduped, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    print(f"wrote {len(deduped)} entries (from {len(raw_entries)} raw files, "
          f"deduped on (name, target))", file=sys.stderr)


if __name__ == "__main__":
    main()
