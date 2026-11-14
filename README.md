# Cyberpunk 2077 2.5 Modpack

A 1000+ mod Cyberpunk 2077 setup for **game version 2.5**, built from the Nexus Mods API, plus PowerShell tools to install it, check it, back it up and debug it.

The mods themselves aren't in this repo (Nexus terms and mod authors' permissions don't allow re-hosting). The repo holds the **list** of mods (which exact file, what each one needs) and scripts that download them from Nexus for you.

## Install with Vortex (easiest)

1. Install [Vortex](https://www.nexusmods.com/app), log in, and manage Cyberpunk 2077. Turn on Settings > Downloads > "Handle Nexus Links".
2. Download this repo (Code > Download ZIP, then extract) or `git clone` it.
3. Double-click **`Install with Vortex.bat`** and answer the questions.

It installs the pack in 8 stages, frameworks first. After each stage you install/deploy in Vortex and launch the game once, and the script checks everything before moving on. Close it anytime; running it again picks up at the next stage. With Nexus Premium + your API key it downloads the exact files straight into Vortex; without, it sends each mod to Vortex as a Nexus link.

## Quick start (PowerShell)

```powershell
git clone https://github.com/crystiankilgore-bit/Cyberpunk-mods
cd Cyberpunk-mods
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

.\scripts\Backup-Game.ps1 -Label pre-modpack          # 1. back up
$env:NEXUS_API_KEY = "<your Nexus personal API key>"  # 2. Premium: direct downloads
.\scripts\Install-Modpack.ps1 -Category 00-frameworks.json
#    ...install in Vortex, launch, then the next category (see the guide)
.\scripts\Test-ModSetup.ps1                           # 3. check
```

Read **[docs/INSTALL-GUIDE.md](docs/INSTALL-GUIDE.md)** before installing. It covers the staged install that keeps 1000+ mods debuggable.

## What's in here

| Path | What |
|---|---|
| `manifest/modpack.json` | Pack settings: target version, expected exe version, category files |
| `manifest/mods/*.json` | The mods, one file per category. Each entry has the Nexus id, the pinned main file, requirements (`dependsOn`), detect paths, and a 2.5 compatibility rating |
| `manifest/mods/99-personal.json` | **Yours.** Add mods by hand here; the builder never touches it |
| `DISABLE-THESE-MODS.txt` | Mods removed from the pack since you may have installed them: disable these in Vortex |
| `manifest/REPORT.md` | Build summary: counts, compatibility breakdown, and every mod left out and why |
| `tools/nexus/build_modpack.py` | Regenerates the manifest from Nexus (top-endorsed per category, requirements, conflicts) |
| `tools/nexus/modpack-config.json` | How many mods per category, compatibility cutoffs, exclusions |
| `docs/` | Install guide, load order & conflicts, troubleshooting |

### Scripts

| Script | Does |
|---|---|
| `Start-VortexInstall.ps1` | The guided installer behind `Install with Vortex.bat`: questions, backup, staged install, checks between stages, resume |
| `Install-Modpack.ps1` | Downloads every mod's pinned file via the API (Premium) into Vortex's downloads folder, or opens `nxm://` links for Vortex. Requirements first; resumable; `-Category`, `-MinPriority`, `-Limit`, `-WhatIf` |
| `Test-ModSetup.ps1` | Game version vs expected, required frameworks present and not stale, installed/missing counts, missing requirements, conflicts, stray archives |
| `Find-MissingDependencies.ps1` | Download list for anything installed mods need but you don't have |
| `Get-ModLogs.ps1` | Collects CET / RED4ext / redscript / ArchiveXL / TweakXL / Codeware logs, prints errors, names likely culprits, zips it all |
| `Backup-Game.ps1` / `Restore-Game.ps1` | Back up mod folders + saves + settings (not the whole 70 GB game); restore refuses across a game patch unless `-Force` |
| `Publish-Collection.ps1` | Builds a Vortex-format collection from the manifest and uploads it to Nexus as an **unpublished draft** (default name "Ai modpack"). Never publishes; you do that on Nexus. `-DryRun` builds it without uploading |
| `Test-Manifest.ps1` | Validates the manifest (ids, references, cycles). CI runs it on every push |

All scripts find the game automatically (Steam, GOG, Epic). If yours is somewhere unusual, pass `-GameDir "D:\Games\Cyberpunk 2077"` or set `$env:CP2077_DIR`.

## How the mods were picked

`build_modpack.py` asks the Nexus API for the most-endorsed mods in each category (quotas in `modpack-config.json`), then for each one:

- **Pins the newest main file** so everyone installs the same thing.
- **Rates 2.5 compatibility** from that file's upload date and what it contains:
  - `updated-for-2.5`: uploaded after the 2.5 patch.
  - `assets-likely-ok`: archive-only mod from before 2.5. Asset mods rarely break on patches.
  - `script-verify`: redscript/CET/TweakXL mod from patch 2.3 or later. Usually fine.
  - Skipped: DLL plugins not updated for 2.5, script mods from before 2.3, asset mods from before 2.1.
- **Pulls in every Nexus requirement**, recursively.
- **Drops file conflicts:** if two mods ship the same file, the more-endorsed one stays.
- **Records detect paths** from the real file list so the scripts can tell what's installed.

What it can't know: "incompatible with X" notes on mod pages, or two mods replacing the same in-game asset under different archive names. See [docs/LOAD-ORDER.md](docs/LOAD-ORDER.md).

### Rebuilding

```powershell
$env:NEXUS_API_KEY = "<key>"
python tools\nexus\build_modpack.py            # ~1 request/second, cached for 24h in .cache\
python tools\nexus\build_modpack.py --dry-run  # summary only
```

Rebuild after a game patch, once the frameworks have updated. Your own `notes`, `conflictsWith`, `detect`, `required` and `id` edits on existing entries are kept.

## Nexus API usage

The builder uses the GraphQL API (separate limits from the v1 API). It runs at about one request per second and backs off when Nexus asks it to. `Install-Modpack.ps1` uses about two v1 calls per mod against the 2,000/hour and 20,000/day limits, and pauses when it gets close. A full install takes more than one hour of quota, so the script pauses partway through and carries on by itself.
