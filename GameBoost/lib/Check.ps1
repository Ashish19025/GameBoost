# GameBoost - read-only PC check. Changes nothing; tells you what is holding FPS back.

function Convert-NvidiaVersion([string]$WinVersion) {
    # Windows shows e.g. 31.0.15.5222 ; NVIDIA calls that 552.22
    $digits = $WinVersion -replace '\.', ''
    if ($digits.Length -lt 5) { return $WinVersion }
    $last5 = $digits.Substring($digits.Length - 5)
    return '{0}.{1}' -f $last5.Substring(0, 3), $last5.Substring(3)
}

function Invoke-Check {
    Out-Title 'PC check (read-only - nothing is changed)'
    $fixes = New-Object System.Collections.ArrayList

    # --- Laptop / charger
    $isLaptop = [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
    if ($isLaptop) {
        $online = $null
        try { $online = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStatus -ErrorAction Stop | Select-Object -First 1).PowerOnline } catch {}
        if ($online -eq $false) {
            Out-Bad 'Running on battery - laptop GPUs are heavily throttled on battery.'
            [void]$fixes.Add('Plug in the charger while gaming.')
        } else { Out-Ok 'Laptop is on the charger' }
        [void]$fixes.Add("Open your laptop maker's app (Armoury Crate, Lenovo Vantage, Omen Gaming Hub, NitroSense...) and pick Turbo/Performance mode. If it has a 'dGPU only' / 'MUX switch' option, turn it on.")
    }

    # --- GPUs
    $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
    $dgpu = $gpus | Where-Object { $_.Name -match 'NVIDIA|Radeon RX|Radeon Pro|Arc\(TM\) A|Arc A\d' } | Select-Object -First 1
    foreach ($g in $gpus) {
        $ver = $g.DriverVersion
        if ($g.Name -match 'NVIDIA') { $ver = Convert-NvidiaVersion $g.DriverVersion }
        $date = ''
        if ($g.DriverDate) { $date = ' from ' + $g.DriverDate.ToString('MMM yyyy') }
        Out-Ok "GPU: $($g.Name)  (driver $ver$date)"
        if ($g.DriverDate -and $g.DriverDate -lt (Get-Date).AddMonths(-6) -and $g -eq $dgpu) {
            Out-Warn '     That driver is more than 6 months old.'
            [void]$fixes.Add('Update your graphics driver (NVIDIA app / AMD Adrenalin / Intel Arc Control). New games often need new drivers.')
        }
    }
    if (-not $dgpu) {
        Out-Warn 'No dedicated gaming GPU detected (or its driver is missing).'
        [void]$fixes.Add('If your PC has an NVIDIA/AMD GPU, install its driver from the maker''s website.')
    } elseif ($gpus.Count -ge 2) {
        Out-Info 'Two GPUs (hybrid graphics). GameBoost makes games use the fast one.'
    }

    # --- CPU
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cpu) { Out-Ok ("CPU: {0} ({1} cores / {2} threads)" -f $cpu.Name.Trim(), $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors) }

    # --- RAM
    $sticks = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
    if ($sticks.Count -gt 0) {
        $totalGB = [math]::Round((($sticks | Measure-Object Capacity -Sum).Sum) / 1GB)
        $speed = ($sticks | Select-Object -First 1).ConfiguredClockSpeed
        Out-Ok "RAM: $totalGB GB in $($sticks.Count) stick(s) at $speed MT/s"
        if ($totalGB -lt 16) {
            Out-Warn '     Most new games want 16 GB.'
            [void]$fixes.Add('Upgrade to 16 GB RAM (2 x 8 GB). This is often the cheapest big FPS win.')
        }
        if ($sticks.Count -eq 1) {
            Out-Warn '     Single stick = single-channel memory. This can cost 15-30% FPS, especially on laptops.'
            [void]$fixes.Add('Add a matching second RAM stick for dual-channel memory.')
        }
    }

    # --- Disks
    try {
        foreach ($pd in @(Get-PhysicalDisk -ErrorAction Stop)) {
            if ($pd.MediaType -eq 'HDD') {
                Out-Warn "Hard disk (HDD) found: $($pd.FriendlyName). Games on an HDD stutter and load slowly."
                [void]$fixes.Add('Install your games on the SSD, not the HDD.')
            }
        }
    } catch {}
    foreach ($ld in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)) {
        if (-not $ld.Size) { continue }
        $freeGB = [math]::Round($ld.FreeSpace / 1GB)
        $pct = [math]::Round(100 * $ld.FreeSpace / $ld.Size)
        if ($pct -lt 10) {
            Out-Warn "Drive $($ld.DeviceID) is almost full ($freeGB GB free)."
            [void]$fixes.Add("Free up space on $($ld.DeviceID) - keep at least 10-15% free.")
        } else { Out-Ok "Drive $($ld.DeviceID): $freeGB GB free" }
    }

    # --- Windows gaming settings
    $gm  = Get-RegValue 'HKCU\Software\Microsoft\GameBar' 'AutoGameModeEnabled'
    $dvr = Get-RegValue 'HKCU\System\GameConfigStore' 'GameDVR_Enabled'
    $hags = Get-RegValue 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode'
    if ($gm -eq 0) { Out-Warn 'Game Mode is OFF' } else { Out-Ok 'Game Mode is on' }
    if ($dvr -eq 0) { Out-Ok 'Xbox background recording is off' } else { Out-Warn 'Xbox background recording may be on (costs FPS)' }
    if ($hags -eq 2) { Out-Ok 'GPU scheduling is on' } else { Out-Info 'GPU scheduling is off' }
    if ($gm -eq 0 -or $dvr -ne 0 -or $hags -ne 2) { [void]$fixes.Add('Run "Optimize Windows for gaming" in GameBoost.') }

    # --- Startup apps
    $startup = @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue)
    if ($startup.Count -gt 8) {
        Out-Warn "$($startup.Count) apps start with Windows."
        [void]$fixes.Add('Task Manager > Startup apps: disable the ones you do not need at boot.')
    } else { Out-Ok "$($startup.Count) startup apps" }

    # --- Memory hogs right now
    Out-Line ''
    Out-Line 'Using the most memory right now:' 'Cyan'
    if (-not $script:QuietMode) {
        Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 8 `
            @{ n = 'App'; e = { $_.ProcessName } }, @{ n = 'RAM (MB)'; e = { [int]($_.WorkingSet64 / 1MB) } } |
            Format-Table -AutoSize | Out-String | Write-Host
    }

    # --- Summary
    Out-Title 'What to fix first'
    if ($fixes.Count -eq 0) { Out-Ok 'Nothing obvious - your PC is in good shape.' }
    $n = 1
    foreach ($f in ($fixes | Select-Object -Unique)) { Out-Line ("  {0}. {1}" -f $n, $f) 'Yellow'; $n++ }
}
