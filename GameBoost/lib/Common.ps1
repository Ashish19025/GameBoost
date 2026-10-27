# GameBoost - shared helpers: output, state files, registry tracking, config.
# Every registry change goes through Set-TrackedReg, which remembers the original
# value the first time it is touched, so Invoke-Undo can always put it back.

$script:GBVersion       = '1.0.0'
$script:StateDir        = Join-Path $env:LOCALAPPDATA 'GameBoost'
$script:TweakFile       = Join-Path $script:StateDir 'tweaks-backup.json'
$script:SessionFile     = Join-Path $script:StateDir 'session.json'
$script:LogFile         = Join-Path $script:StateDir 'gameboost.log'
$script:GuidRx          = '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'
$script:HighPerf        = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$script:BestPerfOverlay = 'ded574b5-45a0-4f42-8737-46345c09c238'
$script:GpuPrefKey      = 'HKCU\Software\Microsoft\DirectX\UserGpuPreferences'
$script:AutoScanTask    = 'GameBoost AutoScan'
$script:QuietMode       = $false

# ---------------- Output ----------------
function Write-GBLog([string]$Message) {
    try {
        if (-not (Test-Path $script:StateDir)) { New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null }
        if ((Test-Path $script:LogFile) -and ((Get-Item $script:LogFile).Length -gt 1MB)) { Remove-Item $script:LogFile -Force }
        Add-Content -Path $script:LogFile -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message)
    } catch {}
}
function Out-Title([string]$t) { Write-GBLog "---- $t"; if (-not $script:QuietMode) { Write-Host ''; Write-Host "=== $t ===" -ForegroundColor Cyan } }
function Out-Ok([string]$t)    { Write-GBLog "OK    $t"; if (-not $script:QuietMode) { Write-Host "  [OK]  $t" -ForegroundColor Green } }
function Out-Warn([string]$t)  { Write-GBLog "WARN  $t"; if (-not $script:QuietMode) { Write-Host "  [!]   $t" -ForegroundColor Yellow } }
function Out-Bad([string]$t)   { Write-GBLog "BAD   $t"; if (-not $script:QuietMode) { Write-Host "  [X]   $t" -ForegroundColor Red } }
function Out-Info([string]$t)  { if (-not $script:QuietMode) { Write-Host "        $t" -ForegroundColor DarkGray } }
function Out-Line([string]$t, [string]$Color = 'Gray') { if (-not $script:QuietMode) { Write-Host $t -ForegroundColor $Color } }

# ---------------- Basics ----------------
function Test-IsAdmin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-BaseName([string]$Name) {
    if (-not $Name) { return '' }
    return ($Name -replace '\.exe$', '').ToLowerInvariant()
}

function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) } catch { return $null }
}

function Save-Json([string]$Path, $Object) {
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $Object | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-GBConfig([string]$Root) {
    $path = Join-Path $Root 'config.json'
    if (-not (Test-Path -LiteralPath $path)) { throw "config.json not found in $Root" }
    try { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) }
    catch { throw "config.json has a mistake in it (check commas and quotes): $($_.Exception.Message)" }
}

# ---------------- Registry (via .NET: safe with any path, even ones with [ ] in them) ----------------
function Open-RegKey([string]$Path, [bool]$Write) {
    $i    = $Path.IndexOf('\')
    $hive = $Path.Substring(0, $i)
    $sub  = $Path.Substring($i + 1)
    $root = if ($hive -eq 'HKCU') { [Microsoft.Win32.Registry]::CurrentUser } else { [Microsoft.Win32.Registry]::LocalMachine }
    if ($Write) { return $root.CreateSubKey($sub) }
    return $root.OpenSubKey($sub)
}

function Get-RegValue([string]$Path, [string]$Name) {
    $k = $null
    try {
        $k = Open-RegKey $Path $false
        if (-not $k) { return $null }
        return $k.GetValue($Name, $null)
    } catch { return $null } finally { if ($k) { $k.Close() } }
}

function Get-RegSubKeyNames([string]$Path) {
    $k = $null
    try {
        $k = Open-RegKey $Path $false
        if (-not $k) { return @() }
        return @($k.GetSubKeyNames())
    } catch { return @() } finally { if ($k) { $k.Close() } }
}

# ---------------- Tweak backup (permanent changes, reversed by Undo) ----------------
function Get-TweakBackup {
    $b = [pscustomobject]@{ Registry = New-Object System.Collections.ArrayList; AutoScanTask = $false }
    $d = Read-Json $script:TweakFile
    if ($d) {
        if ($d.Registry) { foreach ($r in @($d.Registry)) { if ($r) { [void]$b.Registry.Add($r) } } }
        if ($d.AutoScanTask) { $b.AutoScanTask = $true }
    }
    return $b
}

function Save-TweakBackup($b) {
    Save-Json $script:TweakFile ([pscustomobject]@{
        Version      = $script:GBVersion
        Registry     = @($b.Registry)
        AutoScanTask = [bool]$b.AutoScanTask
    })
}

# Sets a registry value and remembers what was there before (only the first time).
function Set-TrackedReg($b, [string]$Path, [string]$Name, $Value, [string]$Type) {
    $already = $b.Registry | Where-Object { $_.Path -eq $Path -and $_.Name -eq $Name } | Select-Object -First 1
    if (-not $already) {
        $existed = $false; $old = $null
        $k = Open-RegKey $Path $false
        if ($k) {
            if ($k.GetValueNames() -contains $Name) { $existed = $true; $old = $k.GetValue($Name, $null, 'DoNotExpandEnvironmentNames') }
            $k.Close()
        }
        [void]$b.Registry.Add([pscustomobject]@{ Path = $Path; Name = $Name; Existed = $existed; Old = $old; Type = $Type })
    }
    if ($Type -eq 'DWord') { $Value = [int]$Value } else { $Value = [string]$Value }
    $k = Open-RegKey $Path $true
    try { $k.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]$Type) } finally { $k.Close() }
}

# Merges "key=value;" into a semicolon-separated DirectX settings string without dropping other flags.
function Set-DxGlobalSetting($b, [string]$Key, [string]$Value) {
    $name = 'DirectXUserGlobalSettings'
    $cur  = Get-RegValue $script:GpuPrefKey $name
    $pairs = [ordered]@{}
    if ($cur) {
        foreach ($kv in ($cur -split ';')) { if ($kv -match '^\s*([^=]+)=(.*)$') { $pairs[$Matches[1].Trim()] = $Matches[2] } }
    }
    $pairs[$Key] = $Value
    $new = (($pairs.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';') + ';'
    Set-TrackedReg $b $script:GpuPrefKey $name $new 'String'
}

# ---------------- Power plan ----------------
function Get-ActiveScheme {
    $out = powercfg /getactivescheme 2>$null | Out-String
    if ($out -match $script:GuidRx) { return $Matches[1] }
    return $null
}

function Initialize-GBPower {
    if (-not ('GBPower' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class GBPower {
    [DllImport("powrprof.dll")] public static extern uint PowerGetEffectiveOverlayScheme(out Guid overlay);
    [DllImport("powrprof.dll")] public static extern uint PowerSetActiveOverlayScheme(Guid overlay);
}
'@
    }
}

# ---------------- Misc ----------------
function Select-ExeFile([string]$Title = "Pick the game's .exe file") {
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title  = $Title
    $dlg.Filter = 'Programs (*.exe)|*.exe'
    $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }
    try { $result = $dlg.ShowDialog($owner) } finally { $owner.Dispose() }
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.FileName }
    return $null
}

# Starts a program as the normal (non-admin) user, even when GameBoost runs as admin.
# Apps like OneDrive refuse to run elevated, so relaunching them directly would fail.
function Start-AsUser([string]$Path, [string]$Arguments) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    if (-not (Test-IsAdmin)) {
        if ($Arguments) { Start-Process -FilePath $Path -ArgumentList $Arguments } else { Start-Process -FilePath $Path }
        return $true
    }
    $name = 'GameBoost-Relaunch-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    try {
        $cmdArgs  = '/c start "" "' + $Path + '"'
        if ($Arguments) { $cmdArgs += ' ' + $Arguments }
        $action   = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument $cmdArgs
        $user     = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $princ    = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $name -Action $action -Principal $princ -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $name
        Start-Sleep -Seconds 3
        return $true
    } catch {
        return $false
    } finally {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    }
}
