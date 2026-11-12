#Requires -Version 5.1
<#
.SYNOPSIS
    Uploads the modpack to Nexus Mods as an UNPUBLISHED DRAFT collection.

.DESCRIPTION
    1. Builds a Vortex-style collection.json from the manifest (every mod pinned to its exact file,
       frameworks in install phase 0, everything else in phase 1).
    2. Checks each pinned file still exists on Nexus and records its size (cached in .cache\, ~1 API
       call per mod; pauses if the hourly limit gets low). If a pinned file was removed, it switches
       to that mod's newest main file. Skip with -SkipFileCheck.
    3. Packs it into a .7z (uses 7-Zip if installed, otherwise .zip) in .\collection\.
    4. Uploads it and calls createCollection. That creates a DRAFT only: this script never
       publishes. Review it on Nexus, add images and a category, then press Publish there.

    Run with -DryRun first to build the files without uploading anything.

    Nexus may only accept collection uploads from Vortex's login rather than a personal API key.
    If so, the script stops with Nexus's error, and you can upload the .7z from Vortex instead
    (see docs\INSTALL-GUIDE.md).

.EXAMPLE
    .\scripts\Publish-Collection.ps1 -DryRun
.EXAMPLE
    $env:NEXUS_API_KEY = "<key>"; .\scripts\Publish-Collection.ps1
.EXAMPLE
    .\scripts\Publish-Collection.ps1 -Name "Ai modpack" -MinPriority recommended
#>
[CmdletBinding()]
param(
    [string]$Name = 'Ai modpack',
    [string]$Summary = 'A 1000+ mod Cyberpunk 2077 overhaul for game version 2.5: frameworks, fixes, UI, gameplay, combat, vehicles, world, graphics, appearance and audio.',
    [string]$Description,
    [string]$GameVersion = '2.5.0.0',
    [string]$ManifestDir,
    [string]$ApiKey = $env:NEXUS_API_KEY,
    # Only include mods at or above this priority (requirements always included).
    [ValidateSet('core', 'recommended', 'optional')]
    [string]$MinPriority = 'optional',
    # Mark 'optional'-priority mods as optional in the collection (users can untick them in Vortex).
    [switch]$LowPriorityOptional,
    [switch]$SkipFileCheck,
    # Build collection.json + archive only; no upload.
    [switch]$DryRun,
    # Add a new draft revision to a collection you already created with this script.
    [int]$CollectionId = 0
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ModTools.psm1') -Force
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

$Domain = 'cyberpunk2077'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$OutDir = Join-Path $RepoRoot 'collection'
$CacheFile = Join-Path $RepoRoot '.cache\collection-files.json'
New-Item -ItemType Directory -Force $OutDir, (Split-Path $CacheFile) | Out-Null

if (-not $ApiKey -and -not ($DryRun -and $SkipFileCheck)) {
    Write-Fail "Set `$env:NEXUS_API_KEY (nexusmods.com > Settings > API Keys) or pass -ApiKey."
    exit 2
}
$headers = @{ apikey = $ApiKey; 'Application-Name' = 'cp2077-modpack-publisher'; 'Application-Version' = '1.0.0' }

# ---------------------------------------------------------------- API helpers
$script:hourlyLeft = 9999
function Invoke-V1([string]$Path) {
    for ($try = 0; $try -lt 5; $try++) {
        if ($script:hourlyLeft -lt 15) {
            Write-Warn "Nexus hourly API limit nearly used up; waiting 10 minutes (progress is cached)..."
            Start-Sleep -Seconds 600; $script:hourlyLeft = 9999
        }
        try {
            $r = Invoke-WebRequest -Uri "https://api.nexusmods.com/v1/$Path" -Headers $headers -UseBasicParsing
            $left = $r.Headers['X-Rl-Hourly-Remaining']; if ($left) { $script:hourlyLeft = [int](@($left)[0]) }
            return ($r.Content | ConvertFrom-Json)
        } catch {
            $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch { }
            if ($code -eq 401) { throw "Nexus rejected the API key (401)." }
            if ($code -eq 404) { return $null }
            if ($code -eq 429) { Start-Sleep -Seconds 120; continue }
            if ($try -lt 4) { Start-Sleep -Seconds (5 * ($try + 1)); continue }
            throw
        }
    }
}

function Invoke-Gql([string]$Query, [hashtable]$Variables = @{}) {
    $body = @{ query = $Query; variables = $Variables } | ConvertTo-Json -Depth 30 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    $r = Invoke-WebRequest -Uri 'https://api.nexusmods.com/v2/graphql' -Method Post -Headers $headers `
        -ContentType 'application/json; charset=utf-8' -Body $bytes -UseBasicParsing
    $res = $r.Content | ConvertFrom-Json
    if ($res.PSObject.Properties.Name -contains 'errors' -and $res.errors) {
        throw ("Nexus GraphQL error: " + (($res.errors | ForEach-Object { $_.message }) -join '; '))
    }
    return $res.data
}

# ---------------------------------------------------------------- Select mods
$mp = Import-Modpack -ManifestDir $ManifestDir
$byId = @{}; foreach ($m in $mp.Mods) { $byId[$m.id] = $m }
$rank = @{ core = 0; recommended = 1; optional = 2 }
$selected = @{}
$stack = New-Object System.Collections.Stack
foreach ($m in $mp.Mods) {
    if ((Get-Prop $m 'nexusId') -and $rank[(Get-Prop $m 'priority' 'optional')] -le $rank[$MinPriority]) { $stack.Push($m.id) }
}
$isDependency = @{}
while ($stack.Count) {
    $id = $stack.Pop()
    if ($selected.ContainsKey($id) -or -not $byId.ContainsKey($id)) { continue }
    $selected[$id] = $true
    foreach ($d in @(Get-Prop $byId[$id] 'dependsOn' @())) { $isDependency[$d] = $true; $stack.Push($d) }
}
$mods = @($selected.Keys | ForEach-Object { $byId[$_] } | Where-Object { Get-Prop $_ 'mainFile' } |
    Sort-Object SourceFile, @{ e = { -[int](Get-Prop $_ 'endorsements' 0) } })
Write-Section "Collection '$Name': $($mods.Count) mods"

# ---------------------------------------------------------------- File check
$cache = @{}
if (Test-Path -LiteralPath $CacheFile) {
    (Get-Content -LiteralPath $CacheFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $cache[$_.Name] = $_.Value }
}
$swapped = 0; $dropped = New-Object System.Collections.Generic.List[string]
if (-not $SkipFileCheck) {
    Write-Info "Checking pinned files on Nexus (cached after the first run)..."
    $n = 0
    foreach ($m in $mods) {
        $n++
        $key = "$($m.nexusId)"
        if (-not $cache.ContainsKey($key)) {
            $files = Invoke-V1 "games/$Domain/mods/$($m.nexusId)/files.json"
            $list = if ($files) { @($files.files | ForEach-Object {
                [pscustomobject]@{ id = $_.file_id; name = $_.name; version = $_.version; size = $_.size_in_bytes; cat = $_.category_name; ts = $_.uploaded_timestamp } }) } else { @() }
            $cache[$key] = $list
            if ($n % 25 -eq 0) { $cache | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $CacheFile -Encoding UTF8; Write-Info "  $n/$($mods.Count)" }
        }
    }
    $cache | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $CacheFile -Encoding UTF8
}

# ---------------------------------------------------------------- Build entries
$entries = New-Object System.Collections.Generic.List[object]
$gqlMods = New-Object System.Collections.Generic.List[object]
foreach ($m in $mods) {
    $main = $m.mainFile
    $fileId = [int]$main.fileId; $fileName = [string]$main.name; $version = [string]$main.version; $size = $null
    if (-not $SkipFileCheck) {
        $files = @($cache["$($m.nexusId)"])
        $f = $files | Where-Object { $_ -and $_.id -eq $fileId -and $_.cat -notin 'ARCHIVED', 'DELETED' } | Select-Object -First 1
        if (-not $f) {
            $f = $files | Where-Object { $_ -and $_.cat -eq 'MAIN' } | Sort-Object ts -Descending | Select-Object -First 1
            if ($f) { $swapped++ } else { $dropped.Add((Format-ModRef $m)); continue }
        }
        $fileId = [int]$f.id; $fileName = [string]$f.name; $version = [string]$f.version; $size = [long]$f.size
    }
    if (-not $version) { $version = '1.0' }
    $optional = [bool]($LowPriorityOptional -and (Get-Prop $m 'priority' 'optional') -eq 'optional' -and -not $isDependency[$m.id])
    $source = [ordered]@{ type = 'nexus'; modId = [int]$m.nexusId; fileId = $fileId; updatePolicy = 'exact'; logicalFilename = $fileName }
    if ($size) { $source.fileSize = $size }
    $author = [string](Get-Prop $m 'author' '')

    # collection.json (Vortex format) entry
    $entries.Add([ordered]@{
        name = $m.name; version = $version; optional = $optional; domainName = $Domain
        source = $source; author = $author
        details = [ordered]@{ category = [string](Get-Prop $m 'nexusCategory' ''); type = '' }
        phase = $(if ($m.SourceFile -eq '00-frameworks.json') { 0 } else { 1 })
        instructions = [string](Get-Prop $m 'notes' (Get-Prop $m 'autoNotes' ''))
    })
    # GraphQL manifest entry (subset the API accepts)
    $gqlMods.Add([ordered]@{ name = $m.name; version = $version; optional = $optional; domainName = $Domain; source = $source; author = $author })
}
if ($swapped) { Write-Warn "$swapped pinned file(s) were gone from Nexus; switched to the newest main file." }
if ($dropped.Count) { Write-Warn "$($dropped.Count) mod(s) have no downloadable file any more and were left out:"; $dropped | ForEach-Object { Write-Host "    $_" } }

if (-not $Description) {
    $counts = ($mods | Group-Object SourceFile | Sort-Object Name | ForEach-Object {
        $t = ($mp.Pack.categories | Where-Object file -eq $_.Name).title; "- $t`: $($_.Count)" }) -join "`n"
    $Description = @"
$Summary

Built from the most-endorsed mods per category, each pinned to an exact file and checked for patch 2.5:
updated after 2.5, a recent script mod, or an asset-only mod. Every Nexus requirement is included.

$counts

Install with Vortex. Frameworks (RED4ext, Cyber Engine Tweaks, redscript, ArchiveXL, TweakXL, Codeware) install first.
Launch once after the frameworks phase to bind the CET overlay key.
"@
}

$info = [ordered]@{
    author = ''; authorUrl = ''; name = $Name; summary = $Summary; description = $Description
    installInstructions = 'Frameworks install first (phase 1). If a mod asks installer questions, pick the default unless you know you need another option.'
    domainName = $Domain; gameVersions = @($GameVersion)
}

if (-not $DryRun) {
    $me = Invoke-V1 'users/validate.json'
    $info.author = [string]$me.name
    $info.authorUrl = "https://www.nexusmods.com/users/$($me.user_id)"
}

# ---------------------------------------------------------------- Write archive
$collection = [ordered]@{ info = $info; mods = $entries; modRules = @(); loadOrder = @() }
$stage = Join-Path $OutDir 'staging'
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force $stage | Out-Null
$jsonPath = Join-Path $stage 'collection.json'
[IO.File]::WriteAllText($jsonPath, ($collection | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding $false))

$safe = ($Name -replace '[^\w\-]+', '-').Trim('-')
$sevenZip = @("$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe") | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if ($sevenZip) {
    $archive = Join-Path $OutDir "$safe.7z"
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    & $sevenZip a -t7z $archive $jsonPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "7-Zip failed (exit $LASTEXITCODE)" }
} else {
    Write-Warn "7-Zip not found, making a .zip instead. If Nexus rejects it, install 7-Zip (7-zip.org) and rerun."
    $archive = Join-Path $OutDir "$safe.zip"
    Compress-Archive -Path $jsonPath -DestinationPath $archive -Force
}
Copy-Item -LiteralPath $jsonPath -Destination (Join-Path $OutDir 'collection.json') -Force
Write-Ok "Built $archive ($($entries.Count) mods)"

if ($DryRun) {
    Write-Info "Dry run: nothing uploaded. Check collection\collection.json, then rerun without -DryRun."
    exit 0
}

# ---------------------------------------------------------------- Upload + create draft
Write-Section "Uploading draft to Nexus"
$slot = (Invoke-Gql '{ collectionRevisionUploadUrl { url uuid } }').collectionRevisionUploadUrl
Invoke-WebRequest -Uri $slot.url -Method Put -InFile $archive -ContentType 'application/octet-stream' -UseBasicParsing | Out-Null
Write-Ok "Archive uploaded"

$payload = @{
    adultContent = $false
    collectionSchemaId = 1
    collectionManifest = @{ info = [ordered]@{ author = $info.author; authorUrl = $info.authorUrl; name = $Name; summary = $Summary; description = $Description; domainName = $Domain; gameVersions = @($GameVersion) }; mods = $gqlMods }
}

try {
    if ($CollectionId -gt 0) {
        $q = 'mutation($data: CollectionPayload!, $id: Int!, $uuid: String!) { createOrUpdateRevision(collectionData: $data, collectionId: $id, uuid: $uuid) { success collectionId revisionId revisionNumber collection { slug } } }'
        $res = (Invoke-Gql $q @{ data = $payload; id = $CollectionId; uuid = $slot.uuid }).createOrUpdateRevision
    } else {
        $q = 'mutation($data: CollectionPayload!, $uuid: String!) { createCollection(collectionData: $data, uuid: $uuid) { success collectionId revisionId collection { slug } } }'
        $res = (Invoke-Gql $q @{ data = $payload; uuid = $slot.uuid }).createCollection
    }
} catch {
    Write-Fail $_.Exception.Message
    Write-Info "If Nexus refused the API key for this, upload from Vortex instead: Collections tab > Create > import $archive, or recreate it from your profile."
    exit 1
}

if (-not $res.success) { Write-Fail "Nexus didn't confirm the upload."; exit 1 }

$slug = $res.collection.slug
Write-Section "Draft created (not published)"
Write-Ok "Collection id $($res.collectionId), revision id $($res.revisionId)"
Write-Info "Review it: https://www.nexusmods.com/games/$Domain/collections/$slug  (or nexusmods.com > your profile > Collections)"
Write-Info "On that page: add a category, tile/header images and screenshots, then Publish when you're happy."
Write-Info "To upload changes later as a new draft revision: .\scripts\Publish-Collection.ps1 -CollectionId $($res.collectionId)"
@{ collectionId = $res.collectionId; slug = $slug; revisionId = $res.revisionId; created = (Get-Date).ToString('o') } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutDir 'published.json') -Encoding UTF8
exit 0
