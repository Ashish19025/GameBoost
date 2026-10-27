# GameBoost - finds installed games in every launcher and tells Windows to run them
# on the dedicated (fast) GPU instead of the integrated one.

function Get-SteamCommonFolders {
    $libs = New-Object System.Collections.ArrayList
    $steam = Get-RegValue 'HKCU\Software\Valve\Steam' 'SteamPath'
    if (-not $steam) { $steam = Get-RegValue 'HKLM\SOFTWARE\WOW6432Node\Valve\Steam' 'InstallPath' }
    if ($steam) {
        $steam = $steam -replace '/', '\'
        [void]$libs.Add($steam)
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            $text = Get-Content -LiteralPath $vdf -Raw
            foreach ($m in [regex]::Matches($text, '"path"\s+"([^"]+)"')) {
                [void]$libs.Add(($m.Groups[1].Value -replace '\\\\', '\'))
            }
        }
    }
    $out = @()
    foreach ($l in $libs) {
        $c = Join-Path $l 'steamapps\common'
        if (Test-Path -LiteralPath $c) { $out += $c }
    }
    return $out
}

# Returns one object per installed game: Name, Path, Source
function Get-InstalledGames($Config) {
    $games = @{}   # path (lowercase) -> object
    $add = {
        param($name, $path, $source)
        if (-not $path) { return }
        $path = ($path -replace '/', '\').TrimEnd('\')
        if (-not (Test-Path -LiteralPath $path)) { return }
        $key = $path.ToLowerInvariant()
        if (-not $games.ContainsKey($key)) { $games[$key] = [pscustomobject]@{ Name = $name; Path = $path; Source = $source } }
    }
    $skipFolders = '^(Steamworks Shared|Steam Controller Configs|SteamVR|DirectX|Redist|_CommonRedist|CommonRedist)$'

    # A "library" folder holds one sub-folder per game
    $libraries = New-Object System.Collections.ArrayList
    foreach ($c in (Get-SteamCommonFolders)) { [void]$libraries.Add(@($c, 'Steam')) }

    $drives = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue | ForEach-Object { $_.DeviceID + '\' })
    $common = @(
        @('SteamLibrary\steamapps\common', 'Steam'),
        @('Program Files\Epic Games', 'Epic'),
        @('Epic Games', 'Epic'),
        @('Program Files (x86)\Ubisoft\Ubisoft Game Launcher\games', 'Ubisoft'),
        @('Program Files\EA Games', 'EA'),
        @('Program Files (x86)\Origin Games', 'EA'),
        @('Program Files (x86)\GOG Galaxy\Games', 'GOG'),
        @('GOG Games', 'GOG'),
        @('XboxGames', 'Xbox'),
        @('Riot Games', 'Riot'),
        @('Games', 'Games folder')
    )
    foreach ($d in $drives) { foreach ($c in $common) { [void]$libraries.Add(@((Join-Path $d $c[0]), $c[1])) } }
    if ($Config.games.extraLibraryFolders) {
        foreach ($f in @($Config.games.extraLibraryFolders)) { if ($f) { [void]$libraries.Add(@([string]$f, 'Your folder')) } }
    }

    foreach ($lib in $libraries) {
        if (-not (Test-Path -LiteralPath $lib[0])) { continue }
        foreach ($dir in (Get-ChildItem -LiteralPath $lib[0] -Directory -ErrorAction SilentlyContinue)) {
            if ($dir.Name -match $skipFolders) { continue }
            & $add $dir.Name $dir.FullName $lib[1]
        }
    }

    # Epic manifests (games installed anywhere)
    $epicDir = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'
    if (Test-Path -LiteralPath $epicDir) {
        foreach ($f in (Get-ChildItem -LiteralPath $epicDir -Filter *.item -ErrorAction SilentlyContinue)) {
            $j = Read-Json $f.FullName
            if ($j -and $j.InstallLocation) { & $add $j.DisplayName $j.InstallLocation 'Epic' }
        }
    }

    # Ubisoft Connect
    $ubi = 'HKLM\SOFTWARE\WOW6432Node\Ubisoft\Launcher\Installs'
    foreach ($id in (Get-RegSubKeyNames $ubi)) {
        $p = Get-RegValue "$ubi\$id" 'InstallDir'
        if ($p) { & $add (Split-Path ($p -replace '/', '\').TrimEnd('\') -Leaf) $p 'Ubisoft' }
    }

    # GOG Galaxy
    $gog = 'HKLM\SOFTWARE\WOW6432Node\GOG.com\Games'
    foreach ($id in (Get-RegSubKeyNames $gog)) {
        $p = Get-RegValue "$gog\$id" 'path'
        if ($p) { & $add (Get-RegValue "$gog\$id" 'gameName') $p 'GOG' }
    }

    # Single game folders the user added by hand
    if ($Config.games.extraGameFolders) {
        foreach ($f in @($Config.games.extraGameFolders)) { if ($f) { & $add (Split-Path ([string]$f) -Leaf) ([string]$f) 'Your folder' } }
    }

    return @($games.Values | Sort-Object Name)
}

function Get-GameExecutables($Game, $Config) {
    $skip = '(?i)(unins|setup|install|redist|vcredist|directx|dxsetup|dotnet|prereq|crash|report|cleanup|touchup|activation|cefprocess|webhelper|helper)'
    if ($Config.games.skipExePattern) { $skip = [string]$Config.games.skipExePattern }
    return @(Get-ChildItem -LiteralPath $Game.Path -Filter *.exe -File -Recurse -Depth 6 -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -notmatch $skip } |
             Select-Object -ExpandProperty FullName)
}

function Test-HasDedicatedGpu {
    $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
    return [bool]($gpus | Where-Object { $_.Name -match 'NVIDIA|Radeon RX|Radeon Pro|Arc\(TM\) A|Arc A\d' })
}

function Invoke-GameScan($Config) {
    Out-Title 'Finding your games'
    $games = Get-InstalledGames $Config
    if ($games.Count -eq 0) {
        Out-Warn 'No games found. Add your game folder to "extraLibraryFolders" in config.json, or use "Add a game manually".'
        return
    }

    $b = Get-TweakBackup
    $newFiles = 0; $userChoice = 0
    try {
        foreach ($g in $games) {
            $exes = Get-GameExecutables $g $Config
            $added = 0
            foreach ($exe in $exes) {
                $cur = Get-RegValue $script:GpuPrefKey $exe
                if ($null -eq $cur) {
                    Set-TrackedReg $b $script:GpuPrefKey $exe 'GpuPreference=2;' 'String'
                    $added++; $newFiles++
                } elseif ($cur -notmatch 'GpuPreference=2') {
                    $userChoice++   # someone set this on purpose - respect it
                }
            }
            $tag = if ($added -gt 0) { "  (+$added new)" } else { '' }
            Out-Info ("{0,-45} {1}{2}" -f $g.Name, $g.Source, $tag)
        }
    } finally {
        Save-TweakBackup $b
    }

    Out-Ok "$($games.Count) games found. $newFiles new game file(s) set to use the dedicated GPU."
    if ($userChoice -gt 0) { Out-Info "$userChoice file(s) already had a different GPU choice set by you - left as they were." }
    if (-not (Test-HasDedicatedGpu)) { Out-Info 'Note: no dedicated GPU detected, so this has no effect on this PC (that is fine).' }
}

function Add-GameManually {
    Out-Title 'Add a game manually'
    Out-Line "Pick the game's main .exe (in its install folder). A file window is opening - it may be behind this one." 'Cyan'
    $exe = Select-ExeFile
    if (-not $exe) { Out-Warn 'Nothing picked.'; return }
    $b = Get-TweakBackup
    try { Set-TrackedReg $b $script:GpuPrefKey $exe 'GpuPreference=2;' 'String' } finally { Save-TweakBackup $b }
    Out-Ok "$(Split-Path $exe -Leaf) will use the dedicated GPU."
}

# ---------------- Auto-scan new games at every login ----------------
function Enable-AutoScan([string]$Root) {
    $script = Join-Path $Root 'GameBoost.ps1'
    $user   = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`" -Action Scan -Quiet"
    $trigger  = New-ScheduledTaskTrigger -AtLogOn -User $user
    $trigger.Delay = 'PT2M'   # wait 2 minutes after login so it doesn't slow startup
    $princ    = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
    Register-ScheduledTask -TaskName $script:AutoScanTask -Action $action -Trigger $trigger -Principal $princ -Settings $settings -Description 'GameBoost: set newly installed games to use the dedicated GPU' -Force | Out-Null

    $b = Get-TweakBackup; $b.AutoScanTask = $true; Save-TweakBackup $b
    Out-Ok 'Auto-scan ON: every new game you install is set up automatically at your next login.'
    Out-Info "Keep the GameBoost folder where it is ($Root) - the task runs the script from there."
}

function Disable-AutoScan {
    Unregister-ScheduledTask -TaskName $script:AutoScanTask -Confirm:$false -ErrorAction SilentlyContinue
    $b = Get-TweakBackup; $b.AutoScanTask = $false; Save-TweakBackup $b
    Out-Ok 'Auto-scan OFF.'
}

function Test-AutoScan {
    return [bool](Get-ScheduledTask -TaskName $script:AutoScanTask -ErrorAction SilentlyContinue)
}
