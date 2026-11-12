#Requires -Version 5.1
<#
.SYNOPSIS
    Validates the manifest files. Doesn't need the game installed (runs in CI too).

.DESCRIPTION
    Checks: JSON parses, required fields, id format, duplicate ids, duplicate Nexus ids,
    unknown dependsOn / conflictsWith ids, dependency cycles, mods that depend on something
    they also conflict with, category files listed in modpack.json that are missing (or vice versa).

.EXAMPLE
    .\scripts\Test-Manifest.ps1
#>
[CmdletBinding()]
param([string]$ManifestDir)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ModTools.psm1') -Force

$errors = New-Object System.Collections.Generic.List[string]
$warns  = New-Object System.Collections.Generic.List[string]

try { $mp = Import-Modpack -ManifestDir $ManifestDir } catch { Write-Fail "Can't load manifest: $($_.Exception.Message)"; exit 2 }
$mods = $mp.Mods

# Category files vs modpack.json
$listed = @($mp.Pack.categories | ForEach-Object { $_.file })
$onDisk = @(Get-ChildItem -LiteralPath (Join-Path $mp.Dir 'mods') -Filter *.json | ForEach-Object Name)
foreach ($f in $listed) { if ($onDisk -notcontains $f) { $errors.Add("modpack.json lists '$f' but manifest/mods/$f doesn't exist.") } }
foreach ($f in $onDisk) { if ($listed -notcontains $f) { $warns.Add("manifest/mods/$f isn't listed in modpack.json categories (it's still loaded).") } }

$byId = @{}
$byNexus = @{}
$allowed = 'id', 'name', 'nexusId', 'category', 'priority', 'required', 'dependsOn', 'conflictsWith',
           'testedGameVersion', 'modVersion', 'detect', 'logFiles', 'notes', 'SourceFile',
           'author', 'endorsements', 'nexusCategory', 'compat', 'mainFile', 'summary', 'autoNotes'

foreach ($m in $mods) {
    $where = "$($m.SourceFile)"
    $id = Get-Prop $m 'id'
    if (-not $id) { $errors.Add("$where : a mod has no id (name: '$(Get-Prop $m 'name')')."); continue }
    $where = "$($m.SourceFile) [$id]"

    if ($id -cnotmatch '^[a-z0-9][a-z0-9-]*$') { $errors.Add("$where : id must be lowercase letters, digits and dashes.") }
    if (-not (Get-Prop $m 'name')) { $errors.Add("$where : missing name.") }

    if ($byId.ContainsKey($id)) { $errors.Add("$where : duplicate id (also in $($byId[$id].SourceFile)).") }
    else { $byId[$id] = $m }

    foreach ($p in $m.PSObject.Properties.Name) {
        if ($allowed -notcontains $p) { $warns.Add("$where : unknown field '$p' (typo?).") }
    }

    $nid = Get-Prop $m 'nexusId'
    if ($null -ne $nid) {
        if (-not ($nid -is [int] -or $nid -is [long]) -or $nid -le 0) { $errors.Add("$where : nexusId must be a positive number.") }
        elseif ($byNexus.ContainsKey($nid)) { $warns.Add("$where : same nexusId $nid as [$($byNexus[$nid])]. Fine if they're two files from one Nexus page.") }
        else { $byNexus[$nid] = $id }
    } else {
        $warns.Add("$where : no nexusId.")
    }

    $prio = Get-Prop $m 'priority'
    if ($prio -and @('core', 'recommended', 'optional') -notcontains $prio) { $errors.Add("$where : priority must be core, recommended or optional.") }

    if ($null -eq (Get-Prop $m 'detect')) { $warns.Add("$where : no detect paths, so scripts can't tell if it's installed.") }

    $deps = @(Get-Prop $m 'dependsOn' @())
    $cons = @(Get-Prop $m 'conflictsWith' @())
    foreach ($d in $deps) { if ($cons -contains $d) { $errors.Add("$where : '$d' is in both dependsOn and conflictsWith.") } }
    if ($deps -contains $id) { $errors.Add("$where : depends on itself.") }
}

foreach ($p in (Get-DependencyReport -Mods $mods)) {
    $kind = if ($p.Type -eq 'UnknownDependency') { 'dependsOn' } else { 'conflictsWith' }
    $errors.Add("$($p.Mod.SourceFile) [$($p.Mod.id)] : $kind '$($p.Other)' doesn't match any mod id.")
}

# Cycle detection (DFS, 0 = unvisited, 1 = in progress, 2 = done)
$mark = @{}
$stack = New-Object System.Collections.Generic.List[string]
function Visit([string]$id) {
    if (-not $byId.ContainsKey($id)) { return }
    if ($mark[$id] -eq 2) { return }
    if ($mark[$id] -eq 1) {
        $start = $stack.IndexOf($id)
        $cycle = ($stack.GetRange($start, $stack.Count - $start) + $id) -join ' -> '
        $script:errors.Add("Dependency cycle: $cycle")
        return
    }
    $mark[$id] = 1
    $stack.Add($id)
    foreach ($d in @(Get-Prop $byId[$id] 'dependsOn' @())) { Visit $d }
    $stack.RemoveAt($stack.Count - 1)
    $mark[$id] = 2
}
foreach ($id in @($byId.Keys)) { Visit $id }

# Report
Write-Section "Manifest: $($mods.Count) mods in $($onDisk.Count) files"
foreach ($c in ($mods | Group-Object category | Sort-Object Name)) { Write-Info ("{0,5}  {1}" -f $c.Count, $c.Name) }

if ($warns.Count -gt 0) {
    Write-Section "Warnings ($($warns.Count))"
    $warns | Select-Object -First 200 | ForEach-Object { Write-Warn $_ }
    if ($warns.Count -gt 200) { Write-Info "... $($warns.Count - 200) more" }
}
Write-Section "Result"
if ($errors.Count -eq 0) {
    Write-Ok "Manifest is valid."
    exit 0
}
$errors | ForEach-Object { Write-Fail $_ }
Write-Fail "$($errors.Count) error(s)."
exit 1
