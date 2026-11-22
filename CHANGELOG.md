# Changelog

## [1.0.0] - 2026-11-22
### Added
- Windowless `RTSSLauncher.exe`, compiled on install from `src/RTSSLauncher.cs` with the .NET Framework 4 compiler built into Windows.
- Starts RTSS before a Steam game (`"...\RTSSLauncher.exe" %command%`) and closes it after the game exits, but only if the launcher started it.
- Detects when the game has closed by watching every process running from the game's install folder, so launchers that hand off to another exe (e.g. Chrome's `Chrome.exe` to `ChromeSingle.exe` / `ChromeNet.exe`) are handled.
- On-demand scheduled tasks to start and stop the elevated RTSS without UAC prompts.
- Per-game RTSS profile settings from `config.ini`: `[FrameLimits]`, `[ProfileSettings]` and `[Profile:<exe>]`, written as `Section.Key=Value`.
- Chrome preset: 60 FPS cap and On-Screen Display off for `ChromeSingle.exe` and `ChromeNet.exe`.
- Self-elevating `Install.cmd` / `Uninstall.cmd`.
