# Load order & conflicts with a big modpack

With 1000+ mods, a handful of rules prevent most problems.

## Install order

1. **Frameworks** (`00-frameworks.json`) - RED4ext, Cyber Engine Tweaks, redscript, ArchiveXL, TweakXL, Codeware, then the other libraries.
2. **Fixes & performance**
3. **UI / HUD**
4. **Gameplay, combat, vehicles** - the script-heavy mods
5. **World, NPCs, quests**
6. **Graphics & lighting**
7. **Appearance, clothing, audio** - mostly archive-only, the safest
8. **Your personal tweaks** (`99-personal.json`) - last, so they win

`Install-Modpack.ps1` follows this order and always puts requirements before the mods that need them.

## How Cyberpunk decides who wins

| Mod type | Lives in | When two mods touch the same thing |
|---|---|---|
| `.archive` | `archive\pc\mod` | Archives load in **alphabetical order by file name, and the first one loaded wins** for a given in-game file. That's why some mods ship as `#name.archive` or `0-name.archive`: to load first. Vortex/MO2 can also write `archive\pc\mod\modlist.txt` to set an explicit order. |
| `.xl` (ArchiveXL) | `archive\pc\mod` | Additive: adds items/appearances instead of replacing, so these rarely conflict. |
| redscript `.reds` | `r6\scripts` | Two mods that `@replaceMethod` the same method conflict: the compile fails or one silently wins. `@wrapMethod` mods stack fine. |
| TweakXL `.yaml` / `.tweak` | `r6\tweaks` | Last loaded value wins for the same record/field. Files load alphabetically. |
| CET Lua | `bin\x64\plugins\cyber_engine_tweaks\mods\<name>` | Separate folders, so they rarely conflict at the file level. They can still fight over the same game system at runtime. |
| RED4ext plugins `.dll` | `red4ext\plugins\<name>` | Separate folders. Must be built for your game version. |
| REDmod | `mods\<name>` | Ordered by REDmod's load order (Vortex has a Load Order page for it). |

## What the manifest already handles

- **File conflicts:** the builder looked at every mod's file list. When two mods ship the same file path, it kept the more endorsed one and listed the other under "Left out" in `manifest/REPORT.md`.
- **Requirements:** every Nexus-listed requirement is in the pack and in `dependsOn`. `Find-MissingDependencies.ps1` checks they're installed.

## What it can't see (check these yourself)

- **Two mods replacing the same in-game asset from different archive names**, e.g. two different body mods, two V hair retextures, two weather or LUT overhauls. Both will "install fine" and one silently wins. In Vortex these don't show as conflicts either. If two mods describe themselves as replacing the same thing, keep one.
- **Gameplay overhauls that rebalance the same system**, e.g. two different police/wanted overhauls, two different driving-physics mods, two traffic density mods. Read the descriptions in each category file (`summary`) and pick one per system.
- **Mods whose page says "incompatible with X".** Nexus doesn't expose that through the API. When you find one, add `"conflictsWith": ["other-mod-id"]` to the entry; `Test-ModSetup.ps1` will flag both-installed from then on, and the builder keeps your `conflictsWith` when it regenerates.

## Vortex conflict prompts

When Vortex shows a lightning bolt (file conflict), the rule of thumb is: **the more specific mod loads after the general one.** E.g. a specific car retexture after a vehicle overhaul, a hotfix after the mod it fixes, your personal tweaks after everything.
