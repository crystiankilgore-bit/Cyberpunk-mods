#Requires -Version 5.1
<#
.SYNOPSIS
    Lists installed mods whose requirements aren't installed, and conflicting mods installed together.

.DESCRIPTION
    Uses "dependsOn" / "conflictsWith" from the manifest and "detect" paths to see what's installed.
    Prints a deduplicated "go download these" list with Nexus links.

    -ManifestOnly skips the game folder entirely and just checks the manifest's ids line up.

.EXAMPLE
    .\scripts\Find-MissingDependencies.ps1
.EXAMPLE
    .\scripts\Find-MissingDependencies.ps1 -ManifestOnly
#>
[CmdletBinding()]
param(
    [string]$GameDir,
    [string]$ManifestDir,
    [switch]$ManifestOnly,
    # Treat mods with no detect paths as installed (stricter: their deps get checked too).
    [switch]$AssumeUnknownInstalled
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ModTools.psm1') -Force

try { $mods = (Import-Modpack -ManifestDir $ManifestDir).Mods } catch { Write-Fail $_.Exception.Message; exit 2 }

$state = $null
if (-not $ManifestOnly) {
    try { $game = Find-GameDir -GameDir $GameDir } catch { Write-Fail $_.Exception.Message; exit 2 }
    $state = Get-InstallState -Mods $mods -GameDir $game
}

$report = @(Get-DependencyReport -Mods $mods -State $state -AssumeUnknownInstalled:$AssumeUnknownInstalled)

Write-Section "Missing dependencies"
$missing = @($report | Where-Object Type -eq 'MissingDependency')
if ($missing.Count -eq 0) { Write-Ok "None." }
foreach ($g in ($missing | Group-Object { $_.Other.id })) {
    $dep = $g.Group[0].Other
    $needers = ($g.Group | ForEach-Object { $_.Mod.name }) -join ', '
    Write-Fail "$(Format-ModRef $dep)"
    Write-Host "         needed by: $needers" -ForegroundColor DarkGray
}

Write-Section "Conflicts (both installed)"
$conflicts = @($report | Where-Object Type -eq 'Conflict')
if ($conflicts.Count -eq 0) { Write-Ok "None." }
foreach ($c in $conflicts) { Write-Fail "$($c.Mod.name)  <->  $($c.Other.name)" }

Write-Section "Manifest references"
$unknown = @($report | Where-Object { $_.Type -in 'UnknownDependency', 'UnknownConflict' })
if ($unknown.Count -eq 0) { Write-Ok "All dependsOn / conflictsWith ids exist." }
foreach ($u in $unknown) {
    $kind = if ($u.Type -eq 'UnknownDependency') { 'dependsOn' } else { 'conflictsWith' }
    Write-Warn "$($u.Mod.id) ($($u.Mod.SourceFile)): $kind '$($u.Other)' isn't in the manifest. Add it or fix the id."
}

if ($state) {
    $unchecked = @($mods | Where-Object { $null -eq $state[$_.id] })
    if ($unchecked.Count -gt 0 -and -not $AssumeUnknownInstalled) {
        Write-Info "$($unchecked.Count) mod(s) have no detect paths and were skipped. Add detect paths, or rerun with -AssumeUnknownInstalled."
    }
}

Write-Host ""
exit ([int](($missing.Count + $conflicts.Count + $unknown.Count) -gt 0))
