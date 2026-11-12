#Requires -Version 5.1
<#
.SYNOPSIS
    Downloads every mod in the manifest from Nexus (Premium) and hands them to Vortex in the right order.

.DESCRIPTION
    Two modes:

    -Mode Download (default)
        Uses the Nexus API to download each mod's main file (the exact file the manifest lists) into
        Vortex's download folder. Frameworks and requirements come first. Needs a Premium account
        (the API only gives direct download links to Premium users) and your API key in
        $env:NEXUS_API_KEY or -ApiKey. Resumable: rerun it and it skips what's already downloaded.
        When it's done, restart Vortex: it picks the new archives up under Downloads, then select all
        and Install. Or point -DownloadDir anywhere and drag the files into Vortex/MO2.

    -Mode Vortex
        Opens nxm:// links one by one so Vortex downloads and installs each mod itself, in batches.
        No API key needed in the script. Vortex must be set as the handler for nxm links
        (Vortex > Settings > Downloads > "Handle Nexus links").

    Respects the API's hourly limit: if it gets low, the script waits for the reset.

.EXAMPLE
    $env:NEXUS_API_KEY = "<your key>"; .\scripts\Install-Modpack.ps1
.EXAMPLE
    .\scripts\Install-Modpack.ps1 -Category 00-frameworks.json, 10-fixes-performance.json
.EXAMPLE
    .\scripts\Install-Modpack.ps1 -Mode Vortex -BatchSize 10 -BatchDelaySeconds 60
.EXAMPLE
    .\scripts\Install-Modpack.ps1 -WhatIf      # just show the plan
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Download', 'Vortex')]
    [string]$Mode = 'Download',
    [string]$ManifestDir,
    [string]$GameDir,
    [string]$ApiKey = $env:NEXUS_API_KEY,
    [string]$DownloadDir,
    # Only these category files (e.g. 00-frameworks.json). Requirements from other files are still included.
    [string[]]$Category,
    # Only mods at or above this priority (core < recommended < optional). Requirements still included.
    [ValidateSet('core', 'recommended', 'optional')]
    [string]$MinPriority = 'optional',
    # Skip mods that the detect paths say are already installed (needs the game folder).
    [switch]$SkipInstalled,
    # Ask Nexus for the newest main file instead of the one pinned in the manifest.
    [switch]$Latest,
    [int]$BatchSize = 8,
    [int]$BatchDelaySeconds = 45,
    # Stop after this many mods (0 = all). Handy for a first test run.
    [int]$Limit = 0
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ModTools.psm1') -Force
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Domain = 'cyberpunk2077'
$Api = 'https://api.nexusmods.com/v1'

$mp = Import-Modpack -ManifestDir $ManifestDir
$mods = @($mp.Mods | Where-Object { Get-Prop $_ 'nexusId' })
$byId = @{}
foreach ($m in $mods) { $byId[$m.id] = $m }

# ---------------------------------------------------------------- Selection
$rank = @{ core = 0; recommended = 1; optional = 2 }
$maxRank = $rank[$MinPriority]
$wanted = @($mods | Where-Object {
    (-not $Category -or $Category -contains $_.SourceFile) -and
    ($rank[(Get-Prop $_ 'priority' 'optional')] -le $maxRank)
})

# Add requirements recursively, then order so every mod comes after what it needs.
$selected = @{}
$stack = New-Object System.Collections.Stack
foreach ($m in $wanted) { $stack.Push($m.id) }
while ($stack.Count -gt 0) {
    $id = $stack.Pop()
    if ($selected.ContainsKey($id) -or -not $byId.ContainsKey($id)) { continue }
    $selected[$id] = $true
    foreach ($d in @(Get-Prop $byId[$id] 'dependsOn' @())) { $stack.Push($d) }
}

$fileOrder = @{}
$i = 0
foreach ($c in $mp.Pack.categories) { $fileOrder[$c.file] = $i++ }

$ordered = New-Object System.Collections.Generic.List[object]
$state = @{}  # 1 = visiting, 2 = done
function Add-Ordered([string]$id) {
    if ($state[$id] -eq 2 -or -not $selected.ContainsKey($id)) { return }
    if ($state[$id] -eq 1) { return }  # cycle; Test-Manifest reports these
    $state[$id] = 1
    foreach ($d in @(Get-Prop $byId[$id] 'dependsOn' @())) { Add-Ordered $d }
    $state[$id] = 2
    $ordered.Add($byId[$id])
}
$seed = $selected.Keys | ForEach-Object { $byId[$_] } |
    Sort-Object @{ e = { $fileOrder[$_.SourceFile] } }, @{ e = { -[int](Get-Prop $_ 'endorsements' 0) } }
foreach ($m in $seed) { Add-Ordered $m.id }

if ($SkipInstalled) {
    $game = Find-GameDir -GameDir $GameDir
    $inst = Get-InstallState -Mods $ordered -GameDir $game
    $before = $ordered.Count
    $ordered = [System.Collections.Generic.List[object]]@($ordered | Where-Object { $inst[$_.id] -ne $true })
    Write-Info "$($before - $ordered.Count) already installed, skipping them."
}
if ($Limit -gt 0 -and $ordered.Count -gt $Limit) {
    $ordered = [System.Collections.Generic.List[object]]@($ordered | Select-Object -First $Limit)
}

Write-Section "Plan: $($ordered.Count) mods ($Mode mode)"
$ordered | Group-Object SourceFile | Sort-Object { $fileOrder[$_.Name] } | ForEach-Object {
    Write-Info ("{0,5}  {1}" -f $_.Count, $_.Name)
}
$risky = @($ordered | Where-Object { (Get-Prop $_ 'compat') -eq 'native-pre-2.5' })
if ($risky.Count) { Write-Warn "$($risky.Count) DLL plugin(s) haven't been updated for 2.5 (they're requirements of other mods). See manifest/REPORT.md." }

if ($WhatIfPreference) {
    foreach ($m in $ordered) { Write-Host ("  {0,-26} {1}" -f $m.SourceFile, (Format-ModRef $m)) }
    return
}

# ---------------------------------------------------------------- API helpers
$script:hourlyLeft = 9999
function Invoke-Nexus([string]$Path) {
    for ($try = 0; $try -lt 5; $try++) {
        if ($script:hourlyLeft -lt 15) {
            Write-Warn "Nexus hourly API limit nearly used up; waiting 10 minutes..."
            Start-Sleep -Seconds 600
            $script:hourlyLeft = 9999
        }
        try {
            $r = Invoke-WebRequest -Uri "$Api/$Path" -UseBasicParsing -Headers @{
                apikey = $ApiKey; 'Application-Name' = 'cp2077-modpack-installer'; 'Application-Version' = '1.0.0'
            }
            $left = $r.Headers['X-Rl-Hourly-Remaining']
            if ($left) { $script:hourlyLeft = [int](@($left)[0]) }
            return ($r.Content | ConvertFrom-Json)
        } catch {
            $code = 0
            try { $code = [int]$_.Exception.Response.StatusCode } catch { }
            if ($code -eq 401) { throw "Nexus rejected the API key (401). Check `$env:NEXUS_API_KEY." }
            if ($code -eq 403) { throw "Nexus refused the download link (403). Direct API downloads need a Premium account; use -Mode Vortex instead." }
            if ($code -eq 404) { return $null }
            if ($code -eq 429) { Write-Warn "Rate limited; waiting 2 minutes..."; Start-Sleep -Seconds 120; continue }
            if ($try -lt 4) { Start-Sleep -Seconds (5 * ($try + 1)); continue }
            throw
        }
    }
}

function Get-FileId($m) {
    $main = Get-Prop $m 'mainFile'
    if (-not $Latest -and $main -and (Get-Prop $main 'fileId')) { return [int]$main.fileId }
    $files = Invoke-Nexus "games/$Domain/mods/$($m.nexusId)/files.json"
    if (-not $files) { return $null }
    $f = @($files.files | Where-Object category_name -eq 'MAIN' | Sort-Object uploaded_timestamp -Descending | Select-Object -First 1)
    if ($f) { return [int]$f[0].file_id }
    return $null
}

# ---------------------------------------------------------------- Vortex mode
if ($Mode -eq 'Vortex') {
    $n = 0
    foreach ($m in $ordered) {
        $fid = Get-FileId $m
        $url = if ($fid) { "nxm://$Domain/mods/$($m.nexusId)/files/$fid" } else { "https://www.nexusmods.com/$Domain/mods/$($m.nexusId)?tab=files" }
        Write-Info ("[{0}/{1}] {2}" -f (++$n), $ordered.Count, $m.name)
        Start-Process $url
        Start-Sleep -Milliseconds 800
        if ($n % $BatchSize -eq 0 -and $n -lt $ordered.Count) {
            Write-Info "Batch done; waiting $BatchDelaySeconds s so Vortex can keep up (Ctrl+C to stop, rerun with -SkipInstalled to resume)."
            Start-Sleep -Seconds $BatchDelaySeconds
        }
    }
    Write-Section "Done"
    Write-Info "When Vortex finishes, run .\scripts\Test-ModSetup.ps1."
    return
}

# ---------------------------------------------------------------- Download mode
if (-not $ApiKey) { Write-Fail "Set `$env:NEXUS_API_KEY (nexusmods.com > Settings > API Keys) or pass -ApiKey."; exit 2 }

$me = Invoke-Nexus 'users/validate.json'
if (-not $me.is_premium) {
    Write-Fail "This account isn't Premium, so the API won't hand out download links. Use -Mode Vortex instead."
    exit 2
}

if (-not $DownloadDir) {
    $DownloadDir = Join-Path $env:APPDATA "Vortex\downloads\$Domain"
}
New-Item -ItemType Directory -Path $DownloadDir -Force | Out-Null
Write-Info "Downloading to $DownloadDir"

$progressFile = Join-Path $DownloadDir '.modpack-progress.json'
$done = @{}
if (Test-Path -LiteralPath $progressFile) {
    (Get-Content -LiteralPath $progressFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $done[$_.Name] = $_.Value }
}
function Save-Progress { $done | ConvertTo-Json | Set-Content -LiteralPath $progressFile -Encoding UTF8 }

$failed = New-Object System.Collections.Generic.List[string]
$n = 0
$ProgressPreference = 'SilentlyContinue'  # Invoke-WebRequest is ~10x slower with the progress bar
foreach ($m in $ordered) {
    $n++
    $key = "$($m.nexusId)"
    if ($done.ContainsKey($key) -and (Test-Path -LiteralPath (Join-Path $DownloadDir $done[$key]))) {
        Write-Host ("  [{0}/{1}] already have {2}" -f $n, $ordered.Count, $m.name) -ForegroundColor DarkGray
        continue
    }
    try {
        $fid = Get-FileId $m
        if (-not $fid) { throw "no main file" }
        $links = Invoke-Nexus "games/$Domain/mods/$($m.nexusId)/files/$fid/download_link.json"
        if (-not $links) {
            # Pinned file was removed or archived; try the newest one.
            $fid = $null; $savedLatest = $Latest; $Latest = $true
            $fid = Get-FileId $m; $Latest = $savedLatest
            if ($fid) { $links = Invoke-Nexus "games/$Domain/mods/$($m.nexusId)/files/$fid/download_link.json" }
        }
        if (-not $links) { throw "no download link" }
        $uri = [Uri]@($links)[0].URI
        $fileName = [Uri]::UnescapeDataString($uri.Segments[-1])
        $dest = Join-Path $DownloadDir $fileName
        Write-Info ("[{0}/{1}] {2}  ->  {3}" -f $n, $ordered.Count, $m.name, $fileName)
        if ($PSCmdlet.ShouldProcess($dest, 'Download')) {
            Invoke-WebRequest -Uri $uri -OutFile "$dest.part" -UseBasicParsing
            Move-Item -LiteralPath "$dest.part" -Destination $dest -Force
            $done[$key] = $fileName
            Save-Progress
        }
    } catch {
        Write-Fail "$($m.name): $($_.Exception.Message)"
        $failed.Add((Format-ModRef $m))
        if ($_.Exception.Message -match '401|403') { break }
    }
}

Write-Section "Done"
Write-Ok "$($done.Count) archive(s) in $DownloadDir"
if ($failed.Count) {
    Write-Warn "$($failed.Count) failed - get these by hand:"
    $failed | ForEach-Object { Write-Host "    $_" }
}
Write-Host ""
Write-Info "Next: restart Vortex -> Mods tab -> filter 'Never Installed' -> select all -> Install."
Write-Info "Then deploy, and run .\scripts\Test-ModSetup.ps1. See docs/INSTALL-GUIDE.md."
