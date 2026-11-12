#Requires -Version 5.1
<#
.SYNOPSIS
    Restores a backup made by Backup-Game.ps1.

.DESCRIPTION
    By default restores the newest backup. Mod folders (archive/pc/mod, bin/x64/plugins, red4ext,
    r6/scripts, r6/tweaks, mods) are replaced so they exactly match the backup - mods you added
    since the backup are removed from those folders. Other files are copied back over the top.

    If the game has been patched since the backup, the restore refuses unless you pass -Force,
    because old framework DLLs and r6/cache files can crash a newer game.

    Use -WhatIf to see what would happen without changing anything.

.EXAMPLE
    .\scripts\Restore-Game.ps1 -WhatIf
.EXAMPLE
    .\scripts\Restore-Game.ps1 -Backup ".\backups\2026-11-12_101500_before-2.5-update" -IncludeSaves
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$GameDir,
    [string]$ManifestDir,
    # A backup folder, or the folder that holds backups (newest one is used).
    [string]$Backup,
    [switch]$IncludeSaves,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ModTools.psm1') -Force

try { $game = Find-GameDir -GameDir $GameDir } catch { Write-Fail $_.Exception.Message; exit 2 }

if (-not $Backup) {
    $Backup = ''
    try { $Backup = Get-Prop (Import-Modpack -ManifestDir $ManifestDir).Pack 'backupDir' '' } catch { }
    if (-not $Backup) { $Backup = Join-Path (Split-Path -Parent $PSScriptRoot) 'backups' }
}
if (-not (Test-Path -LiteralPath $Backup)) { Write-Fail "Backup path not found: $Backup"; exit 2 }

if (-not (Test-Path -LiteralPath (Join-Path $Backup 'backup-info.json'))) {
    $latest = Get-ChildItem -LiteralPath $Backup -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'backup-info.json') } |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $latest) { Write-Fail "No backups found in $Backup"; exit 2 }
    $Backup = $latest.FullName
}

$info = Get-Content -LiteralPath (Join-Path $Backup 'backup-info.json') -Raw | ConvertFrom-Json
$ver = Get-GameVersion -GameDir $game

Write-Section "Restore"
Write-Info "Backup : $Backup"
Write-Info "Created: $($info.created)   game exe then: $($info.productVersion)"
Write-Info "Game   : $game   game exe now: $($ver.ProductVersion)"

if ($info.full) {
    Write-Fail "This is a -Full backup. Copy its 'game' folder back manually, or use Steam/GOG 'verify files' then restore a normal backup."
    exit 2
}

if ($info.productVersion -ne $ver.ProductVersion -and -not $Force) {
    Write-Fail "The game was patched since this backup. Restoring old frameworks/cache onto a newer game usually crashes it."
    Write-Info "Re-run with -Force if you're sure (e.g. you rolled the game back to the old version)."
    exit 1
}

$hasRobocopy = [bool](Get-Command robocopy.exe -ErrorAction SilentlyContinue)
$src = Join-Path $Backup 'game'

# Folders that are 100% mod content: mirror them (deletes extras).
$mirror = 'archive/pc/mod', 'bin/x64/plugins', 'red4ext', 'r6/scripts', 'r6/tweaks', 'mods'
# Folders that also contain vanilla files: copy over, never delete.
$overlay = 'engine/config', 'engine/tools', 'r6/config', 'r6/cache', 'bin/x64'

function Sync-Folder {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$From, [string]$To, [switch]$Mirror)
    if (-not (Test-Path -LiteralPath $From)) { return }
    if (-not $PSCmdlet.ShouldProcess($To, $(if ($Mirror) { 'Mirror from backup' } else { 'Copy from backup' }))) { return }
    New-Item -ItemType Directory -Path $To -Force | Out-Null
    if ($hasRobocopy) {
        $mode = if ($Mirror) { '/MIR' } else { '/E' }
        & robocopy.exe $From $To $mode /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy failed restoring $To (exit $LASTEXITCODE)" }
    } else {
        if ($Mirror -and (Test-Path -LiteralPath $To)) { Remove-Item -Path (Join-Path $To '*') -Recurse -Force }
        Copy-Item -Path (Join-Path $From '*') -Destination $To -Recurse -Force
    }
    Write-Ok ("{0} {1}" -f $(if ($Mirror) { 'mirrored' } else { 'restored' }), $To)
}

foreach ($rel in $mirror) {
    $from = Join-Path $src $rel
    if (Test-Path -LiteralPath $from) {
        Sync-Folder -From $from -To (Join-Path $game $rel) -Mirror
    } elseif (Test-Path -LiteralPath (Join-Path $game $rel)) {
        # Folder didn't exist at backup time -> mods added since; leave it but tell the user.
        Write-Warn "$rel wasn't in the backup but exists now. Left untouched; delete it yourself if you want a full rollback."
    }
}
foreach ($rel in $overlay) {
    Sync-Folder -From (Join-Path $src $rel) -To (Join-Path $game $rel)
}

if ($IncludeSaves) {
    Sync-Folder -From (Join-Path $Backup 'saves') -To (Join-Path $env:USERPROFILE 'Saved Games\CD Projekt Red\Cyberpunk 2077')
    Sync-Folder -From (Join-Path $Backup 'settings') -To (Join-Path $env:LOCALAPPDATA 'CD Projekt Red\Cyberpunk 2077')
}

Write-Section "Done"
Write-Info "If you use Vortex or MO2, tell it about the change (Vortex: Purge then Deploy) so it doesn't fight the restored files."
exit 0
