@echo off
rem Double-click to remove RTSS Launcher (scheduled tasks and program folder).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Uninstall.ps1"
