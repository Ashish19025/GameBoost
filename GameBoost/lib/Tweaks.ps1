# GameBoost - one-time Windows tweaks for gaming, and the Undo that reverses them.

function Invoke-Tune($Config) {
    Out-Title 'One-time Windows gaming tune-up'

    try {
        Checkpoint-Computer -Description 'Before GameBoost' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningAction SilentlyContinue
        Out-Ok 'Windows restore point created (extra safety net)'
    } catch {
        Out-Warn "Couldn't create a restore point (System Protection is off, or one was made in the last 24h). Undo still works."
    }

    $b = Get-TweakBackup
    try {
        Set-TrackedReg $b 'HKCU\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1 'DWord'
        Set-TrackedReg $b 'HKCU\Software\Microsoft\GameBar' 'AllowAutoGameMode'   1 'DWord'
        Out-Ok 'Game Mode ON - Windows gives the game priority and pauses updates while you play'

        Set-TrackedReg $b 'HKCU\System\GameConfigStore' 'GameDVR_Enabled' 0 'DWord'
        Set-TrackedReg $b 'HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0 'DWord'
        Out-Ok 'Xbox background recording OFF - it records constantly and costs FPS'

        Set-TrackedReg $b 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2 'DWord'
        Out-Ok 'Hardware-accelerated GPU scheduling ON (takes effect after restart)'

        Set-DxGlobalSetting $b 'SwapEffectUpgradeEnable' '1'
        Out-Ok 'Optimizations for windowed games ON - lower latency in borderless/windowed mode (Windows 11)'

        $mm = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
        Set-TrackedReg $b $mm 'SystemResponsiveness' 10 'DWord'
        Set-TrackedReg $b "$mm\Tasks\Games" 'GPU Priority' 8 'DWord'
        Set-TrackedReg $b "$mm\Tasks\Games" 'Priority' 6 'DWord'
        Set-TrackedReg $b "$mm\Tasks\Games" 'Scheduling Category' 'High' 'String'
        Set-TrackedReg $b "$mm\Tasks\Games" 'SFIO Priority' 'High' 'String'
        Out-Ok 'Windows multimedia scheduler now favors games over background tasks'
    } finally {
        Save-TweakBackup $b
    }

    Invoke-GameScan $Config

    Out-Line ''
    Out-Line 'Done. RESTART your PC so every change takes effect.' 'Green'
    Out-Line 'Before each gaming session, use BOOST to pause background stuff (and restore it after).' 'Green'
}

function Invoke-Undo {
    Out-Title 'Undo all GameBoost changes'

    if (Test-Path $script:SessionFile) { Restore-BoostSession }

    $b = Get-TweakBackup
    if ($b.Registry.Count -eq 0 -and -not $b.AutoScanTask) {
        Out-Warn 'Nothing to undo - GameBoost has not changed any settings.'
        if (Test-Path $script:TweakFile) { Remove-Item $script:TweakFile -Force }
        return
    }

    $failed = New-Object System.Collections.ArrayList
    $done = 0
    foreach ($e in $b.Registry) {
        try {
            $k = Open-RegKey $e.Path $true
            try {
                if ($e.Existed) {
                    $val = if ($e.Type -eq 'DWord') { [int]$e.Old } else { [string]$e.Old }
                    $k.SetValue($e.Name, $val, [Microsoft.Win32.RegistryValueKind]$e.Type)
                } else {
                    $k.DeleteValue($e.Name, $false)
                }
            } finally { $k.Close() }
            $done++
        } catch {
            [void]$failed.Add($e)
            Out-Warn "Couldn't restore $($e.Path)\$($e.Name): $($_.Exception.Message)"
        }
    }

    if ($b.AutoScanTask) {
        Unregister-ScheduledTask -TaskName $script:AutoScanTask -Confirm:$false -ErrorAction SilentlyContinue
        Out-Ok 'Auto-scan at login removed'
    }

    if ($failed.Count -gt 0) {
        $b.Registry = $failed; $b.AutoScanTask = $false
        Save-TweakBackup $b
        Out-Warn "$($failed.Count) setting(s) could not be restored. Run Undo again as administrator."
    } else {
        Remove-Item $script:TweakFile -Force
    }
    Out-Ok "$done setting(s) put back to how they were. Restart your PC to finish."
}
