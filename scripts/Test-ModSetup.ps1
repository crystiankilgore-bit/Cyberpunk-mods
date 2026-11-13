#Requires -Version 5.1
<#
.SYNOPSIS
    Checks your Cyberpunk 2077 install against the modpack manifest.

.DESCRIPTION
    - Finds the game and prints its version (warns if a patch changed it)
    - Checks every required framework is installed
    - Warns if frameworks look older than the game exe (common after a patch)
    - Counts installed / missing mods from the manifest
    - Reports missing dependencies and conflicting mods that are both installed
    - Sanity-checks the mod folders

    Exit code: 0 = fine, 1 = problems found, 2 = couldn't run.

.EXAMPLE
    .\scripts\Test-ModSetup.ps1
.EXAMPLE
    .\scripts\Test-ModSetup.ps1 -GameDir "D:\SteamLibrary\steamapps\common\Cyberpunk 2077" -ShowMissing
#>
[CmdletBinding()]
param(
    [string]$GameDir,
    [string]$ManifestDir,
    # List every manifest mod that isn't installed (can be long).
    [switch]$ShowMissing
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ModTools.psm1') -Force

$failures = 0
$warnings = 0

try {
    $game = Find-GameDir -GameDir $GameDir
    $modpack = Import-Modpack -ManifestDir $ManifestDir
} catch {
    Write-Fail $_.Exception.Message
    exit 2
}

$pack = $modpack.Pack
$mods = $modpack.Mods

# ---------------------------------------------------------------- Game
Write-Section "Game"
$ver = Get-GameVersion -GameDir $game
Write-Info "Folder:  $game"
Write-Info "Exe ProductVersion: $($ver.ProductVersion)   FileVersion: $($ver.FileVersion)"
Write-Info "Exe last modified:  $($ver.LastWriteTime)"
Write-Info "Modpack targets game version $($pack.targetGameVersion)"

$expected = Get-Prop $pack 'expectedExeVersion' ''
if ([string]::IsNullOrWhiteSpace($expected)) {
    Write-Warn "manifest/modpack.json has no expectedExeVersion yet. Once the game runs fine, set it to '$($ver.ProductVersion)' so patches get flagged."
    $warnings++
} elseif ($expected -ne $ver.ProductVersion) {
    Write-Fail "Game exe is '$($ver.ProductVersion)' but the modpack expects '$expected'. The game was probably patched: update RED4ext, CET, redscript, ArchiveXL, TweakXL and Codeware before launching."
    $failures++
} else {
    Write-Ok "Game version matches the modpack."
}

# ---------------------------------------------------------------- Frameworks
Write-Section "Required frameworks"
$state = Get-InstallState -Mods $mods -GameDir $game
$vortexDirs = $null
$stuck = @{ staged = 0; downloaded = 0; nowhere = 0 }
$exeTime = $ver.LastWriteTime

foreach ($m in ($mods | Where-Object { (Get-Prop $_ 'required' $false) -eq $true })) {
    $installed = $state[$m.id]
    if ($installed -eq $true) {
        Write-Ok $m.name
        # Staleness heuristic: framework files older than the game exe
        $detect = Get-Prop $m 'detect'
        $paths = @(Get-Prop $detect 'paths' @()) + @(Get-Prop $detect 'anyOf' @())
        foreach ($p in $paths) {
            $item = Get-Item -Path (Join-Path $game $p) -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($item -and -not $item.PSIsContainer -and $item.LastWriteTime -lt $exeTime.AddDays(-1)) {
                Write-Warn "  $($m.name) ($p) is older than the game exe. If the game was patched recently, check Nexus for an update."
                $warnings++
                break
            }
        }
    } elseif ($installed -eq $false) {
        Write-Fail "$($m.name) is NOT in the game folder -> $(Format-ModRef $m)"
        $failures++
        if (-not $vortexDirs) { $vortexDirs = Get-VortexDirs -GameDir $game }
        $found = Find-ModInVortex -Mod $m -VortexDirs $vortexDirs
        if ($found -and $found.State -eq 'staged') {
            Write-Host "         Vortex HAS installed it but hasn't deployed it: Mods tab > make sure it's Enabled > Deploy." -ForegroundColor Yellow
            Write-Host "         ($($found.Where))" -ForegroundColor DarkGray
            $stuck['staged']++
        } elseif ($found) {
            Write-Host "         Downloaded but NOT installed in Vortex: Downloads tab > select it > Install, then Enable + Deploy." -ForegroundColor Yellow
            Write-Host "         ($($found.Where))" -ForegroundColor DarkGray
            $stuck['downloaded']++
        } else {
            $stuck['nowhere']++
        }
    } else {
        Write-Warn "$($m.name) has no 'detect' paths in the manifest, so it can't be checked."
        $warnings++
    }
}

# ---------------------------------------------------------------- Manifest coverage
Write-Section "Modpack coverage"
$on      = @($mods | Where-Object { $state[$_.id] -eq $true })
$off     = @($mods | Where-Object { $state[$_.id] -eq $false })
$unknown = @($mods | Where-Object { $null -eq $state[$_.id] })
Write-Info ("{0} mods in manifest: {1} installed, {2} missing, {3} can't be checked (no detect paths)" -f $mods.Count, $on.Count, $off.Count, $unknown.Count)

if ($off.Count -gt 0) {
    if ($ShowMissing) {
        foreach ($m in ($off | Sort-Object category, name)) { Write-Warn "missing: [$($m.category)] $(Format-ModRef $m)" }
    } else {
        Write-Info "Run with -ShowMissing to list them."
    }
}

# ---------------------------------------------------------------- Dependencies / conflicts
Write-Section "Dependencies & conflicts"
$report = Get-DependencyReport -Mods $mods -State $state
if ($report.Count -eq 0) {
    Write-Ok "No missing dependencies or active conflicts found."
}
foreach ($p in $report) {
    switch ($p.Type) {
        'MissingDependency' { Write-Fail "$($p.Mod.name) needs $(Format-ModRef $p.Other)"; $failures++ }
        'Conflict'          { Write-Fail "$($p.Mod.name) conflicts with $($p.Other.name) and both are installed. Remove one."; $failures++ }
        'UnknownDependency' { Write-Warn "$($p.Mod.name) lists dependency '$($p.Other)' which isn't in the manifest. Run Test-Manifest.ps1."; $warnings++ }
        'UnknownConflict'   { Write-Warn "$($p.Mod.name) lists conflict '$($p.Other)' which isn't in the manifest."; $warnings++ }
    }
}

# ---------------------------------------------------------------- Folder sanity
Write-Section "Mod folders"
function Count-Files([string]$rel, [string]$filter) {
    $full = Join-Path $game $rel
    if (-not (Test-Path -LiteralPath $full)) { return 0 }
    return @(Get-ChildItem -LiteralPath $full -Recurse -File -Filter $filter -ErrorAction SilentlyContinue).Count
}
Write-Info ("archive/pc/mod  : {0} .archive files" -f (Count-Files 'archive/pc/mod' '*.archive'))
Write-Info ("r6/scripts      : {0} .reds files" -f (Count-Files 'r6/scripts' '*.reds'))
Write-Info ("r6/tweaks       : {0} .yaml + {1} .tweak files" -f (Count-Files 'r6/tweaks' '*.yaml'), (Count-Files 'r6/tweaks' '*.tweak'))
Write-Info ("red4ext/plugins : {0} .dll files" -f (Count-Files 'red4ext/plugins' '*.dll'))
$cetMods = Join-Path $game 'bin/x64/plugins/cyber_engine_tweaks/mods'
if (Test-Path -LiteralPath $cetMods) {
    Write-Info ("CET mods        : {0} folders" -f @(Get-ChildItem -LiteralPath $cetMods -Directory).Count)
}
$redmodDir = Join-Path $game 'mods'
if (Test-Path -LiteralPath $redmodDir) {
    $redmods = @(Get-ChildItem -LiteralPath $redmodDir -Directory)
    Write-Info ("REDmod mods     : {0} folders (need the -modded launch option and a REDmod deploy)" -f $redmods.Count)
}

# Archives in the wrong place: loose in archive/pc or the game root.
$stray = @()
foreach ($rel in '.', 'archive', 'archive/pc', 'bin/x64') {
    $full = Join-Path $game $rel
    if (Test-Path -LiteralPath $full) {
        $stray += @(Get-ChildItem -LiteralPath $full -File -Filter *.archive -ErrorAction SilentlyContinue)
    }
}
foreach ($s in $stray) {
    Write-Warn "Stray archive outside archive/pc/mod (the game won't load it): $($s.FullName)"
    $warnings++
}

# Archives with spaces or odd characters can fail to load under some setups.
$modArchives = Join-Path $game 'archive/pc/mod'
if (Test-Path -LiteralPath $modArchives) {
    foreach ($a in Get-ChildItem -LiteralPath $modArchives -File -Filter *.archive) {
        if ($a.Name -match '[^\x20-\x7E]') {
            Write-Warn "Archive name has non-ASCII characters (rename it to be safe): $($a.Name)"
            $warnings++
        }
    }
}

# ---------------------------------------------------------------- Summary
Write-Section "Summary"
if ($failures -eq 0 -and $warnings -eq 0) {
    Write-Ok "Everything checks out."
} elseif ($failures -eq 0) {
    Write-Warn "$warnings warning(s), no failures."
} else {
    Write-Fail "$failures problem(s), $warnings warning(s). Fix the [FAIL] lines first."
}
if (($stuck.staged + $stuck.downloaded + $stuck.nowhere) -gt 0) {
    Write-Host ""
    Write-Host "  Required frameworks are missing from the game folder. Most likely fix:" -ForegroundColor Yellow
    if ($stuck.downloaded) { Write-Host "   - Vortex > Downloads: select the framework downloads > Install." }
    if ($stuck.staged -or $stuck.downloaded) { Write-Host "   - Vortex > Mods: select them > Enable, then click Deploy (top bar)." }
    if ($stuck.nowhere) {
        Write-Host "   - $($stuck.nowhere) weren't found in Vortex's usual folders either. Either they never downloaded"
        Write-Host "     (rerun the installer), or Vortex uses a custom staging/download folder (Settings > Mods / Downloads)."
    }
    Write-Host "   - Check Vortex manages THIS copy of the game: Games tab > Cyberpunk 2077 > the folder should be"
    Write-Host "     $game"
    if ((Join-Path $game 'bin/x64/plugins/cyber_engine_tweaks/mods') -and (Test-Path -LiteralPath (Join-Path $game 'bin/x64/plugins/cyber_engine_tweaks/mods'))) {
        Write-Host "   - Note: CET mod folders exist but CET itself doesn't. They may be left over from an older setup."
    }
}
Write-Host ""
exit ([int]($failures -gt 0))
