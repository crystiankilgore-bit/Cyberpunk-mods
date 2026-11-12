#Requires -Version 5.1
<#
.SYNOPSIS
    Backs up everything mods touch, plus your saves and settings.

.DESCRIPTION
    Copies the mod-related folders (not the whole ~70 GB game) into a timestamped folder:

      archive/pc/mod                 .archive mods
      bin/x64/plugins                CET + its Lua mods
      bin/x64 loader files           version.dll, winmm.dll, global.ini, *.asi
      engine/config, engine/tools    redscript compiler + config
      r6                             scripts, tweaks, cache, config, logs
      red4ext                        RED4ext + all its plugins
      mods                           REDmod mods
      Saves                          %USERPROFILE%\Saved Games\CD Projekt Red\Cyberpunk 2077   (skip with -SkipSaves)
      Settings                       %LOCALAPPDATA%\CD Projekt Red\Cyberpunk 2077             (skip with -SkipSaves)

    A backup-info.json is written alongside so Restore-Game.ps1 knows which game version it came from.
    Use -Full to copy the entire game folder instead (needs ~70+ GB free).

.EXAMPLE
    .\scripts\Backup-Game.ps1
.EXAMPLE
    .\scripts\Backup-Game.ps1 -Destination "E:\CP2077-Backups" -Label "before-2.5-update"
#>
[CmdletBinding()]
param(
    [string]$GameDir,
    [string]$ManifestDir,
    [string]$Destination,
    [string]$Label,
    [switch]$SkipSaves,
    [switch]$Full,
    # How many old backups to keep in the destination (0 = keep all).
    [int]$Keep = 0
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ModTools.psm1') -Force

try { $game = Find-GameDir -GameDir $GameDir } catch { Write-Fail $_.Exception.Message; exit 2 }

if (-not $Destination) {
    try {
        $pack = (Import-Modpack -ManifestDir $ManifestDir).Pack
        $Destination = Get-Prop $pack 'backupDir' ''
    } catch { }
    if (-not $Destination) { $Destination = Join-Path (Split-Path -Parent $PSScriptRoot) 'backups' }
}

$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$name = if ($Label) { "${stamp}_$($Label -replace '[^\w\-\.]', '_')" } else { $stamp }
$target = Join-Path $Destination $name
New-Item -ItemType Directory -Path $target -Force | Out-Null

$hasRobocopy = [bool](Get-Command robocopy.exe -ErrorAction SilentlyContinue)

function Copy-Tree {
    param([string]$From, [string]$To)
    if (-not (Test-Path -LiteralPath $From)) { return $false }
    New-Item -ItemType Directory -Path $To -Force | Out-Null
    if ($hasRobocopy) {
        # /E all subdirs, /R:1 /W:1 don't hang on locked files, quiet output
        & robocopy.exe $From $To /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy failed copying $From (exit $LASTEXITCODE)" }
    } else {
        Copy-Item -Path (Join-Path $From '*') -Destination $To -Recurse -Force
    }
    return $true
}

$ver = Get-GameVersion -GameDir $game
Write-Section "Backing up to $target"
Write-Info "Game: $game  (exe $($ver.ProductVersion))"

$copied = New-Object System.Collections.Generic.List[string]

if ($Full) {
    Write-Info "Full backup: copying the whole game folder. This takes a while."
    Copy-Tree $game (Join-Path $target 'game') | Out-Null
    $copied.Add('game (full)')
} else {
    foreach ($rel in 'archive/pc/mod', 'bin/x64/plugins', 'engine/config', 'engine/tools', 'r6', 'red4ext', 'mods') {
        $from = Join-Path $game $rel
        if (Copy-Tree $from (Join-Path $target "game/$rel")) {
            Write-Ok $rel
            $copied.Add($rel)
        }
    }
    # Loader files that sit directly in bin/x64
    $binOut = Join-Path $target 'game/bin/x64'
    New-Item -ItemType Directory -Path $binOut -Force | Out-Null
    foreach ($pattern in 'version.dll', 'winmm.dll', 'global.ini', '*.asi', 'dxgi.dll', 'd3d11.dll', 'dinput8.dll') {
        foreach ($f in Get-ChildItem -Path (Join-Path $game "bin/x64/$pattern") -File -ErrorAction SilentlyContinue) {
            Copy-Item -LiteralPath $f.FullName -Destination $binOut -Force
            Write-Ok "bin/x64/$($f.Name)"
            $copied.Add("bin/x64/$($f.Name)")
        }
    }
}

if (-not $SkipSaves) {
    $saves = Join-Path $env:USERPROFILE 'Saved Games\CD Projekt Red\Cyberpunk 2077'
    $settings = Join-Path $env:LOCALAPPDATA 'CD Projekt Red\Cyberpunk 2077'
    if ($env:USERPROFILE -and (Copy-Tree $saves (Join-Path $target 'saves'))) { Write-Ok "Saves"; $copied.Add('saves') }
    else { Write-Warn "Save folder not found: $saves" }
    if ($env:LOCALAPPDATA -and (Copy-Tree $settings (Join-Path $target 'settings'))) { Write-Ok "Settings"; $copied.Add('settings') }
}

$info = [ordered]@{
    created        = (Get-Date).ToString('o')
    label          = $Label
    gameDir        = $game
    productVersion = $ver.ProductVersion
    fileVersion    = $ver.FileVersion
    full           = [bool]$Full
    contents       = $copied.ToArray()
}
$info | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $target 'backup-info.json') -Encoding UTF8

$size = (Get-ChildItem -LiteralPath $target -Recurse -File | Measure-Object -Property Length -Sum).Sum
Write-Section "Done"
Write-Ok ("Backup written: {0} ({1:N1} MB)" -f $target, ($size / 1MB))

if ($Keep -gt 0) {
    $old = @(Get-ChildItem -LiteralPath $Destination -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'backup-info.json') } |
        Sort-Object Name -Descending | Select-Object -Skip $Keep)
    foreach ($o in $old) {
        Remove-Item -LiteralPath $o.FullName -Recurse -Force
        Write-Info "Removed old backup $($o.Name)"
    }
}
