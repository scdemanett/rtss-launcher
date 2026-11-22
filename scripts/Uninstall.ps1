#Requires -Version 5.1
# Removes RTSS Launcher's scheduled tasks and program folder. RTSS itself and its profiles are left alone.
param([string]$InstallDir = (Join-Path $env:ProgramFiles 'RTSS Launcher'))

$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-InstallDir', "`"$InstallDir`"") } catch { }
    exit
}

try {
    Set-Location $env:TEMP
    Get-Process -Name 'RTSSLauncher' -ErrorAction SilentlyContinue | Stop-Process -Force

    Get-ScheduledTask -TaskPath '\RTSSLauncher\' -ErrorAction SilentlyContinue |
        Unregister-ScheduledTask -Confirm:$false
    try { $svc = New-Object -ComObject Schedule.Service; $svc.Connect(); $svc.GetFolder('\').DeleteFolder('RTSSLauncher', 0) } catch { }
    Write-Host 'Scheduled tasks removed.' -ForegroundColor Green

    if (Test-Path -LiteralPath $InstallDir) {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
        Write-Host "Removed $InstallDir" -ForegroundColor Green
    }

    Write-Host "`nRemember to clear the game's Steam launch options." -ForegroundColor Yellow
    Write-Host 'RTSS profiles (frame limits) were left in place. Backups of any profiles that existed before install are saved as *.cfg.bak.'
}
catch { Write-Host "Uninstall failed: $($_.Exception.Message)" -ForegroundColor Red }
Read-Host "`nPress Enter to close"
