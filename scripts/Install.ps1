#Requires -Version 5.1
<#
  RTSS Launcher installer.
  - Builds RTSSLauncher.exe (windowless) from source with the C# compiler built into Windows
  - Creates two on-demand scheduled tasks so RTSS can be started/stopped elevated with no UAC prompt
  - Writes the frame limits from config.ini into RTSS's per-game profiles
  Safe to run again at any time (update, new machine, new games, RTSS moved).
#>
param(
    [string]$InstallDir = (Join-Path $env:ProgramFiles 'RTSS Launcher'),
    [string]$RunAsUser
)

$ErrorActionPreference = 'Stop'
$PackageDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$TaskPath   = '\RTSSLauncher\'

# ---------------------------------------------------------------- elevate (once)
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin   = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $RunAsUser) { $RunAsUser = $identity.Name }   # the account you game on, captured before elevation

if (-not $isAdmin) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
                 '-InstallDir', "`"$InstallDir`"", '-RunAsUser', "`"$RunAsUser`"")
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList $argList }
    catch { Write-Host 'Admin rights are needed to install. Nothing was changed.' -ForegroundColor Yellow; Read-Host 'Press Enter to close' }
    exit
}

function Step($text) { Write-Host "`n> $text" -ForegroundColor Cyan }
function Ok($text)   { Write-Host "  $text" -ForegroundColor Green }
function Info($text) { Write-Host "  $text" }

. (Join-Path $PSScriptRoot 'Steam.ps1')

function Read-Numbers([string]$Text, [int]$Max) {
    $nums = New-Object 'System.Collections.Generic.List[int]'
    foreach ($t in ($Text -split '[\s,;]+')) {
        $n = 0
        if ([int]::TryParse($t, [ref]$n) -and $n -ge 1 -and $n -le $Max -and -not $nums.Contains($n)) { $nums.Add($n) }
    }
    return ,$nums
}

# ---------------------------------------------------------------- ini helpers
function Read-Ini([string]$Path) {
    $result = @{}; $section = ''
    foreach ($raw in [IO.File]::ReadAllLines($Path)) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith(';') -or $line.StartsWith('#')) { continue }
        if ($line -match '^\[(.+)\]$') {
            $section = $Matches[1].Trim()
            if (-not $result.ContainsKey($section)) { $result[$section] = [ordered]@{} }
            continue
        }
        $kv = $line.Split('=', 2)
        if ($kv.Count -eq 2 -and $section) { $result[$section][$kv[0].Trim()] = $kv[1].Trim() }
    }
    return $result
}

# Sets Key=Value inside [Section], preserving everything else in the file.
function Set-IniValue([string]$Path, [string]$Section, [string]$Key, [string]$Value) {
    $enc   = [Text.Encoding]::Default
    $lines = New-Object 'System.Collections.Generic.List[string]'
    if (Test-Path -LiteralPath $Path) { $lines.AddRange([string[]][IO.File]::ReadAllLines($Path, $enc)) }

    $inSection = $false; $sectionAt = -1; $sectionEnd = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $t = $lines[$i].Trim()
        if ($t -match '^\[(.+)\]$') {
            if ($inSection) { $sectionEnd = $i; break }
            $inSection = ($Matches[1].Trim() -eq $Section)
            if ($inSection) { $sectionAt = $i }
            continue
        }
        if ($inSection -and $t -match ('^' + [regex]::Escape($Key) + '\s*=')) {
            $lines[$i] = "$Key=$Value"
            [IO.File]::WriteAllLines($Path, $lines, $enc)
            return
        }
    }

    if ($sectionAt -lt 0) {
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Trim()) { $lines.Add('') }
        $lines.Add("[$Section]")
        $lines.Add("$Key=$Value")
    } else {
        if ($sectionEnd -lt 0) { $sectionEnd = $lines.Count }
        while ($sectionEnd -gt $sectionAt + 1 -and -not $lines[$sectionEnd - 1].Trim()) { $sectionEnd-- }
        $lines.Insert($sectionEnd, "$Key=$Value")
    }
    [IO.File]::WriteAllLines($Path, $lines, $enc)
}

# ---------------------------------------------------------------- RTSS discovery
function Find-RTSS([string]$Configured) {
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    if ($Configured -and $Configured -ne 'auto') { $candidates.Add($Configured) }

    foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\Unwinder\RTSS', 'HKLM:\SOFTWARE\Unwinder\RTSS',
                     'HKCU:\SOFTWARE\Unwinder\RTSS') {
        $p = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if ($p) { foreach ($name in 'InstallDir', 'InstallPath', 'Path') { if ($p.$name) { $candidates.Add([string]$p.$name) } } }
    }

    $uninstallRoots = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                      'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    foreach ($root in $uninstallRoots) {
        Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($p.DisplayName -like 'RivaTuner Statistics Server*') {
                if ($p.InstallLocation) { $candidates.Add([string]$p.InstallLocation) }
                if ($p.UninstallString) { $candidates.Add((Split-Path -Parent ($p.UninstallString.Trim('"').Split('"')[0]))) }
            }
        }
    }

    $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'RivaTuner Statistics Server'))
    $candidates.Add((Join-Path $env:ProgramFiles 'RivaTuner Statistics Server'))

    foreach ($c in $candidates) {
        if (-not $c) { continue }
        $dir = if ($c -like '*.exe') { Split-Path -Parent $c } else { $c }
        if (Test-Path -LiteralPath (Join-Path $dir 'RTSS.exe')) { return (Resolve-Path -LiteralPath $dir).Path }
    }

    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Could not find RivaTuner Statistics Server. Select the folder that contains RTSS.exe.'
    if ($dlg.ShowDialog() -eq 'OK' -and (Test-Path -LiteralPath (Join-Path $dlg.SelectedPath 'RTSS.exe'))) { return $dlg.SelectedPath }
    throw 'RTSS.exe not found. Install RivaTuner Statistics Server, or set [RTSS] Path in config.ini.'
}

# ---------------------------------------------------------------- Steam launch options (opt-in)
# Returns $true if launch options were written for at least one game.
function Invoke-SteamLaunchOptionSetup([string]$LauncherExe, [string[]]$ExeNames) {
    Step 'Steam launch options'
    $steamDir = Find-SteamDir
    if (-not $steamDir) { Info 'Steam not found. Add the launch option by hand (see below).'; return $false }
    $answer = Read-Host '  Add the launch option to your Steam games for you? [Y/n]'
    if ($answer -match '^\s*n') { return $false }

    Info 'Looking for installed games...'
    $games    = Get-SteamGames $steamDir
    $found    = if ($ExeNames) { Find-SteamGamesByExe $games $ExeNames } else { @() }
    $selected = [ordered]@{}                                  # AppId -> game

    if ($found.Count) {
        Info 'Installed games with settings in config.ini:'
        for ($i = 0; $i -lt $found.Count; $i++) {
            Info ('  {0,2}. {1}  ({2})' -f ($i + 1), $found[$i].Game.Name, ($found[$i].Exes -join ', '))
        }
        $pick = Read-Host '  Press Enter for all of these, type numbers to choose some (e.g. 1 3), or 0 for none'
        $nums = if ($pick.Trim()) { Read-Numbers $pick $found.Count } else { 1..$found.Count }
        foreach ($n in $nums) { $g = $found[$n - 1].Game; $selected[$g.AppId] = $g }
    }

    while ($true) {
        $q = (Read-Host '  Add another installed game? Type part of its name, or press Enter to continue').Trim()
        if (-not $q) { break }
        $hits = @($games | Where-Object { $_.Name.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
                                             -not $selected.Contains($_.AppId) })
        if (-not $hits.Count) { Info '  No installed game matches that.'; continue }
        if ($hits.Count -gt 15) { Info "  $($hits.Count) matches; showing 15. Type more of the name to narrow it down."; $hits = $hits[0..14] }
        for ($i = 0; $i -lt $hits.Count; $i++) { Info ('  {0,2}. {1}' -f ($i + 1), $hits[$i].Name) }
        $p = if ($hits.Count -eq 1) { Read-Host '  Add it? [Y/n]' } else { Read-Host '  Numbers to add (Enter to skip)' }
        $nums = if ($hits.Count -eq 1) { if ($p -match '^\s*n') { @() } else { @(1) } } else { Read-Numbers $p $hits.Count }
        foreach ($n in $nums) { $g = $hits[$n - 1]; $selected[$g.AppId] = $g; Ok "Added $($g.Name)" }
    }
    if (-not $selected.Count) { Info 'No games chosen.'; return $false }

    $accounts = @(Get-SteamAccounts $steamDir)
    if (-not $accounts.Count) { Info 'No Steam account found on this PC. Sign in to Steam once, then run Install.cmd again.'; return $false }
    $targets = @($accounts[0])
    if ($accounts.Count -gt 1) {
        Info 'Steam accounts on this PC:'
        for ($i = 0; $i -lt $accounts.Count; $i++) {
            Info ('  {0}. {1}{2}' -f ($i + 1), $accounts[$i].Name, $(if ($i -eq 0) { '  (most recent)' } else { '' }))
        }
        $p = Read-Host '  Which account? Press Enter for 1, type a number, or A for all'
        if ($p -match '^\s*a') { $targets = $accounts }
        else { $n = Read-Numbers $p $accounts.Count; if ($n.Count) { $targets = @($accounts[$n[0] - 1]) } }
    }

    $steamState = Request-SteamClosed $steamDir
    if (-not $steamState) { Info 'Skipped; Steam launch options were not changed.'; return $false }

    $wrote = $false
    try {
        foreach ($acct in $targets) {
            $current = Get-SteamLaunchOptions ([IO.File]::ReadAllText($acct.Config, $script:Utf8NoBom))
            $changes = @{}
            foreach ($id in $selected.Keys) {
                $old = if ($current.ContainsKey($id)) { $current[$id] } else { '' }
                $new = Add-LauncherOption $old $LauncherExe
                if ($new -cne $old) { $changes[$id] = $new }
            }
            if ($changes.Count) { Write-SteamLaunchOptions $acct.Config $changes; $wrote = $true }
            Ok ('{0}: {1} game(s) updated, {2} already set' -f $acct.Name, $changes.Count, ($selected.Count - $changes.Count))
            foreach ($id in $changes.Keys) { Info ('    {0}:  {1}' -f $selected[$id].Name, $changes[$id]) }
        }
        if ($wrote) { Info 'A backup of each changed file was saved as localconfig.vdf.rtsslauncher.bak.' }
    }
    finally {
        if ($steamState -eq 'closed') { Info 'Starting Steam again.'; Start-SteamAsUser $steamDir }
    }
    return $true
}

function Stop-RTSS {
    $names = 'RTSS', 'RTSSHooksLoader64', 'RTSSHooksLoader'
    $procs = Get-Process -Name $names -ErrorAction SilentlyContinue
    if ($procs) { $procs | Stop-Process -Force; Start-Sleep -Seconds 1; return $true }
    return $false
}

# ================================================================= install
try {
    $versionFile = Join-Path $PackageDir 'VERSION'
    $Version = if (Test-Path $versionFile) { (Get-Content $versionFile -TotalCount 1).Trim() } else { 'dev' }
    Write-Host "RTSS Launcher $Version - installer" -ForegroundColor White
    Info "Tasks will run as: $RunAsUser"

    $config = Read-Ini (Join-Path $PackageDir 'config.ini')

    Step 'Locating RivaTuner Statistics Server'
    $configuredPath = if ($config.ContainsKey('RTSS')) { $config['RTSS']['Path'] } else { 'auto' }
    $rtssDir = Find-RTSS $configuredPath
    $rtssExe = Join-Path $rtssDir 'RTSS.exe'
    Ok $rtssExe

    Step 'Building RTSSLauncher.exe'
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
    if (-not (Test-Path $csc)) { throw '.NET Framework 4 compiler (csc.exe) not found.' }

    Get-Process -Name 'RTSSLauncher' -ErrorAction SilentlyContinue | Stop-Process -Force
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $launcherExe = Join-Path $InstallDir 'RTSSLauncher.exe'
    $source      = Join-Path $PackageDir 'src\RTSSLauncher.cs'

    $cscOutput = & $csc /nologo /target:winexe /optimize+ /platform:anycpu `
                        /reference:System.Windows.Forms.dll "/out:$launcherExe" "$source" 2>&1
    if ($LASTEXITCODE -ne 0) { $cscOutput | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }; throw 'Compile failed.' }
    Ok $launcherExe

    Step 'Copying package files'
    Copy-Item (Join-Path $PackageDir 'config.ini')    $InstallDir -Force
    Copy-Item (Join-Path $PackageDir 'README.md')     $InstallDir -Force -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $PackageDir 'Uninstall.cmd') $InstallDir -Force
    New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir 'scripts') | Out-Null
    Copy-Item (Join-Path $PackageDir 'scripts\Uninstall.ps1') (Join-Path $InstallDir 'scripts') -Force
    Copy-Item (Join-Path $PackageDir 'scripts\Steam.ps1')     (Join-Path $InstallDir 'scripts') -Force
    Ok $InstallDir

    Step 'Creating scheduled tasks'
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -Priority 4
    $principal = New-ScheduledTaskPrincipal -UserId $RunAsUser -LogonType Interactive -RunLevel Highest

    $startAction = New-ScheduledTaskAction -Execute $rtssExe -WorkingDirectory $rtssDir
    Register-ScheduledTask -TaskPath $TaskPath -TaskName 'Start RTSS' -Action $startAction `
        -Principal $principal -Settings $settings -Force `
        -Description 'Started by RTSS Launcher before a game. Runs RTSS elevated without a UAC prompt.' | Out-Null
    Ok "${TaskPath}Start RTSS"

    $stopAction = New-ScheduledTaskAction -Execute $launcherExe -Argument '--stop-rtss' -WorkingDirectory $InstallDir
    Register-ScheduledTask -TaskPath $TaskPath -TaskName 'Stop RTSS' -Action $stopAction `
        -Principal $principal -Settings $settings -Force `
        -Description 'Started by RTSS Launcher after a game exits. Closes RTSS (windowless).' | Out-Null
    Ok "${TaskPath}Stop RTSS"

    # ------------------------------------------------------------ RTSS per-game profiles
    # Games = every exe in [FrameLimits] plus every [Profile:<exe>] section.
    $limits   = if ($config.ContainsKey('FrameLimits')) { $config['FrameLimits'] } else { @{} }
    $shared   = if ($config.ContainsKey('ProfileSettings')) { $config['ProfileSettings'] } else { @{} }
    $exeNames = New-Object 'System.Collections.Generic.List[string]'
    foreach ($k in $limits.Keys) { if (-not $exeNames.Contains($k)) { $exeNames.Add($k) } }
    foreach ($s in $config.Keys) {
        if ($s -match '^Profile:(.+)$') { $n = $Matches[1].Trim(); if (-not $exeNames.Contains($n)) { $exeNames.Add($n) } }
    }

    if ($exeNames.Count -gt 0) {
        Step 'Writing RTSS game profiles'
        $wasRunning  = Stop-RTSS     # RTSS must be closed or it can overwrite profiles on exit
        $profilesDir = Join-Path $rtssDir 'Profiles'
        $globalCfg   = Join-Path $profilesDir 'Global'
        New-Item -ItemType Directory -Force -Path $profilesDir | Out-Null

        foreach ($exeName in $exeNames) {
            $cfg = Join-Path $profilesDir "$exeName.cfg"
            if (Test-Path -LiteralPath $cfg) {
                if (-not (Test-Path -LiteralPath "$cfg.bak")) { Copy-Item -LiteralPath $cfg "$cfg.bak" }  # original, pre-install copy
            } elseif (Test-Path -LiteralPath $globalCfg) {
                Copy-Item -LiteralPath $globalCfg $cfg     # new profile based on Global
            }

            $changes = New-Object 'System.Collections.Generic.List[string]'

            if ($limits.Contains($exeName)) {
                $fps = 0
                if ([int]::TryParse($limits[$exeName], [ref]$fps) -and $fps -ge 0) {
                    Set-IniValue $cfg 'Framerate' 'Limit' "$fps"
                    Set-IniValue $cfg 'Framerate' 'LimitDenominator' '1'
                    $changes.Add($(if ($fps -eq 0) { 'no FPS limit' } else { "$fps FPS" }))
                } else { Info "  $exeName - invalid FPS '$($limits[$exeName])', skipped" }
            }

            # [ProfileSettings] applies to all games; [Profile:<exe>] overrides per game.
            # Keys are written as Section.Key=Value, matching RTSS\Profiles\*.cfg.
            $perGame = if ($config.ContainsKey("Profile:$exeName")) { $config["Profile:$exeName"] } else { @{} }
            foreach ($set in @($shared, $perGame)) {
                foreach ($entry in $set.Keys) {
                    $parts = $entry.Split('.', 2)
                    if ($parts.Count -ne 2) { Info "  Skipping '$entry' (use Section.Key=Value)"; continue }
                    Set-IniValue $cfg $parts[0] $parts[1] $set[$entry]
                    $changes.Add("$entry=$($set[$entry])")
                }
            }
            Ok ("{0}: {1}" -f $exeName, ($changes -join ', '))
        }

        if ($wasRunning) { Start-ScheduledTask -TaskPath $TaskPath -TaskName 'Start RTSS'; Info 'RTSS was running - restarted it.' }
    }

    $steamDone = $false
    try { $steamDone = Invoke-SteamLaunchOptionSetup $launcherExe $exeNames.ToArray() }
    catch { Write-Host "  Could not set Steam launch options: $($_.Exception.Message)" -ForegroundColor Yellow }

    $launchOption = "`"$launcherExe`" %command%"
    try { Set-Clipboard -Value $launchOption } catch { }

    Write-Host "`nDone." -ForegroundColor Green
    $where = if ($steamDone) { 'For any other game, in Steam' } else { 'In Steam' }
    Write-Host "`n${where}: right-click the game > Properties > General > Launch Options, and paste:" -ForegroundColor White
    Write-Host "`n  $launchOption`n" -ForegroundColor Yellow
    Info '(Already copied to your clipboard.)'
    Info 'Keep "Start with Windows" OFF in RTSS, or the launcher will leave RTSS running.'
    Info "Log file: $env:LOCALAPPDATA\RTSSLauncher\launcher.log  (written by the launcher for your user)"
}
catch {
    Write-Host "`nInstall failed: $($_.Exception.Message)" -ForegroundColor Red
}
Read-Host "`nPress Enter to close"
