#!/usr/bin/env python3
"""
Build the modpack manifest (manifest/mods/*.json) from the Nexus Mods API.

    NEXUS_API_KEY=<your personal API key> python tools/nexus/build_modpack.py

What it does
  1. Pulls the most-endorsed Cyberpunk 2077 mods per Nexus category (quotas in modpack-config.json).
  2. Looks up each mod's newest MAIN file and that file's contents.
  3. Rates 2.5 compatibility from the file date and what kind of files it ships.
  4. Skips mods that are likely broken on 2.5, and drops the lower-endorsed mod when two mods
     ship the same file (a hard file conflict).
  5. Adds every Nexus requirement (recursively), even if outside the quotas.
  6. Writes detect paths from the real file list, so the PowerShell scripts can tell what's installed.

Only uses the Python standard library. Responses are cached in .cache/nexus for 24h (--refresh to bypass).
Your hand-written entries are kept: manifest/mods/99-personal.json is never touched, and entries in other
files keep their id / detect / notes / required / logFiles if their nexusId is picked again.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.request
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

API = "https://api.nexusmods.com"
GAME_ID = 3333
DOMAIN = "cyberpunk2077"
PAGE = 80  # the API's max page size
MOD_PAGE = 50  # mod queries with requirements hit the complexity limit above ~60

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
MANIFEST = REPO / "manifest"
MODS_DIR = MANIFEST / "mods"
CACHE = REPO / ".cache" / "nexus"
PERSONAL_FILE = "99-personal.json"

# Hand-maintained fields we never overwrite on existing entries.
KEEP_FIELDS = ("id", "required", "detect", "logFiles", "notes", "conflictsWith", "testedGameVersion")

# Files that don't count as a conflict when two mods both ship them.
IGNORE_BASENAMES = re.compile(
    r"(?i)^(readme|license|licence|changelog|credits|third_party_licenses|info)(\.[a-z]+)?$|\.(txt|md|pdf|png|jpe?g|webp|url|html?)$"
)

KNOWN_ROOTS = ("archive/", "bin/", "r6/", "red4ext/", "engine/", "mods/")


# --------------------------------------------------------------------------- HTTP

class Nexus:
    def __init__(self, key: str, refresh: bool, verbose: bool):
        self.key = key
        self.refresh = refresh
        self.verbose = verbose
        self.calls = 0
        self.cached = 0
        self.lock = threading.Lock()
        self.min_interval = 1.0  # seconds between live requests; Nexus' firewall bans bursts
        self._next_slot = 0.0
        CACHE.mkdir(parents=True, exist_ok=True)

    def _throttle(self):
        with self.lock:
            now = time.time()
            wait = self._next_slot - now
            self._next_slot = max(now, self._next_slot) + self.min_interval
        if wait > 0:
            time.sleep(wait)

    def _cache_path(self, kind: str, body: str) -> Path:
        return CACHE / f"{kind}-{hashlib.sha1(body.encode()).hexdigest()}.json"

    def _request(self, url: str, data: bytes | None) -> dict:
        headers = {
            "apikey": self.key,
            "Accept": "application/json",
            "Application-Name": "cp2077-modpack-builder",
            "Application-Version": "1.0.0",
            "User-Agent": "cp2077-modpack-builder/1.0.0",
        }
        if data is not None:
            headers["Content-Type"] = "application/json"
        delay = 5
        for attempt in range(8):
            self._throttle()
            req = urllib.request.Request(url, data=data, headers=headers)
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    with self.lock:
                        self.calls += 1
                    remaining = r.headers.get("X-Rl-Hourly-Remaining")
                    if remaining is not None and int(remaining) < 50:
                        print(f"  ! only {remaining} API calls left this hour, slowing down", file=sys.stderr)
                        time.sleep(10)
                    return json.loads(r.read().decode())
            except urllib.error.HTTPError as e:
                if e.code == 401:
                    sys.exit("Nexus rejected the API key (401). Check NEXUS_API_KEY.")
                if e.code == 429 and attempt < 7:
                    wait = int(e.headers.get("Retry-After") or 60) + 5
                    print(f"  ! rate limited by Nexus, waiting {wait}s", file=sys.stderr, flush=True)
                    with self.lock:
                        self._next_slot = max(self._next_slot, time.time() + wait)
                    continue
                if e.code in (500, 502, 503, 504) and attempt < 7:
                    time.sleep(delay)
                    delay *= 2
                    continue
                raise
            except (urllib.error.URLError, TimeoutError, ConnectionError, OSError):
                if attempt < 7:
                    time.sleep(delay)
                    delay *= 2
                    continue
                raise
        raise RuntimeError("unreachable")

    def gql(self, query: str, variables: dict | None = None) -> dict:
        body = json.dumps({"query": query, "variables": variables or {}}, sort_keys=True)
        cp = self._cache_path("gql", body)
        if not self.refresh and cp.exists() and time.time() - cp.stat().st_mtime < 86400:
            with self.lock:
                self.cached += 1
            return json.loads(cp.read_text())
        res = self._request(f"{API}/v2/graphql", body.encode())
        if res.get("errors"):
            raise RuntimeError(f"GraphQL error: {res['errors'][0].get('message')}")
        cp.write_text(json.dumps(res))
        return res


# --------------------------------------------------------------------------- Queries

MOD_FIELDS = """
  modId name summary version author endorsements downloads updatedAt createdAt adultContent status
  modCategory { name }
  modRequirements {
    nexusRequirements { nodes { modId modName gameId externalRequirement notes url } }
    dlcRequirements { gameExpansion { name } notes }
  }
"""

SEARCH_Q = f"""
query($cat: String!, $offset: Int!, $count: Int!) {{
  mods(
    filter: {{ gameId: [{{ value: "{GAME_ID}" }}], categoryName: [{{ value: $cat }}], adultContent: [{{ value: false }}] }}
    sort: [{{ endorsements: {{ direction: DESC }} }}]
    offset: $offset, count: $count
  ) {{ totalCount nodes {{ {MOD_FIELDS} }} }}
}}"""


def search_category(nx: Nexus, cat: str, want: int, min_endorse: int):
    """Yields mods in a Nexus category, most endorsed first, until `want` or endorsements < min."""
    offset = 0
    got = 0
    while got < want:
        res = nx.gql(SEARCH_Q, {"cat": cat, "offset": offset, "count": MOD_PAGE})["data"]["mods"]
        nodes = res["nodes"]
        if not nodes:
            return
        for n in nodes:
            if n["endorsements"] < min_endorse:
                return
            got += 1
            yield n
        offset += len(nodes)
        if offset >= res["totalCount"]:
            return


def fetch_mods_by_id(nx: Nexus, ids: list[int]) -> list[dict]:
    out = []
    for i in range(0, len(ids), 20):
        chunk = ids[i:i + 20]
        ors = ", ".join(f'{{ gameId: [{{ value: "{GAME_ID}" }}], modId: [{{ value: "{m}" }}] }}' for m in chunk)
        q = f"{{ mods(filter: {{ op: OR, filter: [{ors}] }}, count: {MOD_PAGE}) {{ nodes {{ {MOD_FIELDS} }} }} }}"
        out += nx.gql(q)["data"]["mods"]["nodes"]
    return out


def fetch_main_file(nx: Nexus, mod_id: int) -> dict | None:
    q = f'{{ modFiles(modId: "{mod_id}", gameId: "{GAME_ID}") {{ fileId name version category date primary }} }}'
    files = nx.gql(q)["data"]["modFiles"] or []
    mains = [f for f in files if f["category"] == "MAIN"]
    pool = mains or [f for f in files if f["category"] in ("UPDATE", "OPTIONAL", "MISCELLANEOUS")]
    if not pool:
        return None
    newest = max(pool, key=lambda f: f["date"])
    # "Variants" = other MAIN files uploaded around the same time (pick-one options on the mod page).
    variants = [f for f in mains if abs(f["date"] - newest["date"]) < 14 * 86400]
    return {
        "fileId": newest["fileId"],
        "name": newest["name"],
        "version": newest["version"],
        "uploaded": datetime.fromtimestamp(newest["date"], timezone.utc).strftime("%Y-%m-%d"),
        "variants": len(variants),
        "_ts": newest["date"],
    }


def fetch_file_contents(nx: Nexus, file_ids: list[int]) -> dict[int, list[str]]:
    """file id -> list of paths inside the file's archive."""
    out: dict[int, list[str]] = defaultdict(list)
    for i in range(0, len(file_ids), 10):
        chunk = file_ids[i:i + 10]
        ors = ", ".join(f"{{ gameId: [{{ value: {GAME_ID} }}], fileId: [{{ value: {f} }}] }}" for f in chunk)
        offset = 0
        while True:
            q = (f"{{ modFileContents(filter: {{ op: OR, filter: [{ors}] }}, sort: [{{ fileId: {{ direction: DESC }} }}], "
                 f"offset: {offset}, count: {PAGE}) {{ totalCount nodes {{ fileId filePath }} }} }}")
            res = nx.gql(q)["data"]["modFileContents"]
            for n in res["nodes"]:
                out[n["fileId"]].append(n["filePath"])
            offset += len(res["nodes"])
            # Cap per batch so a texture pack with 10k loose files doesn't eat the rate limit.
            if not res["nodes"] or offset >= res["totalCount"] or offset >= 800:
                break
    return out


# --------------------------------------------------------------------------- Analysis

def normalize(path: str) -> str | None:
    p = path.replace("\\", "/").lstrip("./")
    low = p.lower()
    best = None
    for root in KNOWN_ROOTS:
        if low.startswith(root):
            best = 0
            break
        idx = low.find("/" + root)
        if idx >= 0 and (best is None or idx + 1 < best):
            best = idx + 1
    if best is not None:
        return p[best:]
    if low.endswith((".archive", ".archive.xl", ".xl")):
        return "archive/pc/mod/" + p.split("/")[-1]
    return None


def classify(paths: list[str]) -> dict:
    kinds = set()
    for p in paths:
        low = p.lower()
        if low.startswith("red4ext/plugins/") and low.endswith(".dll"):
            kinds.add("red4ext-plugin")
        elif low.startswith("bin/x64/") and low.endswith((".asi", ".dll")) and "cyber_engine_tweaks/mods/" not in low:
            kinds.add("native")
        elif "cyber_engine_tweaks/mods/" in low and low.endswith(".lua"):
            kinds.add("cet")
        elif low.endswith(".reds"):
            kinds.add("redscript")
        elif low.startswith("r6/tweaks/"):
            kinds.add("tweak")
        elif low.endswith((".archive", ".xl")):
            kinds.add("archive")
        elif low.startswith("mods/"):
            kinds.add("redmod")
        elif low.startswith(("engine/config/", "r6/config/")):
            kinds.add("config")
    return {"kinds": sorted(kinds)}


def detect_paths(paths: list[str]) -> list[str]:
    ranked = []
    for p in paths:
        low = p.lower()
        if IGNORE_BASENAMES.search(p.split("/")[-1]):
            continue
        if low.startswith("red4ext/plugins/") and low.endswith(".dll"):
            ranked.append((0, p))
        elif low.startswith("archive/pc/mod/") and low.endswith(".archive"):
            ranked.append((1, p))
        elif low.endswith("/init.lua") and "cyber_engine_tweaks/mods/" in low:
            ranked.append((2, p))
        elif low.startswith("r6/scripts/") and low.endswith(".reds"):
            ranked.append((3, p))
        elif low.startswith("r6/tweaks/"):
            ranked.append((4, p))
        elif low.startswith("mods/") and low.endswith("/info.json"):
            ranked.append((5, p))
        elif low.startswith("archive/pc/mod/") and low.endswith(".xl"):
            ranked.append((6, p))
    ranked.sort()
    out = []
    for _, p in ranked:
        if p not in out:
            out.append(p)
        if len(out) == 3:
            break
    return out


def compat_of(main: dict | None, kinds: list[str], cfg: dict) -> str:
    if not main:
        return "unknown"
    day = main["uploaded"]
    if day >= cfg["patch25Date"]:
        return "updated-for-2.5"
    if set(kinds) & {"red4ext-plugin", "native"}:
        return "native-pre-2.5"
    if set(kinds) & {"redscript", "cet", "tweak", "redmod", "config"}:
        return "script-verify" if day >= cfg["scriptCutoff"] else "script-outdated"
    if kinds:
        return "assets-likely-ok" if day >= cfg["assetCutoff"] else "assets-outdated"
    # No game files we recognise: standalone tools, or a file Nexus hasn't indexed yet.
    if main["name"].lower().endswith((".exe", ".msi")):
        return "external-tool"
    return "unknown" if day >= cfg["scriptCutoff"] else "unknown-outdated"


def slug(name: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return (s[:48].rstrip("-") or "mod")


# --------------------------------------------------------------------------- Main

def load_existing() -> tuple[dict[int, dict], set[int], set[str]]:
    by_nexus: dict[int, dict] = {}
    personal_ids: set[int] = set()
    used_ids: set[str] = set()
    for f in sorted(MODS_DIR.glob("*.json")):
        data = json.loads(f.read_text(encoding="utf-8"))
        for m in data.get("mods", []):
            if f.name == PERSONAL_FILE:
                used_ids.add(m["id"])
                if m.get("nexusId"):
                    personal_ids.add(m["nexusId"])
            elif m.get("nexusId"):
                by_nexus[m["nexusId"]] = m
    return by_nexus, personal_ids, used_ids


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", default=str(HERE / "modpack-config.json"))
    ap.add_argument("--refresh", action="store_true", help="ignore the 24h response cache")
    ap.add_argument("--dry-run", action="store_true", help="print the summary, don't write files")
    ap.add_argument("--workers", type=int, default=2)
    ap.add_argument("--rate", type=float, default=1.0, help="max live API requests per second (default 1)")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    key = os.environ.get("NEXUS_API_KEY")
    if not key:
        sys.exit("Set NEXUS_API_KEY to your Nexus personal API key (nexusmods.com > Settings > API Keys).")

    cfg = json.loads(Path(args.config).read_text(encoding="utf-8"))
    nx = Nexus(key, args.refresh, args.verbose)
    nx.min_interval = 1.0 / max(args.rate, 0.1)
    excl_names = [re.compile(p) for p in cfg.get("excludeNamePatterns", [])]
    excl_ids = set(cfg.get("excludeModIds", []))
    existing, personal_ids, reserved_ids = load_existing()

    # ---- 1. candidates per category (with headroom for skips)
    print("Searching Nexus categories...")
    candidates: dict[int, dict] = {}
    cat_file: dict[str, str] = {}
    quota: dict[str, int] = {}
    for c in cfg["categories"]:
        cat_file[c["nexus"]] = c["file"]
        quota[c["nexus"]] = c["count"]
        want = int(c["count"] * 2.2) + 10
        n = 0
        for m in search_category(nx, c["nexus"], want, cfg["minEndorsements"]):
            if m["status"] != "published" or m["adultContent"]:
                continue
            if m["modId"] in excl_ids or m["modId"] in personal_ids:
                continue
            if any(rx.search(m["name"]) for rx in excl_names):
                continue
            candidates[m["modId"]] = m
            n += 1
        print(f"  {c['nexus']:<24} {n:>4} candidates")

    # ---- 2. requirement closure for candidates (resolved later for the final picks)
    def requirement_ids(m: dict) -> list[int]:
        out = []
        for r in m["modRequirements"]["nexusRequirements"]["nodes"]:
            if not r["externalRequirement"] and str(r["gameId"]) == str(GAME_ID):
                try:
                    out.append(int(r["modId"]))
                except (TypeError, ValueError):
                    pass
        return out

    # ---- 3. files + contents
    def enrich(mods: dict[int, dict]):
        todo = [mid for mid, m in mods.items() if "_main" not in m]
        if not todo:
            return
        print(f"Fetching main files for {len(todo)} mods...")
        with ThreadPoolExecutor(args.workers) as pool:
            for k, (mid, main) in enumerate(zip(todo, pool.map(lambda i: fetch_main_file(nx, i), todo)), 1):
                mods[mid]["_main"] = main
                if k % 200 == 0:
                    print(f"  {k}/{len(todo)}", flush=True)
        fids = [m["_main"]["fileId"] for m in (mods[i] for i in todo) if m["_main"]]
        print(f"Fetching file lists for {len(fids)} files...")
        contents: dict[int, list[str]] = {}
        chunks = [fids[i:i + 10] for i in range(0, len(fids), 10)]
        with ThreadPoolExecutor(args.workers) as pool:
            for part in pool.map(lambda ch: fetch_file_contents(nx, ch), chunks):
                contents.update(part)
        for mid in todo:
            m = mods[mid]
            raw = contents.get(m["_main"]["fileId"], []) if m["_main"] else []
            paths = sorted({p for p in (normalize(x) for x in raw) if p})
            m["_paths"] = paths
            m["_kinds"] = classify(paths)["kinds"]
            m["_compat"] = compat_of(m["_main"], m["_kinds"], cfg)

    enrich(candidates)

    # ---- 3b. fetch the whole requirement tree up front, so we can reject mods whose
    #          requirements are themselves outdated, adult-only or gone.
    pool = dict(candidates)
    unresolvable: set[int] = set()
    while True:
        need = {d for m in list(pool.values()) for d in requirement_ids(m)} - set(pool) - unresolvable
        if not need:
            break
        print(f"Resolving {len(need)} requirements...")
        for m in fetch_mods_by_id(nx, sorted(need)):
            if m["adultContent"] or m["status"] != "published":
                print(f"  ! requirement {m['name']} ({m['modId']}) is adult-only or not published - mods needing it are skipped")
                unresolvable.add(m["modId"])
            else:
                pool[m["modId"]] = m
        for d in need:
            if d not in pool and d not in unresolvable:
                print(f"  ! requirement {d} not found on Nexus (hidden or removed) - mods needing it are skipped")
                unresolvable.add(d)
        enrich({d: pool[d] for d in need if d in pool})

    # ---- 4. greedy selection, most endorsed first, with file-conflict checks
    skip_compat = {"script-outdated", "assets-outdated", "unknown-outdated", "external-tool"}
    if cfg.get("excludeOutdatedNative", True):
        skip_compat.add("native-pre-2.5")

    def bad_requirement(mid: int) -> int | None:
        for d in deps_closure_pool(mid):
            if d in unresolvable or (d in pool and pool[d]["_compat"] in skip_compat) or (d in pool and pool[d]["_main"] is None):
                return d
        return None

    def deps_closure_pool(mid: int) -> set[int]:
        seen, stack = set(), [mid]
        while stack:
            x = stack.pop()
            for d in (requirement_ids(pool[x]) if x in pool else []):
                if d not in seen and d != mid:
                    seen.add(d)
                    stack.append(d)
        return seen

    picked: dict[int, dict] = {}
    owner: dict[str, int] = {}  # normalized path (lowercase) -> mod id
    taken = defaultdict(int)
    skipped = defaultdict(list)

    def deps_closure(mid: int, pool: dict[int, dict]) -> set[int]:
        seen, stack = set(), [mid]
        while stack:
            x = stack.pop()
            for d in requirement_ids(pool[x]) if x in pool else []:
                if d not in seen:
                    seen.add(d)
                    stack.append(d)
        return seen

    def claim(mid: int, m: dict, pool: dict[int, dict]) -> int | None:
        """Returns the id of a conflicting mod, or None after claiming the mod's paths."""
        related = deps_closure(mid, pool)
        for p in m.get("_paths", []):
            if IGNORE_BASENAMES.search(p.split("/")[-1]):
                continue
            o = owner.get(p.lower())
            if o is not None and o != mid and o not in related and mid not in deps_closure(o, pool):
                return o
        for p in m.get("_paths", []):
            if not IGNORE_BASENAMES.search(p.split("/")[-1]):
                owner.setdefault(p.lower(), mid)
        return None

    # Frameworks first so their files are "owned" by them, then by endorsements.
    order = sorted(candidates.values(),
                   key=lambda m: (m["modCategory"]["name"] != "Modders Resources", -m["endorsements"]))
    for m in order:
        cat = m["modCategory"]["name"]
        if cat not in quota or taken[cat] >= quota[cat]:
            continue
        if m["_compat"] in skip_compat:
            skipped[m["_compat"]].append(m)
            continue
        if m["_main"] is None:
            skipped["no-main-file"].append(m)
            continue
        bad = bad_requirement(m["modId"])
        if bad is not None:
            m["_badreq"] = bad
            skipped["bad-requirement"].append(m)
            continue
        c = claim(m["modId"], m, pool)
        if c is not None:
            m["_conflict"] = c
            skipped["file-conflict"].append(m)
            continue
        picked[m["modId"]] = m
        taken[cat] += 1

    # ---- 5. requirements (recursive), regardless of quotas - all already vetted in step 3b
    added_deps: set[int] = set()
    for mid in list(picked):
        for d in deps_closure_pool(mid):
            if d not in picked and d in pool:
                claim(d, pool[d], pool)
                picked[d] = pool[d]
                added_deps.add(d)

    # ---- 6. write manifest
    file_of_cat = dict(cat_file)
    default_file = "30-gameplay.json"
    by_file: dict[str, list[dict]] = defaultdict(list)
    used_ids = set(reserved_ids)
    id_of: dict[int, str] = {}

    # Ids: keep existing ones, else slug, unique.
    for mid, m in sorted(picked.items(), key=lambda kv: -kv[1]["endorsements"]):
        old = existing.get(mid)
        if old:
            id_of[mid] = old["id"]
        else:
            s = slug(m["name"])
            if s in used_ids:
                s = f"{s}-{mid}"
            id_of[mid] = s
        used_ids.add(id_of[mid])

    required_by = defaultdict(int)
    for m in picked.values():
        for d in requirement_ids(m):
            required_by[d] += 1

    for mid, m in picked.items():
        old = existing.get(mid, {})
        main = m["_main"] or {}
        deps = [id_of[d] for d in requirement_ids(m) if d in id_of and d != mid]
        dlc = [r["gameExpansion"]["name"] for r in m["modRequirements"]["dlcRequirements"] if r.get("gameExpansion")]
        externals = [r["modName"] for r in m["modRequirements"]["nexusRequirements"]["nodes"] if r["externalRequirement"]]
        note_bits = []
        if m["_compat"] == "native-pre-2.5":
            note_bits.append("Native plugin not updated since 2.5 - check the mod page before launching.")
        elif m["_compat"] == "script-verify":
            note_bits.append("Script mod last updated before 2.5 - usually fine, verify in-game.")
        if main.get("variants", 0) > 1:
            note_bits.append(f"{main['variants']} main-file variants on Nexus - pick one.")
        if dlc:
            note_bits.append("Needs DLC: " + ", ".join(dlc) + ".")
        if externals:
            note_bits.append("Also needs (off Nexus): " + ", ".join(externals) + ".")
        if mid in added_deps and m["modCategory"]["name"] not in quota:
            note_bits.append("Added as a requirement.")
        if required_by[mid]:
            note_bits.append(f"Required by {required_by[mid]} mod(s) in this pack.")

        entry = {
            "id": id_of[mid],
            "name": m["name"].strip(),
            "nexusId": mid,
            "priority": "core" if (m["modCategory"]["name"] == "Modders Resources" and required_by[mid] >= 3) or old.get("priority") == "core"
                        else ("recommended" if m["endorsements"] >= 2000 else "optional"),
            "required": old.get("required", False),
            "dependsOn": deps,
            "author": m.get("author") or "",
            "endorsements": m["endorsements"],
            "nexusCategory": m["modCategory"]["name"],
            "compat": m["_compat"],
            "mainFile": {k: main[k] for k in ("fileId", "name", "version", "uploaded", "variants")} if main else None,
            "summary": (m.get("summary") or "").strip()[:300],
        }
        dp = detect_paths(m["_paths"])
        if dp:
            entry["detect"] = {"anyOf": dp}
        auto_notes = " ".join(note_bits)
        for k in KEEP_FIELDS:
            if k in old:
                entry[k] = old[k]
        if "notes" not in old and auto_notes:
            entry["notes"] = auto_notes
        elif auto_notes:
            entry["autoNotes"] = auto_notes
        if not entry["dependsOn"]:
            del entry["dependsOn"]

        f = file_of_cat.get(m["modCategory"]["name"])
        if not f:
            f = "00-frameworks.json" if m["modCategory"]["name"] in ("Modders Resources", "Utilities") else default_file
        by_file[f].append(entry)

    pack = json.loads((MANIFEST / "modpack.json").read_text(encoding="utf-8"))
    titles = {c["file"]: c["title"] for c in pack["categories"]}
    total = sum(len(v) for v in by_file.values())

    compat_count = defaultdict(int)
    for m in picked.values():
        compat_count[m["_compat"]] += 1

    print()
    print(f"Picked {total} mods ({len(added_deps)} pulled in as requirements). API calls: {nx.calls}, cache hits: {nx.cached}")
    for k, v in sorted(compat_count.items()):
        print(f"  {k:<18} {v}")
    for k, v in skipped.items():
        print(f"  skipped {k:<14} {len(v)}")
    if args.dry_run:
        return 0

    for fname in titles:
        if fname == PERSONAL_FILE:
            continue
        mods = sorted(by_file.get(fname, []), key=lambda e: (e["priority"] != "core", -e["endorsements"]))
        out = {"$schema": "../schema/mod-list.schema.json", "category": titles[fname], "mods": mods}
        (MODS_DIR / fname).write_text(json.dumps(out, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    write_report(picked, skipped, compat_count, by_file, titles, cfg, pool)
    print(f"Wrote manifest/mods/*.json and manifest/REPORT.md")
    return 0


def write_report(picked, skipped, compat_count, by_file, titles, cfg, pool):
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    lines = [
        "# Modpack build report",
        "",
        f"Generated {now} by `tools/nexus/build_modpack.py` from the Nexus Mods API.",
        "",
        f"**{len(picked)} mods** across {len([f for f in by_file if by_file[f]])} category files.",
        "",
        "## By category",
        "",
        "| File | Category | Mods |",
        "|---|---|---:|",
    ]
    for f, t in titles.items():
        if by_file.get(f):
            lines.append(f"| `{f}` | {t} | {len(by_file[f])} |")
    legend = {
        "updated-for-2.5": "Main file uploaded after patch 2.5. Most likely to work.",
        "assets-likely-ok": "Archive/asset-only mod from before 2.5. Asset mods rarely break on patches.",
        "script-verify": "redscript/CET/TweakXL mod from 2.3-2.4x. Usually fine; check if something misbehaves.",
        "native-pre-2.5": "DLL plugin not updated for 2.5 (only present because another mod needs it). Check its page.",
        "unknown": "Nexus has no file list for it (often a FOMOD installer or a brand-new upload). Recent, so kept; check the page.",
    }
    lines += ["", "## 2.5 compatibility", "", "| Rating | Mods | Meaning |", "|---|---:|---|"]
    for k, v in sorted(compat_count.items(), key=lambda kv: -kv[1]):
        lines.append(f"| `{k}` | {v} | {legend.get(k, '')} |")

    lines += ["", "## Left out", ""]
    why = {
        "file-conflict": "ships a file a more-endorsed mod already ships",
        "native-pre-2.5": "DLL plugin not updated since 2.5",
        "script-outdated": f"script mod not updated since {cfg['scriptCutoff']}",
        "assets-outdated": f"asset mod not updated since {cfg['assetCutoff']}",
        "no-main-file": "no downloadable main file",
        "bad-requirement": "needs a mod that's outdated, adult-only or removed",
        "unknown-outdated": f"no recognisable game files and not updated since {cfg['scriptCutoff']}",
        "external-tool": "standalone program, not a game mod",
    }
    for k, mods in skipped.items():
        lines.append(f"<details><summary><b>{len(mods)}</b> - {why.get(k, k)}</summary>")
        lines.append("")
        for m in sorted(mods, key=lambda m: -m["endorsements"])[:150]:
            extra = ""
            if k == "file-conflict" and m.get("_conflict") in pool:
                extra = f" (overlaps {pool[m['_conflict']]['name']})"
            if k == "bad-requirement":
                b = m.get("_badreq")
                extra = f" (needs {pool[b]['name']} - {pool[b]['_compat']})" if b in pool else f" (needs removed/adult mod {b})"
            lines.append(f"- [{m['name']}](https://www.nexusmods.com/{DOMAIN}/mods/{m['modId']}) - {m['endorsements']} endorsements{extra}")
        if len(mods) > 150:
            lines.append(f"- ... and {len(mods) - 150} more")
        lines += ["", "</details>", ""]
    (MANIFEST / "REPORT.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    sys.exit(main())
