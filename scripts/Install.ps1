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

    $launchOption = "`"$launcherExe`" %command%"
    try { Set-Clipboard -Value $launchOption } catch { }

    Write-Host "`nDone." -ForegroundColor Green
    Write-Host "`nIn Steam: right-click the game > Properties > General > Launch Options, and paste:" -ForegroundColor White
    Write-Host "`n  $launchOption`n" -ForegroundColor Yellow
    Info '(Already copied to your clipboard.)'
    Info 'Keep "Start with Windows" OFF in RTSS, or the launcher will leave RTSS running.'
    Info "Log file: $env:LOCALAPPDATA\RTSSLauncher\launcher.log  (written by the launcher for your user)"
}
catch {
    Write-Host "`nInstall failed: $($_.Exception.Message)" -ForegroundColor Red
}
Read-Host "`nPress Enter to close"
