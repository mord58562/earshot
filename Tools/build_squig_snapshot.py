#!/usr/bin/env python3
"""Bake every squig.link site's catalog + target list into bundled JSON.

Without this, a fresh install starts with only the ~6 K AutoEq-mirrored
headphones, and the target-curve dropdown shows only the 4-5 AutoEq
defaults. The squig.link expansion only lands after the runtime network
refresh, which takes ~30 seconds and requires the user to open the
Find-a-preset sheet at least once. This script does that fetch at
build time and stores the result alongside headphones.json so cold-
start sees the full library and the full target picker.

Writes:
    Resources/squig_catalog.json    list[HeadphoneEntry] for squig sources
    Resources/squig_targets.json    dict[sourceID, list[str]] for the dropdown

Run with:
    python3 Tools/build_squig_snapshot.py

Mirrors SquigFetcher.fetchCatalog + SquigFetcher.fetchTargets in
Sources/SquigFetcher.swift, so the bundled snapshot and the runtime
refresh produce identical data shape.
"""

import json
import re
import sys
import urllib.parse
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

ROOT = Path(__file__).parent.parent
RES = ROOT / "Resources"
SITES_FILE = RES / "squigsites.json"

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X) Earshot/1.4 build-snapshot"
TIMEOUT = 15
PARALLEL = 16


def fetch(url, accept=None):
    req = urllib.request.Request(url)
    req.add_header("User-Agent", UA)
    if accept:
        req.add_header("Accept", accept)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return r.read()


def expand_site(site):
    """Yield (source_id, label, base_url, type) per database on the site."""
    username = site["username"]
    url_type = site.get("urlType")
    if url_type == "root":
        base = "https://squig.link"
    elif url_type == "altDomain":
        base = site.get("altDomain") or f"https://{username}.squig.link"
    elif url_type == "subdomain":
        base = f"https://{username}.squig.link"
    else:
        base = f"https://squig.link/lab/{username}"
    for db in site.get("dbs") or []:
        folder = db.get("folder") or "/"
        db_type = db.get("type") or "IEMs"
        source_id = (username + folder.replace("/", "-")).strip("-")
        data_url = base.rstrip("/") + folder + "data/"
        cfg_url = base.rstrip("/") + folder + "config.js"
        yield source_id, db_type, data_url, cfg_url


def rig_for(db_type, username):
    if db_type == "5128":
        return "B&K 5128"
    if db_type == "Headphones":
        return "GRAS 43AG" if "kr0mka" in username.lower() else "GRAS 43AG-7"
    return "IEC 60318-4 (711)"


def default_target_for(db_type, username):
    if db_type == "5128":
        return "JM-1" if "graph" in username.lower() else "IEF Neutral 2023"
    if db_type == "Headphones":
        return "Harman 2018 OE"
    if db_type == "Earbuds":
        return "Diffuse Field"
    return "Harman 2019 IE"


# Mirror of SquigFetcher.parseTargetsFromConfigJS.
TARGETS_BLOCK_RE = re.compile(
    r"(?:const|let|var)\s+targets\s*=\s*\[(.*?)\]\s*;",
    re.DOTALL,
)
GROUP_RE = re.compile(
    r"\{\s*type\s*:\s*['\"]([^'\"]*)['\"]\s*,\s*files\s*:\s*\[([^\]]+)\]"
)
STRING_RE = re.compile(r"['\"]([^'\"]+)['\"]")


def parse_targets(js):
    m = TARGETS_BLOCK_RE.search(js)
    if not m:
        return []
    body = m.group(1)
    out = []
    seen = set()
    for g in GROUP_RE.finditer(body):
        type_ = g.group(1)
        type_lower = type_.lower()
        if type_.startswith("Δ") or "delta" in type_lower or "compensation" in type_lower:
            continue
        files_block = g.group(2)
        for s in STRING_RE.finditer(files_block):
            name = s.group(1)
            lower = name.lower()
            if name.startswith("Δ") or " comp" in lower or " tilt" in lower or "compensation" in lower:
                continue
            if name not in seen:
                seen.add(name)
                out.append(name)
    return out


def fetch_one(source_id, db_type, data_url, cfg_url, username):
    """Pull phone_book.json + config.js for one source. Returns (entries, targets)."""
    entries = []
    try:
        raw = fetch(data_url + "phone_book.json")
        brands = json.loads(raw.decode("utf-8", errors="replace"))
    except Exception as e:
        print(f"warn: {source_id}: phone_book fetch failed ({e})", file=sys.stderr)
        return [], []

    rig = rig_for(db_type, username)
    target = default_target_for(db_type, username)
    for brand in brands:
        bname = brand.get("name", "")
        suffix = brand.get("suffix")
        prefix = f"{bname} {suffix}" if suffix else bname
        for ph in brand.get("phones") or []:
            if isinstance(ph, str):
                model_name = ph
                file_base = f"{bname} {ph}"
            else:
                model_name = ph.get("name", "")
                f = ph.get("file")
                if isinstance(f, list):
                    file_base = f[0] if f else f"{bname} {model_name}"
                elif isinstance(f, str):
                    file_base = f
                else:
                    file_base = f"{bname} {model_name}"
            display = f"{prefix} {model_name}".strip()
            # Skip empty rows (some brands declare an entry with no model name,
            # producing a phantom empty-string headphone in the picker).
            if not display or not file_base.strip():
                continue
            raw_url = data_url + urllib.parse.quote(file_base, safe=" ()&,.+'")
            entries.append({
                "name": display,
                "measurer": source_id,
                "rawTxtURL": raw_url,
                "set": source_id,
                "rig": rig,
                "target": target,
            })

    targets = []
    try:
        cfg = fetch(cfg_url).decode("utf-8", errors="replace")
        targets = parse_targets(cfg)
    except Exception as e:
        print(f"info: {source_id}: config.js fetch failed ({e})", file=sys.stderr)
    return entries, targets


def main():
    sites = json.loads(SITES_FILE.read_text())
    jobs = []
    for site in sites:
        for source_id, db_type, data_url, cfg_url in expand_site(site):
            jobs.append((source_id, db_type, data_url, cfg_url, site["username"]))

    print(f"Fetching {len(jobs)} squig sources with {PARALLEL}-way parallelism...", file=sys.stderr)
    catalog = []
    targets_map = {}
    with ThreadPoolExecutor(max_workers=PARALLEL) as pool:
        futs = {pool.submit(fetch_one, *j): j for j in jobs}
        for fut in as_completed(futs):
            source_id, db_type, *_ = futs[fut]
            try:
                entries, targets = fut.result()
            except Exception as e:
                print(f"warn: {source_id}: unhandled {e}", file=sys.stderr)
                continue
            if entries:
                catalog.extend(entries)
            if targets:
                targets_map[source_id] = targets

    print(f"got {len(catalog)} entries from {len(targets_map)} sources with targets", file=sys.stderr)

    # De-dupe entries on (name, target, source) within squig set.
    seen = set()
    unique = []
    for e in catalog:
        key = (e["name"].lower(), (e.get("target") or "").lower(), e["measurer"])
        if key in seen:
            continue
        seen.add(key)
        unique.append(e)
    unique.sort(key=lambda e: (e["name"].lower(), e.get("target") or "", e["measurer"]))

    (RES / "squig_catalog.json").write_text(
        json.dumps(unique, indent=1, ensure_ascii=False) + "\n"
    )
    # Sort the targets dict by source id so git diffs after a refresh are
    # signal-only - ThreadPoolExecutor completion order varies per run.
    sorted_targets = {k: targets_map[k] for k in sorted(targets_map.keys())}
    (RES / "squig_targets.json").write_text(
        json.dumps(sorted_targets, indent=1, ensure_ascii=False) + "\n"
    )
    print(f"wrote {len(unique)} squig entries and {sum(len(v) for v in targets_map.values())} target names "
          f"across {len(targets_map)} sources",
          file=sys.stderr)


if __name__ == "__main__":
    main()
