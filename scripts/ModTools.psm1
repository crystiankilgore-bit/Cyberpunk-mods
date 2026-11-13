#Requires -Version 5.1
<#
    Shared helpers for the Cyberpunk 2077 modpack scripts.
    Works on Windows PowerShell 5.1 and PowerShell 7+.
#>

Set-StrictMode -Version Latest

$script:RepoRoot = Split-Path -Parent $PSScriptRoot

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

function Write-Ok    { param([string]$Message) Write-Host "  [ OK ] $Message" -ForegroundColor Green }
function Write-Warn  { param([string]$Message) Write-Host "  [WARN] $Message" -ForegroundColor Yellow }
function Write-Fail  { param([string]$Message) Write-Host "  [FAIL] $Message" -ForegroundColor Red }
function Write-Info  { param([string]$Message) Write-Host "  [INFO] $Message" -ForegroundColor Cyan }
function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "== $Title ==" -ForegroundColor White
}

# ---------------------------------------------------------------------------
# Locating the game
# ---------------------------------------------------------------------------

function Test-IsGameDir {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return Test-Path -LiteralPath (Join-Path $Path 'bin/x64/Cyberpunk2077.exe')
}

function Get-SteamLibraryPaths {
    $libraries = New-Object System.Collections.Generic.List[string]
    $steamRoots = @()

    foreach ($key in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
        try {
            $props = Get-ItemProperty -Path $key -ErrorAction Stop
            foreach ($name in 'SteamPath', 'InstallPath') {
                if ($props.PSObject.Properties.Name -contains $name -and $props.$name) {
                    $steamRoots += ($props.$name -replace '/', '\')
                }
            }
        } catch { }
    }
    $steamRoots += "${env:ProgramFiles(x86)}\Steam"

    foreach ($root in ($steamRoots | Where-Object { $_ } | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $libraries.Add($root)
        $vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            foreach ($line in Get-Content -LiteralPath $vdf) {
                if ($line -match '"path"\s+"([^"]+)"') {
                    $libraries.Add(($Matches[1] -replace '\\\\', '\'))
                }
            }
        }
    }
    return $libraries | Select-Object -Unique
}

function Find-GameDir {
    <#
        .SYNOPSIS
        Returns the Cyberpunk 2077 install folder, or throws if it can't be found.
        Checks, in order: the -GameDir argument, $env:CP2077_DIR, Steam, GOG, Epic, common paths.
    #>
    param([string]$GameDir)

    if ($GameDir) {
        if (Test-IsGameDir $GameDir) { return (Resolve-Path -LiteralPath $GameDir).Path }
        throw "'$GameDir' is not a Cyberpunk 2077 folder (bin\x64\Cyberpunk2077.exe not found)."
    }

    if ($env:CP2077_DIR -and (Test-IsGameDir $env:CP2077_DIR)) { return $env:CP2077_DIR }

    $candidates = New-Object System.Collections.Generic.List[string]

    # Steam
    foreach ($lib in Get-SteamLibraryPaths) {
        $candidates.Add((Join-Path $lib 'steamapps\common\Cyberpunk 2077'))
    }

    # GOG (registry)
    foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games\1423049311', 'HKLM:\SOFTWARE\GOG.com\Games\1423049311') {
        try {
            $p = (Get-ItemProperty -Path $key -ErrorAction Stop).path
            if ($p) { $candidates.Add($p) }
        } catch { }
    }

    # Epic (manifests)
    $epicManifests = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'
    if ($env:ProgramData -and (Test-Path -LiteralPath $epicManifests)) {
        foreach ($item in Get-ChildItem -LiteralPath $epicManifests -Filter *.item -ErrorAction SilentlyContinue) {
            try {
                $m = Get-Content -LiteralPath $item.FullName -Raw | ConvertFrom-Json
                if ($m.DisplayName -like '*Cyberpunk 2077*') { $candidates.Add($m.InstallLocation) }
            } catch { }
        }
    }

    # Common fallbacks
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        foreach ($rel in 'SteamLibrary\steamapps\common\Cyberpunk 2077',
                         'Program Files (x86)\Steam\steamapps\common\Cyberpunk 2077',
                         'GOG Games\Cyberpunk 2077',
                         'Program Files (x86)\GOG Galaxy\Games\Cyberpunk 2077',
                         'Program Files\Epic Games\Cyberpunk2077',
                         'Games\Cyberpunk 2077') {
            $candidates.Add((Join-Path $drive.Root $rel))
        }
    }

    foreach ($c in ($candidates | Select-Object -Unique)) {
        if (Test-IsGameDir $c) { return $c }
    }

    throw "Couldn't find Cyberpunk 2077. Pass -GameDir 'D:\path\to\Cyberpunk 2077' or set `$env:CP2077_DIR."
}

function Get-GameVersion {
    param([Parameter(Mandatory)][string]$GameDir)
    $exe = Join-Path $GameDir 'bin/x64/Cyberpunk2077.exe'
    $info = (Get-Item -LiteralPath $exe).VersionInfo
    [pscustomobject]@{
        ProductVersion = $info.ProductVersion
        FileVersion    = $info.FileVersion
        LastWriteTime  = (Get-Item -LiteralPath $exe).LastWriteTime
    }
}

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------

function Get-ManifestDir {
    param([string]$ManifestDir)
    if ($ManifestDir) { return $ManifestDir }
    return (Join-Path $script:RepoRoot 'manifest')
}

function Import-Modpack {
    <#
        .SYNOPSIS
        Loads manifest/modpack.json plus every manifest/mods/*.json file.
        Returns an object with .Pack (settings) and .Mods (all mod entries, each tagged with SourceFile).
    #>
    param([string]$ManifestDir)

    $dir = Get-ManifestDir $ManifestDir
    $packFile = Join-Path $dir 'modpack.json'
    if (-not (Test-Path -LiteralPath $packFile)) { throw "Manifest not found: $packFile" }

    $pack = Get-Content -LiteralPath $packFile -Raw | ConvertFrom-Json
    $mods = New-Object System.Collections.Generic.List[object]

    $modsDir = Join-Path $dir 'mods'
    foreach ($file in (Get-ChildItem -LiteralPath $modsDir -Filter *.json | Sort-Object Name)) {
        $data = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
        foreach ($m in @($data.mods)) {
            if ($null -eq $m) { continue }
            $m | Add-Member -NotePropertyName SourceFile -NotePropertyValue $file.Name -Force
            if (-not ($m.PSObject.Properties.Name -contains 'category') -or -not $m.category) {
                $m | Add-Member -NotePropertyName category -NotePropertyValue $data.category -Force
            }
            $mods.Add($m)
        }
    }

    [pscustomobject]@{ Pack = $pack; Mods = $mods.ToArray(); Dir = $dir }
}

function Get-Prop {
    # Safe property read for optional manifest fields under StrictMode.
    param($Object, [string]$Name, $Default = $null)
    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name -and $null -ne $Object.$Name) {
        return $Object.$Name
    }
    return $Default
}

function Test-ModInstalled {
    <#
        .SYNOPSIS
        Returns $true / $false if the mod's detect paths exist, or $null if the entry has no detect info.
        detect.paths   - every path must exist (relative to the game folder; wildcards allowed)
        detect.anyOf   - at least one must exist
    #>
    param([Parameter(Mandatory)]$Mod, [Parameter(Mandatory)][string]$GameDir)

    $detect = Get-Prop $Mod 'detect'
    if ($null -eq $detect) { return $null }

    $all = @(Get-Prop $detect 'paths' @())
    $any = @(Get-Prop $detect 'anyOf' @())
    if ($all.Count -eq 0 -and $any.Count -eq 0) { return $null }

    foreach ($p in $all) {
        if (-not (Test-Path -Path (Join-Path $GameDir $p))) { return $false }
    }
    if ($any.Count -gt 0) {
        foreach ($p in $any) {
            if (Test-Path -Path (Join-Path $GameDir $p)) { return $true }
        }
        return $false
    }
    return $true
}

function Get-InstallState {
    <#
        .SYNOPSIS
        Builds a hashtable id -> $true/$false/$null for every mod in the manifest.
    #>
    param([Parameter(Mandatory)]$Mods, [Parameter(Mandatory)][string]$GameDir)
    $state = @{}
    foreach ($m in $Mods) { $state[$m.id] = Test-ModInstalled -Mod $m -GameDir $GameDir }
    return $state
}

function Get-DependencyReport {
    <#
        .SYNOPSIS
        Finds dependency and conflict problems.
        Without -State: only checks the manifest itself (unknown ids).
        With -State (from Get-InstallState): also checks installed mods for missing deps / active conflicts.
        Mods whose install state is unknown ($null, no detect info) are treated as installed if
        -AssumeUnknownInstalled is set, otherwise they're skipped.
    #>
    param(
        [Parameter(Mandatory)]$Mods,
        [hashtable]$State,
        [switch]$AssumeUnknownInstalled
    )

    $byId = @{}
    foreach ($m in $Mods) { $byId[$m.id] = $m }

    $isOn = {
        param($id)
        if (-not $State) { return $true }
        $s = $State[$id]
        if ($null -eq $s) { return [bool]$AssumeUnknownInstalled }
        return [bool]$s
    }

    $problems = New-Object System.Collections.Generic.List[object]
    foreach ($m in $Mods) {
        $modOn = & $isOn $m.id
        foreach ($dep in @(Get-Prop $m 'dependsOn' @())) {
            if (-not $byId.ContainsKey($dep)) {
                $problems.Add([pscustomobject]@{ Type = 'UnknownDependency'; Mod = $m; Other = $dep })
            } elseif ($State -and $modOn -and $State[$dep] -eq $false) {
                $problems.Add([pscustomobject]@{ Type = 'MissingDependency'; Mod = $m; Other = $byId[$dep] })
            }
        }
        foreach ($c in @(Get-Prop $m 'conflictsWith' @())) {
            if (-not $byId.ContainsKey($c)) {
                $problems.Add([pscustomobject]@{ Type = 'UnknownConflict'; Mod = $m; Other = $c })
            } elseif ($State -and $modOn -and $State[$c] -eq $true -and ($m.id -lt $c -or -not (@(Get-Prop $byId[$c] 'conflictsWith' @()) -contains $m.id))) {
                # Report each conflicting pair once.
                $problems.Add([pscustomobject]@{ Type = 'Conflict'; Mod = $m; Other = $byId[$c] })
            }
        }
    }
    return $problems.ToArray()
}

function Get-VortexDirs {
    <#
        .SYNOPSIS
        Best-guess Vortex download and staging folders for Cyberpunk. Vortex keeps the real paths in
        its own database, so this checks the defaults: %APPDATA%\Vortex\... and "<drive>:\Vortex Mods\..."
        on every drive (Vortex suggests that when the game is on a different drive).
    #>
    param([string]$GameDir)
    $downloads = New-Object System.Collections.Generic.List[string]
    $staging = New-Object System.Collections.Generic.List[string]
    if ($env:APPDATA) {
        $downloads.Add((Join-Path $env:APPDATA 'Vortex\downloads\cyberpunk2077'))
        $staging.Add((Join-Path $env:APPDATA 'Vortex\cyberpunk2077\mods'))
    }
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        foreach ($base in 'Vortex Mods', 'Vortex', 'Vortex\Mods', 'Modding\Vortex') {
            $staging.Add((Join-Path $drive.Root "$base\cyberpunk2077"))
            $staging.Add((Join-Path $drive.Root "$base\cyberpunk2077\mods"))
            $downloads.Add((Join-Path $drive.Root "$base\downloads\cyberpunk2077"))
        }
    }
    [pscustomobject]@{
        Downloads = @($downloads | Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ })
        Staging   = @($staging | Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ })
    }
}

function Find-ModInVortex {
    <#
        .SYNOPSIS
        For a mod that isn't in the game folder, says whether Vortex has it installed (staging) or
        only downloaded. Returns 'staged', 'downloaded' or $null.
    #>
    param([Parameter(Mandatory)]$Mod, [Parameter(Mandatory)]$VortexDirs)
    $detect = Get-Prop $Mod 'detect'
    $paths = @(Get-Prop $detect 'paths' @()) + @(Get-Prop $detect 'anyOf' @())
    foreach ($s in $VortexDirs.Staging) {
        foreach ($modFolder in Get-ChildItem -LiteralPath $s -Directory -ErrorAction SilentlyContinue) {
            foreach ($p in $paths) {
                if (Test-Path -Path (Join-Path $modFolder.FullName $p)) { return [pscustomobject]@{ State = 'staged'; Where = $modFolder.FullName } }
            }
        }
    }
    $nid = Get-Prop $Mod 'nexusId'
    foreach ($d in $VortexDirs.Downloads) {
        $progress = Join-Path $d '.modpack-progress.json'
        if ($nid -and (Test-Path -LiteralPath $progress)) {
            $map = Get-Content -LiteralPath $progress -Raw | ConvertFrom-Json
            if ($map.PSObject.Properties.Name -contains "$nid") {
                return [pscustomobject]@{ State = 'downloaded'; Where = (Join-Path $d $map."$nid") }
            }
        }
        $pattern = ($Mod.name -replace '[^\w]+', '*')
        $hit = Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$pattern*" -or ($nid -and $_.Name -match "-$nid-") } | Select-Object -First 1
        if ($hit) { return [pscustomobject]@{ State = 'downloaded'; Where = $hit.FullName } }
    }
    return $null
}

function Format-ModRef {
    param($Mod)
    $nid = Get-Prop $Mod 'nexusId'
    if ($nid) { return "$($Mod.name) [$($Mod.id)] - https://www.nexusmods.com/cyberpunk2077/mods/$nid" }
    return "$($Mod.name) [$($Mod.id)]"
}

Export-ModuleMember -Function Write-Ok, Write-Warn, Write-Fail, Write-Info, Write-Section,
    Test-IsGameDir, Find-GameDir, Get-GameVersion, Get-ManifestDir, Import-Modpack, Get-Prop,
    Test-ModInstalled, Get-InstallState, Get-DependencyReport, Format-ModRef, Get-VortexDirs, Find-ModInVortex
