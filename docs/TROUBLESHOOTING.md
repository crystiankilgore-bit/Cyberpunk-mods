# Troubleshooting

First step for any problem:

```powershell
.\scripts\Test-ModSetup.ps1        # what's installed / missing / conflicting
.\scripts\Get-ModLogs.ps1          # errors from every framework log + likely culprits
```

## The game won't start / crashes before the main menu

Usually a framework that doesn't match your game version.

1. Run `Test-ModSetup.ps1`. Fix every `[FAIL]` line.
2. Check RED4ext, Cyber Engine Tweaks, redscript, ArchiveXL, TweakXL and Codeware are the newest versions on Nexus. After a patch, wait for their updates before playing.
3. Look at `red4ext\logs\red4ext-*.log` (Get-ModLogs prints it). A plugin "incompatible with the game version" or "failed to load" is the one to remove or update.
4. Still crashing? Bisect: disable half the mods in Vortex (select → Disable → Deploy), test, and repeat on whichever half crashes. With 1000+ mods that's ~10 rounds to find one bad mod, faster than guessing.

## "redscript compilation failed" popup

The popup and `r6\logs\redscript_rCURRENT.log` name the script file. `Get-ModLogs.ps1` turns that into a mod folder name under "Likely culprits".

- `UNRESOLVED_REF` / "can't find type": a missing requirement (often Codeware or another library). Run `Find-MissingDependencies.ps1`.
- `Conflicting annotations` / two `@replaceMethod` for the same function: two mods fight over the same method. Keep one.
- Errors right after a patch: the mod needs an update. Disable it until it gets one.

If the game says scripts failed even after you removed the bad mod: delete `r6\cache\modded` (if present), then verify the game files. Don't delete `r6\cache\final.redscripts` by hand; verify restores it.

## CET overlay doesn't appear

- First launch: CET asks you to bind an overlay key. If you clicked past it, delete `bin\x64\plugins\cyber_engine_tweaks\bindings.json`.
- Check `bin\x64\plugins\cyber_engine_tweaks\cyber_engine_tweaks.log`. "Unsupported game version" = update CET.
- Make sure `bin\x64\version.dll` (CET's loader) is present: Vortex sometimes needs a redeploy.

## A mod's items / clothes don't show up

- ArchiveXL or TweakXL not installed or outdated: `Test-ModSetup.ps1` checks both.
- `.archive` files ended up in the wrong folder. The checker warns about stray archives outside `archive\pc\mod`.
- Archive names with non-ASCII characters: the checker warns. Rename them.

## Performance tanks

- Graphics mods (`70-graphics-lighting.json`) and high-res texture packs cost the most. Disable that category first to check.
- Crowd/traffic density mods hit the CPU hard. Look in `60-world-npcs.json`.
- With 1000+ archives the first load after install is slow while the game indexes them. That's normal.

## A save won't load / is "corrupted"

- Usually a mod that added items or quests got removed. Re-enable what you removed, load, then remove mods one at a time while in a safe spot.
- Restore saves from a backup: `.\scripts\Restore-Game.ps1 -IncludeSaves` (newest backup) or point `-Backup` at a specific one.

## Undo everything

```powershell
.\scripts\Restore-Game.ps1 -WhatIf      # see what it would do
.\scripts\Restore-Game.ps1              # newest backup
```

For a fully vanilla game: Vortex → Purge, delete the mod folders listed in [INSTALL-GUIDE.md](INSTALL-GUIDE.md) step 1, then verify files.

## Reporting a bug to a mod author

Run `Get-ModLogs.ps1`, attach the zip from `logs\`, include your game version (it's in `summary.txt`) and the mod's version (in the manifest under `mainFile`).
