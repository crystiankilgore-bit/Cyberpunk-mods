# Installing the modpack on 2.5

This walks you from a clean game to the full pack. Budget an evening: downloading 1000+ mods takes a while, and you want to test in stages instead of installing everything at once.

## 0. Before you start

- **Game version 2.5**, Steam, GOG or Epic. Phantom Liberty is needed for mods marked "Needs DLC" in the manifest.
- **Vortex** (recommended: it handles Cyberpunk's install rules for you) or **Mod Organizer 2**.
- **~60 GB free** for downloads + installed mods, on top of the game.
- **PowerShell scripts allowed** for this repo. Run this once in PowerShell:
  ```powershell
  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
  ```
  If Windows still blocks a script because it came from the internet, run `Get-ChildItem -Recurse .\scripts | Unblock-File`.
- **Your Nexus API key** (nexusmods.com → Settings → API Keys → Personal API Key). Only `Install-Modpack.ps1 -Mode Download` needs it.

## 1. Start clean

If the game has been modded before, start from vanilla:

1. Back up your saves: `.\scripts\Backup-Game.ps1 -Label pre-modpack`
2. In Vortex: **Mods → Purge**. In MO2, just disable everything.
3. Delete the leftover mod folders in the game folder if they exist: `red4ext`, `r6\scripts`, `r6\tweaks`, `r6\cache\modded`, `archive\pc\mod`, `bin\x64\plugins`, `mods`, `bin\x64\version.dll`, `bin\x64\winmm.dll`, `bin\x64\global.ini`.
4. **Verify the game files** (Steam: Properties → Installed Files → Verify; GOG: Manage → Verify; Epic: Manage → Verify).
5. Launch the game once without mods, get to the main menu, quit.

## 2. Install in stages

Install one stage, launch, load a save, quit, run the checker, then do the next stage. When something breaks, you know which stage did it.

`Install-Modpack.ps1` always installs requirements first, even ones from other categories.

```powershell
$env:NEXUS_API_KEY = "<your key>"          # only for Download mode

# Stage 1: frameworks (RED4ext, CET, redscript, ArchiveXL, TweakXL, Codeware...)
.\scripts\Install-Modpack.ps1 -Category 00-frameworks.json
```

In Vortex: restart it, open **Mods**, filter **Never Installed**, select all, **Install**, then **Deploy**. Then:

```powershell
.\scripts\Test-ModSetup.ps1
```

Launch the game. Press the CET overlay key it asks you to bind on first launch. If you reach the main menu, stage 1 is good. Copy the `ProductVersion` the checker printed into `expectedExeVersion` in `manifest/modpack.json` so future patches get flagged.

Then the rest, one or two files at a time:

| Stage | Command |
|---|---|
| 2 | `.\scripts\Install-Modpack.ps1 -Category 10-fixes-performance.json, 20-ui-hud.json` |
| 3 | `.\scripts\Install-Modpack.ps1 -Category 30-gameplay.json` |
| 4 | `.\scripts\Install-Modpack.ps1 -Category 40-combat-weapons.json, 50-vehicles.json` |
| 5 | `.\scripts\Install-Modpack.ps1 -Category 60-world-npcs.json, 90-quests-content.json` |
| 6 | `.\scripts\Install-Modpack.ps1 -Category 70-graphics-lighting.json` |
| 7 | `.\scripts\Install-Modpack.ps1 -Category 80-appearance.json, 85-audio-radio.json` |

Want a smaller pack? Add `-MinPriority recommended` (only mods with 2,000+ endorsements, plus their requirements).

Test a few mods first with `-Limit 5`. Preview anything with `-WhatIf`.

### Download mode vs Vortex mode

| | `-Mode Download` (default) | `-Mode Vortex` |
|---|---|---|
| Needs | Nexus Premium + API key | Vortex set to handle Nexus links |
| How | Script downloads the exact files in the manifest into Vortex's downloads folder | Script opens `nxm://` links; Vortex downloads and installs each |
| Install step | You select all in Vortex and click Install | Vortex installs as it goes |
| Resume | Rerun, already-downloaded files are skipped | Rerun with `-SkipInstalled` |

If Vortex doesn't show the downloaded files after a restart, drag them from the downloads folder onto Vortex's **Downloads** tab.

### Mods with options

Some mods ask questions during install (FOMOD installers) or have several main files. The manifest marks those with "N main-file variants on Nexus - pick one". Vortex will pause on those; pick the option that matches your setup (e.g. your body mod, your resolution).

## 3. Launch options

- **REDmod mods** (anything that installs into `mods\`): launch with REDmod enabled. Steam: add `-modded` to the launch options. GOG Galaxy / Epic: enable REDmod in the launcher. Vortex runs the REDmod deploy for you when you deploy.
- Start the game from Steam/GOG/Epic or from Vortex. If you use MO2, **always launch through MO2**, because its files only exist while MO2 runs the game. That also means the `Test-ModSetup.ps1` checks only see MO2 mods while the game is running from MO2.

## 4. After every session where something goes wrong

```powershell
.\scripts\Get-ModLogs.ps1
```

It prints the errors from every framework log, names the mods it thinks are responsible, and zips everything into `logs\` for a bug report. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## 5. When the game patches

Patches almost always break RED4ext, CET and redscript for a few days.

1. **Before** updating (or right after, if Steam got there first): `.\scripts\Backup-Game.ps1 -Label before-patch`
2. Turn off auto-updates while you wait: Steam → game Properties → Updates → "Only update this game when I launch it".
3. When the frameworks update on Nexus, rebuild the manifest (`python tools\nexus\build_modpack.py`), update the frameworks in Vortex first, test, then everything else.
4. `Test-ModSetup.ps1` tells you when the game exe no longer matches `expectedExeVersion`.
