#Requires -Version 5.1
<#
.SYNOPSIS
    Guided install of the modpack through Vortex. Started by "Install with Vortex.bat".

.DESCRIPTION
    Asks a few questions, then installs the pack in stages (frameworks first). After each stage you
    install/deploy in Vortex and launch the game once; then the script checks the setup and moves on.
    Progress is saved, so closing the window and running it again continues at the next stage.

    Two ways to get mods into Vortex:
      Premium + API key : the script downloads each mod's exact file into Vortex's downloads folder.
      No key / free     : the script opens a nxm:// link per mod and Vortex downloads + installs it.
                          (Free accounts have to click "Download" in Vortex/browser for each mod.)
#>
[CmdletBinding()]
param([switch]$Reset)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$repo = Split-Path -Parent $here
Import-Module (Join-Path $here 'ModTools.psm1') -Force
Get-ChildItem -Path $here -Filter *.ps*1 | Unblock-File -ErrorAction SilentlyContinue

$stateFile = Join-Path $repo '.cache\vortex-install.json'
New-Item -ItemType Directory -Force (Split-Path $stateFile) | Out-Null
if ($Reset -and (Test-Path $stateFile)) { Remove-Item $stateFile -Force }

$stages = @(
    @{ n = 1; title = 'Frameworks (RED4ext, CET, redscript, ArchiveXL, TweakXL, Codeware...)'; files = @('00-frameworks.json') }
    @{ n = 2; title = 'Fixes, performance, UI & HUD';           files = @('10-fixes-performance.json', '20-ui-hud.json') }
    @{ n = 3; title = 'Gameplay & balance';                     files = @('30-gameplay.json') }
    @{ n = 4; title = 'Combat, weapons & vehicles';             files = @('40-combat-weapons.json', '50-vehicles.json') }
    @{ n = 5; title = 'World, NPCs, quests & new content';      files = @('60-world-npcs.json', '90-quests-content.json') }
    @{ n = 6; title = 'Graphics, lighting & weather';           files = @('70-graphics-lighting.json') }
    @{ n = 7; title = 'Appearance, clothing, audio & radio';    files = @('80-appearance.json', '85-audio-radio.json') }
    @{ n = 8; title = 'Your personal mods (99-personal.json)';  files = @('99-personal.json') }
)

function Ask([string]$q, [string[]]$choices, [string]$default) {
    while ($true) {
        $a = Read-Host "$q [$($choices -join '/')] (Enter = $default)"
        if (-not $a) { return $default }
        if ($choices -contains $a.ToLower()) { return $a.ToLower() }
        Write-Host "  Type one of: $($choices -join ', ')" -ForegroundColor Yellow
    }
}
function Save-State($s) { $s | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8 }

Clear-Host
Write-Host ""
Write-Host "  Ai modpack - Vortex installer" -ForegroundColor Cyan
Write-Host "  ------------------------------"
Write-Host ""

# ---------------------------------------------------------------- Checks
Write-Section "Checking your setup"
try { $game = Find-GameDir; Write-Ok "Cyberpunk 2077 found: $game" }
catch {
    Write-Fail $_.Exception.Message
    $p = Read-Host "Paste your Cyberpunk 2077 folder (the one containing 'bin')"
    $game = Find-GameDir -GameDir $p.Trim('"')
    [Environment]::SetEnvironmentVariable('CP2077_DIR', $game, 'User')
    $env:CP2077_DIR = $game
    Write-Ok "Saved. Using $game"
}

$vortexExe = @("$env:ProgramFiles\Black Tree Gaming Ltd\Vortex\Vortex.exe", "$env:LOCALAPPDATA\Programs\vortex\Vortex.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
$nxmHandler = ''
try { $nxmHandler = (Get-ItemProperty 'HKCU:\Software\Classes\nxm\shell\open\command' -ErrorAction Stop).'(default)' } catch { }

if ($vortexExe) { Write-Ok "Vortex installed" }
else { Write-Warn "Vortex not found in the usual places. Get it from nexusmods.com/app (if it's installed somewhere else, ignore this)." }
if ($nxmHandler -match 'vortex') { Write-Ok "Vortex handles Nexus download links" }
else { Write-Warn "Vortex isn't set to handle Nexus links yet: Vortex > Settings > Downloads > turn on 'Handle Nexus Links'." }
Write-Info "In Vortex, make sure Cyberpunk 2077 is the active game (Games tab > Manage)."

# ---------------------------------------------------------------- Questions (first run)
$state = $null
if (Test-Path $stateFile) { $state = Get-Content $stateFile -Raw | ConvertFrom-Json }

if (-not $state) {
    Write-Section "A few questions"
    $size = Ask "Pack size: (f)ull 1000+ mods, (r)ecommended only (2,000+ endorsements), (c)ore frameworks only" @('f', 'r', 'c') 'f'
    $mode = Ask "Do you have Nexus Premium and an API key? (y)es = fast direct downloads, (n)o = Vortex link mode" @('y', 'n') 'y'
    $backup = Ask "Back up your current mods, saves and settings first? (recommended)" @('y', 'n') 'y'
    $state = [pscustomobject]@{
        size = @{ f = 'optional'; r = 'recommended'; c = 'core' }[$size]
        mode = $(if ($mode -eq 'y') { 'Download' } else { 'Vortex' })
        next = 1
        backedUp = $false
    }
    if ($backup -eq 'y') {
        & (Join-Path $here 'Backup-Game.ps1') -GameDir $game -Label 'before-ai-modpack'
        $state.backedUp = $true
    }
    Save-State $state
} else {
    Write-Info "Continuing from stage $($state.next) (run with -Reset to start over)."
}

if ($state.mode -eq 'Download' -and -not $env:NEXUS_API_KEY) {
    Write-Host ""
    Write-Info "Your API key is at nexusmods.com > Settings > API Keys > Personal API Key (bottom of the page)."
    $sec = Read-Host "Paste your Nexus API key (hidden)" -AsSecureString
    $env:NEXUS_API_KEY = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    $keep = Ask "Remember the key for next time (stored in your Windows user environment)?" @('y', 'n') 'y'
    if ($keep -eq 'y') { [Environment]::SetEnvironmentVariable('NEXUS_API_KEY', $env:NEXUS_API_KEY, 'User') }
}

$lastStage = if ($state.size -eq 'core') { 1 } else { $stages.Count }

# ---------------------------------------------------------------- Stages
foreach ($st in $stages) {
    if ($st.n -lt $state.next -or $st.n -gt $lastStage) { continue }

    Write-Host ""
    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host "  Stage $($st.n) of $lastStage : $($st.title)" -ForegroundColor Cyan
    Write-Host "==================================================================" -ForegroundColor Cyan

    $installArgs = @{ Mode = $state.mode; Category = $st.files; MinPriority = $state.size; GameDir = $game; SkipInstalled = $true }
    $global:LASTEXITCODE = 0
    try { & (Join-Path $here 'Install-Modpack.ps1') @installArgs }
    catch { $global:LASTEXITCODE = 1; Write-Fail $_.Exception.Message }
    if ($LASTEXITCODE -ne 0) {
        Write-Info "That stage didn't finish. Fix the problem above and run the installer again; it'll retry this stage."
        Read-Host "Press Enter to close"; exit 1
    }

    Write-Host ""
    if ($state.mode -eq 'Download') {
        Write-Info "Now in Vortex:"
        Write-Host "    1. Restart Vortex (so it sees the new downloads)."
        Write-Host "    2. Downloads tab: select all new files > Install. (If they're not listed, drag them in from the folder printed above.)"
        Write-Host "    3. Answer any installer questions (pick the default if unsure)."
        Write-Host "    4. Mods tab: Enable all, then Deploy."
    } else {
        Write-Info "Vortex is downloading and installing these. Wait until its Downloads tab is idle, then Mods tab > Enable all > Deploy."
    }
    Write-Host "    5. Launch the game, load a save (or reach the main menu), then quit."
    if ($st.n -eq 1) { Write-Host "       First launch: Cyber Engine Tweaks asks you to pick an overlay key. Pick one." -ForegroundColor Yellow }
    Write-Host ""
    $r = Ask "Did the game start fine? (y)es = check & continue, (n)o = show the errors, (q)uit for now" @('y', 'n', 'q') 'y'

    if ($r -eq 'q') { Write-Info "Progress saved. Run 'Install with Vortex.bat' again to continue."; exit 0 }
    if ($r -eq 'n') {
        & (Join-Path $here 'Get-ModLogs.ps1') -GameDir $game
        Write-Info "See docs\TROUBLESHOOTING.md. Disable the mod(s) named above in Vortex, deploy, and test again."
        Write-Info "When the game works, run 'Install with Vortex.bat' again: it'll re-check this stage and continue."
        Read-Host "Press Enter to close"
        exit 1
    }

    & (Join-Path $here 'Test-ModSetup.ps1') -GameDir $game
    if ($st.n -eq 1 -and $LASTEXITCODE -ne 0) {
        Write-Warn "The frameworks check isn't clean. Everything else depends on these, so fix the [FAIL] lines first."
        Read-Host "Press Enter to close"
        exit 1
    }
    $state.next = $st.n + 1
    Save-State $state
}

Write-Section "All done"
Write-Ok "The modpack is installed through Vortex."
Write-Info "Updating later: rerun this installer with -Reset after pulling a new manifest, or update mods in Vortex."
Write-Info "If something breaks: run scripts\Get-ModLogs.ps1 and see docs\TROUBLESHOOTING.md."
Read-Host "Press Enter to close"
