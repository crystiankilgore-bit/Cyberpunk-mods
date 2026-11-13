#Requires -Version 5.1
<#
.SYNOPSIS
    Collects the CET, RED4ext, redscript, ArchiveXL, TweakXL and Codeware logs after a crash and shows the errors.

.DESCRIPTION
    - Gathers every known log file (plus any listed under "logFiles" in the manifest)
    - Scans them for errors and prints them grouped by log
    - Points at the mod a redscript compile error came from, where it can tell
    - Saves everything into a zip in ./logs you can attach to a Nexus bug report or Discord post

    Run it right after the crash: logs older than the last game launch are marked [old].

.EXAMPLE
    .\scripts\Get-ModLogs.ps1
.EXAMPLE
    .\scripts\Get-ModLogs.ps1 -MaxPerLog 50 -NoZip
#>
[CmdletBinding()]
param(
    [string]$GameDir,
    [string]$ManifestDir,
    [string]$OutDir,
    # Max error lines to print per log file.
    [int]$MaxPerLog = 15,
    [switch]$NoZip
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ModTools.psm1') -Force

try { $game = Find-GameDir -GameDir $GameDir } catch { Write-Fail $_.Exception.Message; exit 2 }

# Log locations, relative to the game folder.
$known = [ordered]@{
    'redscript'          = @('r6/logs/redscript*.log')
    'RED4ext'            = @('red4ext/logs/*.log')
    'RED4ext plugins'    = @('red4ext/plugins/*/*.log', 'red4ext/plugins/*/logs/*.log')
    'Cyber Engine Tweaks'= @('bin/x64/plugins/cyber_engine_tweaks/*.log')
    'CET mods'           = @('bin/x64/plugins/cyber_engine_tweaks/mods/*/*.log')
    'Game / REDmod'      = @('r6/logs/*.log', 'tools/redmod/bin/*.log', 'tools/redmod/bin/*.txt', 'tools/redmod/*.log', 'r6/cache/modded/*.log')
}

$files = New-Object System.Collections.Generic.List[object]
$seen = @{}
function Add-Log([string]$group, [string]$pattern, [string]$base) {
    foreach ($f in Get-ChildItem -Path (Join-Path $base $pattern) -File -ErrorAction SilentlyContinue) {
        if ($seen.ContainsKey($f.FullName)) { continue }
        $seen[$f.FullName] = $true
        $files.Add([pscustomobject]@{ Group = $group; File = $f })
    }
}

foreach ($g in $known.Keys) { foreach ($p in $known[$g]) { Add-Log $g $p $game } }

# Extra logs declared in the manifest.
try {
    foreach ($m in (Import-Modpack -ManifestDir $ManifestDir).Mods) {
        foreach ($p in @(Get-Prop $m 'logFiles' @())) { Add-Log $m.name $p $game }
    }
} catch { Write-Warn "Couldn't read manifest: $($_.Exception.Message)" }

# Engine crash reports (outside the game folder).
if ($env:LOCALAPPDATA) {
    $crashRoot = Join-Path $env:LOCALAPPDATA 'REDEngine\ReportQueue'
    if (Test-Path -LiteralPath $crashRoot) {
        $latestCrash = Get-ChildItem -LiteralPath $crashRoot -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latestCrash) {
            foreach ($f in Get-ChildItem -LiteralPath $latestCrash.FullName -File -ErrorAction SilentlyContinue) {
                if ($f.Extension -in '.txt', '.log', '.json', '.xml') { $files.Add([pscustomobject]@{ Group = 'Crash report'; File = $f }) }
            }
        }
    }
}

if ($files.Count -eq 0) {
    Write-Warn "No log files found. Launch the game at least once with mods installed."
    exit 1
}

# Anything written before the most recent RED4ext/CET log is probably from an older session.
$sessionStart = ($files | Where-Object { $_.Group -in 'RED4ext', 'Cyber Engine Tweaks' } |
    ForEach-Object { $_.File.LastWriteTime } | Sort-Object -Descending | Select-Object -First 1)
if ($sessionStart) { $sessionStart = $sessionStart.AddMinutes(-30) }

$errorPattern = '(?i)\b(error|fatal|exception|crash(ed)?|failed|failure|cannot|can''t|unable to|not found|missing|incompatible|mismatch)\b'
$ignorePattern = '(?i)(0 errors?|no errors|errors?: 0|without errors)'
# Lines a logger explicitly marked as info/debug/trace are never errors, whatever words they contain.
$infoLevelPattern = '(?i)^\s*(\[[^\]]*\]\s*)*\[\s*(info|debug|trace|verbose)\s*[\]-]|^\s*\[(INFO|DEBUG|TRACE)\b'
# Lines a logger explicitly marked as a problem.
$errorLevelPattern = '(?i)\[\s*(error|err|critical|fatal)\s*[\]-]|^\s*\[(ERROR|FATAL)\b'
# redscript lists every file it compiles; a path line is never an error, even if a file is called "Missing...".
$pathLinePattern = '(?i)^\s*([a-z]:\\|[^\[]).*\.(reds|lua|archive|xl|yaml|tweak)\s*$'

$summary = New-Object System.Collections.Generic.List[string]
$totalErrors = 0
$suspects = @{}

Write-Section "Logs found: $($files.Count)"
foreach ($group in ($files | Group-Object Group)) {
    foreach ($entry in $group.Group) {
        $f = $entry.File
        $rel = $f.FullName
        if ($rel.StartsWith($game, [StringComparison]::OrdinalIgnoreCase)) { $rel = $rel.Substring($game.Length).TrimStart('\', '/') }
        $old = ($sessionStart -and $f.LastWriteTime -lt $sessionStart)
        $tag = if ($old) { ' [old]' } else { '' }

        $lines = @(Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue)
        $hits = @()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $l = $lines[$i]
            if ($l -match $infoLevelPattern -or $l -match $pathLinePattern) { continue }
            if ($l -match $errorLevelPattern -or ($l -match $errorPattern -and $l -notmatch $ignorePattern -and $l -notmatch '(?i)\[\s*(warn|warning)\s*\]')) {
                $hits += [pscustomobject]@{ N = $i + 1; Text = $l.Trim() }
            }
        }

        $header = "[$($entry.Group)] $rel$tag - $($hits.Count) error line(s), modified $($f.LastWriteTime)"
        $summary.Add($header)
        if ($hits.Count -eq 0) { Write-Ok $header; continue }

        if ($old) { Write-Info $header } else { Write-Fail $header; $totalErrors += $hits.Count }
        foreach ($h in ($hits | Select-Object -First $MaxPerLog)) {
            $line = "      line $($h.N): $($h.Text)"
            Write-Host $line -ForegroundColor DarkGray
            $summary.Add($line)

            # Guess the culprit: redscript errors include the script path, CET/plugin errors the folder.
            foreach ($rx in 'r6[\\/]scripts[\\/]([^\\/:]+)', 'cyber_engine_tweaks[\\/]mods[\\/]([^\\/:]+)', 'red4ext[\\/]plugins[\\/]([^\\/:]+)', 'archive[\\/]pc[\\/]mod[\\/]([^\\/:]+\.archive)') {
                if (-not $old -and $h.Text -match $rx) { $suspects[$Matches[1]] = 1 + [int]$suspects[$Matches[1]] }
            }
        }
        if ($hits.Count -gt $MaxPerLog) { Write-Host "      ... $($hits.Count - $MaxPerLog) more (see the zip)" -ForegroundColor DarkGray }
    }
}

Write-Section "Likely culprits"
if ($suspects.Count -eq 0) {
    Write-Info "No mod named directly in the errors. Check the [FAIL] logs above, newest first."
} else {
    foreach ($s in ($suspects.GetEnumerator() | Sort-Object Value -Descending)) {
        Write-Warn ("{0}  ({1} error line(s))" -f $s.Key, $s.Value)
        $summary.Add("SUSPECT: $($s.Key) ($($s.Value))")
    }
    Write-Info "Disable the top one, relaunch, and run this again. See docs/TROUBLESHOOTING.md."
}

# ---------------------------------------------------------------- Save bundle
if (-not $OutDir) { $OutDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'logs' }
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$bundle = Join-Path $OutDir "modlogs_$stamp"
New-Item -ItemType Directory -Path $bundle -Force | Out-Null

foreach ($entry in $files) {
    $safe = ($entry.Group -replace '[^\w\-]', '_')
    $dest = Join-Path $bundle $safe
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Copy-Item -LiteralPath $entry.File.FullName -Destination (Join-Path $dest $entry.File.Name) -Force -ErrorAction SilentlyContinue
}
$ver = Get-GameVersion -GameDir $game
@("Game exe: $($ver.ProductVersion)  ($game)", "Collected: $(Get-Date -Format o)", "") + $summary |
    Set-Content -LiteralPath (Join-Path $bundle 'summary.txt') -Encoding UTF8

Write-Section "Saved"
if ($NoZip) {
    Write-Ok "Logs copied to $bundle"
} else {
    $zip = "$bundle.zip"
    Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath $zip -Force
    Remove-Item -LiteralPath $bundle -Recurse -Force
    Write-Ok "Logs zipped to $zip"
}
exit ([int]($totalErrors -gt 0))
