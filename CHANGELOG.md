# Changelog

## [Unreleased]
### Added
- Install.cmd can add the Steam launch option for you. It finds installed games with settings in `config.ini`, lets you choose from them or add any other installed game by name, closes and restarts Steam if needed, and keeps existing launch options. It's optional, with a backup of `localconfig.vdf`.
- Uninstall.cmd offers to remove the launcher from Steam launch options, keeping anything else in them.

### Fixed
- You Are Empty's 60 FPS limit is now commented out. It only applies to the original 2006 retail release. The Absolute Edition, the version sold on Steam, supports high frame rates and uses the same `you_are_empty.exe`.

## [1.1.0] - 2026-11-22
### Added
- Frame limits for more games that break at high frame rates, per PCGamingWiki: Chrome SpecForce, Deadly Premonition: The Director's Cut, Deus Ex, Deus Ex: Invisible War, Duke Nukem: Manhattan Project, F.E.A.R. (with Extraction Point and Perseus Mandate), F.E.A.R. 2, Grand Theft Auto IV, Hitman: Codename 47, Hitman 2, Hitman: Contracts, Hitman: Blood Money, Joe Danger and You Are Empty.
- Commented-out, situational limits for Hydrophobia: Prophecy, Kane & Lynch: Dead Men, Bully: Scholarship Edition and Mirror's Edge Catalyst.
- Bug report issue template that asks for `launcher.log`.

### Changed
- README: badges, a fuller description and an FAQ.

### Fixed
- README `[ProfileSettings]` example used comments after values, which the installer reads as part of the value.

## [1.0.0] - 2026-11-22
### Added
- Windowless `RTSSLauncher.exe`, compiled on install from `src/RTSSLauncher.cs` with the .NET Framework 4 compiler built into Windows.
- Starts RTSS before a Steam game (`"...\RTSSLauncher.exe" %command%`) and closes it after the game exits, but only if the launcher started it.
- Detects when the game has closed by watching every process running from the game's install folder, so launchers that hand off to another exe (e.g. Chrome's `Chrome.exe` to `ChromeSingle.exe` / `ChromeNet.exe`) are handled.
- On-demand scheduled tasks to start and stop the elevated RTSS without UAC prompts.
- Per-game RTSS profile settings from `config.ini`: `[FrameLimits]`, `[ProfileSettings]` and `[Profile:<exe>]`, written as `Section.Key=Value`.
- Chrome preset: 60 FPS cap and On-Screen Display off for `ChromeSingle.exe` and `ChromeNet.exe`.
- Self-elevating `Install.cmd` / `Uninstall.cmd`.
