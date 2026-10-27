# GameBoost - BOOST sessions.
#
# Boost pauses background services and closes background apps ONLY while you play,
# then puts everything back. It is built so it never breaks your work:
#
#   1. It only touches things on a curated list in config.json (never "everything").
#   2. Anything you are using is protected and left alone:
#        - apps with an open window (VS Code, your browser, Discord...)
#        - anything serving on a network port (node/vite/django dev servers, Docker, databases)
#        - anything in your "protect" list in config.json
#        - every child process started by a protected app (e.g. a dev server run
#          from the VS Code terminal)
#   3. Heavy apps you are using are not closed - they get lower CPU priority instead,
#      so they keep working but give way to the game.
#   4. Services are stopped, never disabled. Everything is written to a session file
#      first, so even after a crash or a closed window, Restore puts it all back.

# ---------------- What is protected ----------------
function Get-ProtectionMap($Config) {
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)

    $children = @{}
    foreach ($p in $all) {
        $pp = [int]$p.ParentProcessId
        if (-not $children.ContainsKey($pp)) { $children[$pp] = New-Object System.Collections.ArrayList }
        [void]$children[$pp].Add([int]$p.ProcessId)
    }

    $reason = @{}   # pid -> why it is protected
    $protectNames = @($Config.protect.processes | ForEach-Object { Get-BaseName $_ })
    foreach ($p in $all) {
        if ($protectNames -contains (Get-BaseName $p.Name)) { $reason[[int]$p.ProcessId] = 'in your protect list' }
    }

    $windowed = @{}
    foreach ($gp in (Get-Process -ErrorAction SilentlyContinue)) {
        if ($gp.MainWindowHandle -ne [IntPtr]::Zero) {
            $windowed[[int]$gp.Id] = $true
            if ($Config.protect.windowedApps -and -not $reason.ContainsKey([int]$gp.Id)) { $reason[[int]$gp.Id] = 'has an open window' }
        }
    }

    $ports = @{}    # pid -> listening ports
    if ($Config.protect.listeningPorts) {
        foreach ($c in @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)) {
            $op = [int]$c.OwningProcess
            if ($op -le 4) { continue }
            if (-not $ports.ContainsKey($op)) { $ports[$op] = New-Object System.Collections.ArrayList }
            if (-not $ports[$op].Contains([int]$c.LocalPort)) { [void]$ports[$op].Add([int]$c.LocalPort) }
        }
        foreach ($op in @($ports.Keys)) {
            if (-not $reason.ContainsKey($op)) { $reason[$op] = 'is serving on port ' + ((@($ports[$op]) | Sort-Object) -join ', ') }
        }
    }

    # Children of protected apps are protected too (dev server started from VS Code's terminal, etc.)
    $queue = New-Object System.Collections.Queue
    foreach ($k in @($reason.Keys)) { $queue.Enqueue($k) }
    while ($queue.Count -gt 0) {
        $id = [int]$queue.Dequeue()
        if (-not $children.ContainsKey($id)) { continue }
        foreach ($c in $children[$id]) {
            if (-not $reason.ContainsKey($c)) { $reason[$c] = 'was started by an app you are using'; $queue.Enqueue($c) }
        }
    }

    return [pscustomobject]@{ Reason = $reason; Ports = $ports; Windowed = $windowed; Processes = $all }
}

# ---------------- Work out what Boost would do ----------------
function Get-BoostPlan($Config) {
    $prot = Get-ProtectionMap $Config
    $plan = [pscustomobject]@{
        Power    = [bool]$Config.boost.highPerformancePower
        Services = @(); Apps = @(); Priority = @(); Skipped = @(); Keep = @()
    }

    # Services: pause only running ones from the list, never ones other running services depend on
    foreach ($s in @($Config.boost.pauseServices)) {
        if (-not $s -or -not $s.enabled) { continue }
        $svc = Get-Service -Name $s.name -ErrorAction SilentlyContinue
        if (-not $svc -or $svc.Status -ne 'Running') { continue }
        $deps = @($svc.DependentServices | Where-Object { $_.Status -eq 'Running' })
        if ($deps.Count -gt 0) { $plan.Skipped += "$($svc.DisplayName) (other running services need it)"; continue }
        $plan.Services += [pscustomobject]@{ Name = $svc.Name; Display = $svc.DisplayName; Why = $s.why }
    }

    # Apps: close only listed apps, and only if NO process of that app is protected
    $groups = $prot.Processes | Group-Object { Get-BaseName $_.Name }
    foreach ($a in @($Config.boost.closeApps)) {
        if (-not $a -or -not $a.enabled) { continue }
        $grp = $groups | Where-Object { $_.Name -eq (Get-BaseName $a.name) } | Select-Object -First 1
        if (-not $grp) { continue }
        $pids = @($grp.Group | ForEach-Object { [int]$_.ProcessId })
        $blocker = $pids | Where-Object { $prot.Reason.ContainsKey($_) } | Select-Object -First 1
        if ($blocker) { $plan.Skipped += "$($a.name) ($($prot.Reason[$blocker]))"; continue }
        $exe = ($grp.Group | Where-Object { $_.ExecutablePath } | Select-Object -First 1).ExecutablePath
        $plan.Apps += [pscustomobject]@{
            Name = $a.name; Why = $a.why; Pids = $pids; Path = $exe
            Relaunch = [bool]$a.relaunch; Args = [string]$a.relaunchArgs
        }
    }

    # Priority: heavy apps you keep using get "below normal" CPU priority (they keep running)
    if ($Config.boost.lowerPriority -and $Config.boost.lowerPriority.enabled) {
        $names = @($Config.boost.lowerPriority.processes | ForEach-Object { Get-BaseName $_ })
        foreach ($gp in (Get-Process -ErrorAction SilentlyContinue)) {
            if ($names -notcontains (Get-BaseName $gp.ProcessName)) { continue }
            try { $pc = [string]$gp.PriorityClass; $st = $gp.StartTime.Ticks.ToString() } catch { continue }
            if ($pc -ne 'Normal' -and $pc -ne 'AboveNormal') { continue }
            $plan.Priority += [pscustomobject]@{ Id = $gp.Id; Name = $gp.ProcessName; Old = $pc; Start = $st }
        }
    }

    # Show the user what keeps running (servers, open protected apps), so they can trust it
    $keep = @{}
    foreach ($p in $prot.Processes) {
        $id = [int]$p.ProcessId
        $path = [string]$p.ExecutablePath
        if (-not $path -or $path -like "$env:windir\*") { continue }
        $n = Get-BaseName $p.Name
        if ($prot.Ports.ContainsKey($id)) {
            $keep["$n|ports"] = "$n  (serving on port " + ((@($prot.Ports[$id]) | Sort-Object) -join ', ') + ')'
        } elseif ($prot.Reason[$id] -eq 'in your protect list' -and -not $keep.ContainsKey("$n|ports")) {
            $keep["$n|list"] = "$n  (protected)"
        }
    }
    $plan.Keep = @($keep.Values | Sort-Object -Unique)
    return $plan
}

function Show-BoostPlan($plan) {
    if ($plan.Keep.Count -gt 0) {
        Out-Line ''
        Out-Line 'Keeps running - your work is safe:' 'Cyan'
        foreach ($k in $plan.Keep) { Out-Line "   + $k" 'Green' }
    }
    if ($plan.Skipped.Count -gt 0) {
        Out-Line ''
        Out-Line 'Left alone because they are in use:' 'Cyan'
        foreach ($s in $plan.Skipped) { Out-Line "   = $s" 'DarkGray' }
    }
    Out-Line ''
    Out-Line 'Paused until you finish gaming:' 'Cyan'
    $any = $false
    if ($plan.Power) { Out-Line '   - Power: switch to maximum performance'; $any = $true }
    foreach ($s in $plan.Services) { Out-Line "   - Service: $($s.Display) - $($s.Why)"; $any = $true }
    foreach ($a in $plan.Apps) {
        $back = if ($a.Relaunch) { ' (reopens after)' } else { '' }
        Out-Line "   - Close: $($a.Name) - $($a.Why)$back"; $any = $true
    }
    if ($plan.Priority.Count -gt 0) {
        $names = ($plan.Priority | ForEach-Object { $_.Name } | Sort-Object -Unique) -join ', '
        Out-Line "   - Lower priority (still running): $names"; $any = $true
    }
    if (-not $any) { Out-Line '   (nothing heavy is running - your PC is already lean)' 'DarkGray' }
}

# ---------------- Power ----------------
function Set-BoostPower($state) {
    $state.PowerScheme = Get-ActiveScheme
    if ($state.PowerScheme -ne $script:HighPerf) {
        powercfg /setactive $script:HighPerf 2>$null | Out-Null
    }
    if ((Get-ActiveScheme) -eq $script:HighPerf) { Out-Ok 'Power: High Performance plan'; return }

    # Newer laptops hide the High Performance plan; use the "Best performance" power mode instead
    try {
        Initialize-GBPower
        $g = [Guid]::Empty
        if ([GBPower]::PowerGetEffectiveOverlayScheme([ref]$g) -eq 0) {
            $state.Overlay = $g.ToString()
            if ([GBPower]::PowerSetActiveOverlayScheme([Guid]$script:BestPerfOverlay) -eq 0) { Out-Ok 'Power: Best performance mode'; return }
        }
    } catch {}
    Out-Warn 'Could not switch power mode. Set it by hand: Settings > System > Power > Power mode > Best performance.'
}

# ---------------- Start / end a session ----------------
function Start-BoostSession($Config, [switch]$Preview, [switch]$NoWait) {
    if ((Test-Path $script:SessionFile) -and -not $Preview) {
        Out-Warn 'A boost is already active.'
        if (-not $NoWait) {
            $a = Read-Host '  End it and restore everything now? [Y/N]'
            if ($a -match '^[Yy]') { Restore-BoostSession }
        }
        return
    }

    if ($Preview) { Out-Title 'BOOST preview - nothing will be changed' } else { Out-Title 'BOOST - getting your PC ready to game' }
    $plan = Get-BoostPlan $Config
    Show-BoostPlan $plan
    if ($Preview) {
        Out-Line ''
        Out-Line 'Preview only. Edit config.json to change what Boost touches or protects.' 'Green'
        return
    }

    Out-Line ''
    $state = [pscustomobject]@{
        Version = $script:GBVersion; Started = (Get-Date).ToString('s')
        PowerScheme = $null; Overlay = $null; Services = @(); Apps = @(); Priority = @()
    }
    Save-Json $script:SessionFile $state     # written first, so a crash can always be restored

    if ($plan.Power) { Set-BoostPower $state; Save-Json $script:SessionFile $state }

    foreach ($s in $plan.Services) {
        try {
            Stop-Service -Name $s.Name -NoWait -ErrorAction Stop -WarningAction SilentlyContinue
            $state.Services += $s.Name
            Out-Ok "Paused service: $($s.Display)"
        } catch { Out-Info "Windows would not pause $($s.Display) - skipped." }
    }
    Save-Json $script:SessionFile $state

    foreach ($a in $plan.Apps) {
        $closed = $false
        foreach ($id in $a.Pids) {
            if (Get-Process -Id $id -ErrorAction SilentlyContinue) {
                try { Stop-Process -Id $id -Force -ErrorAction Stop; $closed = $true } catch {}
            } else { $closed = $true }
        }
        if ($closed) {
            $state.Apps += [pscustomobject]@{ Name = $a.Name; Path = $a.Path; Relaunch = $a.Relaunch; Args = $a.Args }
            Out-Ok "Closed: $($a.Name)"
        }
    }
    Save-Json $script:SessionFile $state

    $lowered = 0
    foreach ($p in $plan.Priority) {
        try {
            $gp = Get-Process -Id $p.Id -ErrorAction Stop
            $gp.PriorityClass = 'BelowNormal'
            $state.Priority += $p
            $lowered++
        } catch {}
    }
    if ($lowered -gt 0) { Out-Ok "Lowered priority of $lowered background process(es) - they keep running, the game just comes first" }
    Save-Json $script:SessionFile $state

    Out-Line ''
    Out-Line '>>> BOOST IS ON. Go play! <<<' 'Green'
    if ($NoWait) {
        Out-Line 'When you are done, run Restore (menu option or -Action Restore) to put everything back.' 'Gray'
        return
    }
    Out-Line 'Keep this window open (minimize it). When you finish gaming, come back here and press Enter.' 'Gray'
    Out-Line 'If you close it by accident, open GameBoost again - it will offer to restore.' 'DarkGray'
    [void](Read-Host 'Press Enter when you are done gaming')
    Restore-BoostSession
}

function Restore-BoostSession {
    $s = Read-Json $script:SessionFile
    if (-not $s) { Out-Warn 'No boost is active - nothing to restore.'; return }
    Out-Title 'Ending boost - putting everything back'

    # Power
    if ($s.PowerScheme) { powercfg /setactive $s.PowerScheme 2>$null | Out-Null }
    if ($s.Overlay) {
        try { Initialize-GBPower; [void][GBPower]::PowerSetActiveOverlayScheme([Guid]$s.Overlay) } catch {}
    }
    if ($s.PowerScheme -or $s.Overlay) { Out-Ok 'Power plan restored' }

    # Services
    foreach ($name in @($s.Services)) {
        if (-not $name) { continue }
        try {
            $svc = Get-Service -Name $name -ErrorAction Stop
            if ($svc.Status -eq 'StopPending') { $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30)) }
            if ($svc.Status -ne 'Running') { Start-Service -Name $name -ErrorAction Stop -WarningAction SilentlyContinue }
            Out-Ok "Resumed service: $($svc.DisplayName)"
        } catch { Out-Warn "Could not restart service $name - it will start again on reboot." }
    }

    # Apps
    foreach ($a in @($s.Apps)) {
        if (-not $a -or -not $a.Relaunch) { continue }
        if ($a.Path -and (Start-AsUser $a.Path $a.Args)) { Out-Ok "Reopened: $($a.Name)" }
        else { Out-Warn "Could not reopen $($a.Name) - open it yourself or it will start on next login." }
    }

    # Priorities (only if it is still the same process, not a new one that reused the id)
    $restored = 0
    foreach ($p in @($s.Priority)) {
        if (-not $p) { continue }
        try {
            $gp = Get-Process -Id ([int]$p.Id) -ErrorAction Stop
            if ($gp.StartTime.Ticks.ToString() -eq [string]$p.Start) { $gp.PriorityClass = [string]$p.Old; $restored++ }
        } catch {}
    }
    if ($restored -gt 0) { Out-Ok "Priority restored for $restored process(es)" }

    Remove-Item $script:SessionFile -Force -ErrorAction SilentlyContinue
    Out-Line ''
    Out-Line 'Everything is back to normal.' 'Green'
}
