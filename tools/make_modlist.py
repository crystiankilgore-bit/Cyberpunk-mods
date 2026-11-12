#!/usr/bin/env python3
"""Write MODLIST.txt: every mod in the manifest, grouped by category, in plain text."""
import json
from datetime import date
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
MANIFEST = REPO / "manifest"
OUT = REPO / "MODLIST.txt"

RATING = {
    "updated-for-2.5": "2.5",
    "script-verify": "verify",
    "assets-likely-ok": "assets",
    "native-pre-2.5": "CHECK",
    "unknown": "?",
}


def main() -> None:
    pack = json.loads((MANIFEST / "modpack.json").read_text(encoding="utf-8"))
    groups = []
    for c in pack["categories"]:
        f = MANIFEST / "mods" / c["file"]
        if f.exists():
            mods = json.loads(f.read_text(encoding="utf-8"))["mods"]
            if mods:
                groups.append((c["title"], mods))

    names = {m["id"]: m["name"] for _, mods in groups for m in mods}
    total = sum(len(m) for _, m in groups)
    lines = [
        f"{pack['name']} - Cyberpunk 2077 {pack['targetGameVersion']} modpack",
        f"{total} mods. Generated {date.today().isoformat()} from manifest/.",
        "",
        "Rating (2.5 compatibility):",
        "  [2.5]     main file uploaded after patch 2.5",
        "  [verify]  script mod from patch 2.3-2.4x, usually fine",
        "  [assets]  textures/models only, rarely breaks on patches",
        "  [CHECK]   DLL plugin not updated for 2.5 (a requirement of another mod)",
        "  [?]       no file list on Nexus, check the mod page",
        "",
        "Contents:",
    ]
    for i, (title, mods) in enumerate(groups, 1):
        lines.append(f"  {i:>2}. {title} ({len(mods)})")

    for i, (title, mods) in enumerate(groups, 1):
        lines += ["", "=" * 78, f"{i}. {title.upper()} ({len(mods)} mods)", "=" * 78, ""]
        for n, m in enumerate(mods, 1):
            main = m.get("mainFile") or {}
            rating = RATING.get(m.get("compat", ""), "?")
            ver = f" v{main['version']}" if main.get("version") else ""
            author = f" by {m['author']}" if m.get("author") else ""
            lines.append(f"{n:>4}. {m['name']}{ver}{author}  [{rating}]")
            lines.append(f"      https://www.nexusmods.com/cyberpunk2077/mods/{m['nexusId']}")
            deps = [names.get(d, d) for d in m.get("dependsOn", [])]
            if deps:
                lines.append(f"      Requires: {', '.join(deps)}")
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Wrote {OUT.relative_to(REPO)}: {total} mods, {len(lines)} lines")


if __name__ == "__main__":
    main()
