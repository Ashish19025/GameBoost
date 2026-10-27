#Requires -Version 5.1
<#
.SYNOPSIS
    GameBoost - safe, reversible gaming optimizer for Windows 10/11.

.DESCRIPTION
    Run with no arguments for the menu, or use -Action for scripts and shortcuts:

      Check        Read-only PC check: what is holding your FPS back
      Tune         One-time Windows gaming tweaks + set up all installed games
      Scan         Find newly installed games and make them use the dedicated GPU
      AddGame      Pick a game .exe by hand
      Boost        Pause background stuff while you game, restore it when you're done
      Preview      Show what Boost would do, without changing anything
      Restore      End an active Boost and put everything back
      AutoScanOn   Set up new games automatically at every login
      AutoScanOff  Turn that off
      Undo         Reverse every change GameBoost has ever made

.EXAMPLE
    .\GameBoost.ps1 -Action Boost
.EXAMPLE
    .\GameBoost.ps1 -Action Boost -NoWait     # boost and exit; run -Action Restore later
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Check', 'Tune', 'Scan', 'AddGame', 'Boost', 'Preview', 'Restore', 'AutoScanOn', 'AutoScanOff', 'Undo')]
    [string]$Action = 'Menu',
    [switch]$NoWait,
    [switch]$Quiet,
    [switch]$PauseAtEnd
)

$ErrorActionPreference = 'Continue'
$Root = $PSScriptRoot
foreach ($f in 'Common', 'Tweaks', 'Games', 'Check', 'Session') { . (Join-Path $Root "lib\$f.ps1") }
$script:QuietMode = [bool]$Quiet

# ---------------- Administrator ----------------
$needsAdmin = @('Check', 'Scan') -notcontains $Action
if ($needsAdmin -and -not (Test-IsAdmin)) {
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Action $Action -PauseAtEnd"
    if ($NoWait) { $argList += ' -NoWait' }
    Write-Host 'GameBoost needs administrator permission for this. Asking now...' -ForegroundColor Yellow
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList $argList }
    catch { Write-Host 'Permission was not given, so nothing was changed.' -ForegroundColor Red; Start-Sleep -Seconds 3 }
    exit
}

try { $Host.UI.RawUI.WindowTitle = "GameBoost $($script:GBVersion)" } catch {}

try { $Config = Get-GBConfig $Root }
catch { Write-Host $_.Exception.Message -ForegroundColor Red; if ($PauseAtEnd) { [void](Read-Host 'Press Enter to close') }; exit 1 }

function Invoke-GBAction([string]$Name) {
    switch ($Name) {
        'Check'       { Invoke-Check }
        'Tune'        { Invoke-Tune $Config }
        'Scan'        { Invoke-GameScan $Config }
        'AddGame'     { Add-GameManually }
        'Boost'       { Start-BoostSession $Config -NoWait:$NoWait }
        'Preview'     { Start-BoostSession $Config -Preview }
        'Restore'     { Restore-BoostSession }
        'AutoScanOn'  { Enable-AutoScan $Root }
        'AutoScanOff' { Disable-AutoScan }
        'Undo'        { Invoke-Undo }
    }
}

# ---------------- One action, then exit ----------------
if ($Action -ne 'Menu') {
    try { Invoke-GBAction $Action }
    catch { Out-Bad "Something went wrong: $($_.Exception.Message)"; Write-GBLog $_.ScriptStackTrace }
    if ($PauseAtEnd -and -not $Quiet) { Write-Host ''; [void](Read-Host 'Press Enter to close') }
    exit
}

# ---------------- Menu ----------------
if (Test-Path $script:SessionFile) {
    Out-Warn 'A Boost session was not ended (the window was closed or the PC restarted).'
    $a = Read-Host '  Restore everything now? [Y/N]'
    if ($a -match '^[Yy]') { Restore-BoostSession }
}

while ($true) {
    $boosting = Test-Path $script:SessionFile
    $auto = Test-AutoScan
    Write-Host ''
    Write-Host '==============================================' -ForegroundColor Cyan
    Write-Host "   GAMEBOOST $($script:GBVersion)  -  safe gaming optimizer" -ForegroundColor Cyan
    Write-Host '==============================================' -ForegroundColor Cyan
    Write-Host '  [1] Check my PC for FPS problems   (changes nothing)'
    Write-Host '  [2] Optimize Windows for gaming     (one time)'
    Write-Host '  [3] Find my games & use the fast GPU'
    if ($boosting) {
        Write-Host '  [4] END BOOST and restore everything' -ForegroundColor Green
    } else {
        Write-Host '  [4] BOOST - start a gaming session' -ForegroundColor Green
    }
    Write-Host '  [5] Preview what Boost would do'
    Write-Host '  [6] Add a game manually'
    if ($auto) { Write-Host '  [7] Auto-setup new games at login: ON  (press 7 to turn off)' }
    else       { Write-Host '  [7] Auto-setup new games at login: OFF (press 7 to turn on)' }
    Write-Host '  [8] Undo all GameBoost changes'
    Write-Host '  [Q] Quit'
    $choice = Read-Host 'Choose'
    try {
        switch -Regex ($choice) {
            '^1$'    { Invoke-GBAction 'Check' }
            '^2$'    { Invoke-GBAction 'Tune' }
            '^3$'    { Invoke-GBAction 'Scan' }
            '^4$'    { if ($boosting) { Invoke-GBAction 'Restore' } else { Invoke-GBAction 'Boost' } }
            '^5$'    { Invoke-GBAction 'Preview' }
            '^6$'    { Invoke-GBAction 'AddGame' }
            '^7$'    { if ($auto) { Invoke-GBAction 'AutoScanOff' } else { Invoke-GBAction 'AutoScanOn' } }
            '^8$'    {
                $c = Read-Host 'This reverses every setting GameBoost changed. Continue? [Y/N]'
                if ($c -match '^[Yy]') { Invoke-GBAction 'Undo' }
            }
            '^[Qq]$' { exit }
            default  { Out-Warn 'Type a number from 1 to 8, or Q.' }
        }
    } catch {
        Out-Bad "Something went wrong: $($_.Exception.Message)"
        Write-GBLog $_.ScriptStackTrace
    }
}
