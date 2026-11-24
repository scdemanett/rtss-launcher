#Requires -Version 5.1
# Removes RTSS Launcher's scheduled tasks and program folder. RTSS itself and its profiles are left alone.
param([string]$InstallDir = (Join-Path $env:ProgramFiles 'RTSS Launcher'))

$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-InstallDir', "`"$InstallDir`"") } catch { }
    exit
}

# Offers to take the launcher out of Steam launch options, keeping anything else in them.
# Returns $true if Steam launch options are clean afterwards (nothing left to clear by hand).
function Remove-SteamLaunchOptions {
    $steamDir = Find-SteamDir
    if (-not $steamDir) { return $false }

    $names = @{}; foreach ($g in Get-SteamGames $steamDir) { $names[$g.AppId] = $g.Name }
    $plan = New-Object System.Collections.ArrayList          # @{ Account; Changes }
    foreach ($acct in Get-SteamAccounts $steamDir) {
        $current = Get-SteamLaunchOptions ([IO.File]::ReadAllText($acct.Config, $script:Utf8NoBom))
        $changes = @{}
        foreach ($id in $current.Keys) {
            if ($current[$id] -match 'RTSSLauncher\.exe') { $changes[$id] = Remove-LauncherOption $current[$id] }
        }
        if ($changes.Count) { [void]$plan.Add(@{ Account = $acct; Changes = $changes }) }
    }
    if (-not $plan.Count) { return $true }

    Write-Host "`nThese Steam games use RTSS Launcher in their launch options:"
    foreach ($p in $plan) {
        foreach ($id in $p.Changes.Keys) {
            $name = if ($names.ContainsKey($id)) { $names[$id] } else { "App $id" }
            Write-Host ("  {0}  ({1})" -f $name, $p.Account.Name)
        }
    }
    $answer = Read-Host 'Remove it from their launch options? Other options are kept. [Y/n]'
    if ($answer -match '^\s*n') { return $false }

    $steamState = Request-SteamClosed $steamDir
    if (-not $steamState) { return $false }
    try {
        foreach ($p in $plan) { Write-SteamLaunchOptions $p.Account.Config $p.Changes }
        Write-Host 'Steam launch options updated (backup: localconfig.vdf.rtsslauncher.bak).' -ForegroundColor Green
    }
    finally {
        if ($steamState -eq 'closed') { Write-Host 'Starting Steam again.'; Start-SteamAsUser $steamDir }
    }
    return $true
}

try {
    Set-Location $env:TEMP
    Get-Process -Name 'RTSSLauncher' -ErrorAction SilentlyContinue | Stop-Process -Force

    $steamClean = $false
    $steamModule = Join-Path $PSScriptRoot 'Steam.ps1'
    if (Test-Path -LiteralPath $steamModule) {
        try { . $steamModule; $steamClean = Remove-SteamLaunchOptions }
        catch { Write-Host "Could not update Steam launch options: $($_.Exception.Message)" -ForegroundColor Yellow }
    }

    Get-ScheduledTask -TaskPath '\RTSSLauncher\' -ErrorAction SilentlyContinue |
        Unregister-ScheduledTask -Confirm:$false
    try { $svc = New-Object -ComObject Schedule.Service; $svc.Connect(); $svc.GetFolder('\').DeleteFolder('RTSSLauncher', 0) } catch { }
    Write-Host 'Scheduled tasks removed.' -ForegroundColor Green

    if (Test-Path -LiteralPath $InstallDir) {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
        Write-Host "Removed $InstallDir" -ForegroundColor Green
    }

    if (-not $steamClean) { Write-Host "`nRemember to remove RTSSLauncher.exe from your games' Steam launch options." -ForegroundColor Yellow }
    Write-Host 'RTSS profiles (frame limits) were left in place. Backups of any profiles that existed before install are saved as *.cfg.bak.'
}
catch { Write-Host "Uninstall failed: $($_.Exception.Message)" -ForegroundColor Red }
Read-Host "`nPress Enter to close"
