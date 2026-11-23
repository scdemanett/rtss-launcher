# RTSS Launcher

[![Latest release](https://img.shields.io/github/v/release/scdemanett/rtss-launcher)](https://github.com/scdemanett/rtss-launcher/releases/latest)
[![License: MIT](https://img.shields.io/github/license/scdemanett/rtss-launcher)](LICENSE)
![Platform: Windows 10 | 11](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D6)

Starts RivaTuner Statistics Server (RTSS) when you launch a Steam game and closes it when the game exits. No console windows and no UAC prompts. It also writes per-game frame limits (FPS caps) and other RTSS profile settings, so RTSS only runs while you play instead of sitting in the tray from Windows startup.

Use it as a Steam launch option for any game: a lightweight way to auto-start the RTSS frame limiter for older games that run too fast, stutter or have no built-in FPS cap.

Comes with frame limits for 15 older games that break at high frame rates, from Chrome (Techland, 2003) to F.E.A.R., GTA IV and the early Hitman games. See [`config.ini`](config.ini) for the list and the reason for each cap, sourced from PCGamingWiki.

**Download:** get `rtss-launcher-<version>.zip` from [Releases](https://github.com/scdemanett/rtss-launcher/releases), or clone the repo. Nothing is pre-compiled; the installer builds the launcher from source on your machine.

## Requirements
- Windows 10 or 11 (uses the .NET Framework 4 compiler built into Windows; nothing else to install)
- RivaTuner Statistics Server installed
- An administrator account (needed once, for the installer)

## Install (also for a new machine)
1. If you downloaded the zip, right-click it, choose **Properties**, tick **Unblock**, then extract it anywhere.
2. Install RTSS if it isn't already installed. In RTSS, keep **Start with Windows** set to **OFF**.
3. Double-click **Install.cmd** and approve the admin prompt.
4. The installer copies the Steam launch option to your clipboard. In Steam, right-click the game, choose **Properties > General > Launch Options**, and paste:
   ```
   "C:\Program Files\RTSS Launcher\RTSSLauncher.exe" %command%
   ```
5. Click **Play**. RTSS appears in the tray, the game runs with its frame limit, and RTSS closes a few seconds after you quit.

Run the installer from the Windows account you game on. The scheduled tasks are tied to that account.

## What the installer does
| Item | Details |
|---|---|
| `C:\Program Files\RTSS Launcher\RTSSLauncher.exe` | Compiled on your machine from `src\RTSSLauncher.cs`. A windowless app, so nothing flashes on screen. |
| Task `\RTSSLauncher\Start RTSS` | Runs `RTSS.exe` elevated in your session. On demand only, with no schedule. |
| Task `\RTSSLauncher\Stop RTSS` | Runs `RTSSLauncher.exe --stop-rtss` elevated, which closes RTSS and its hook loaders. |
| RTSS profiles | For each line under `[FrameLimits]` in `config.ini`, sets `[Framerate] Limit` in `RTSS\Profiles\<exe>.cfg`. Existing profiles keep their other settings and are backed up as `.cfg.bak`. New profiles are copied from RTSS's Global profile. |

The scheduled tasks are what let a normal, non-admin process (Steam) start and stop the elevated RTSS without a UAC prompt. Both tasks only point at files in admin-protected folders (Program Files).

## How the launcher works
1. If RTSS isn't running, it starts RTSS through the task and waits for it to load (`StartupDelayMs`).
2. It starts the game exactly as Steam asked, with the same exe, arguments and working folder.
3. It watches every process running from the game's install folder. That covers launchers such as Chrome's `Chrome.exe`, which hands off to `ChromeSingle.exe` or `ChromeNet.exe`. Matching on folder instead of exe name means Google Chrome (also `chrome.exe`) is never mistaken for the game.
4. When nothing from that folder has been running for one extra check (`GraceMs`), it closes RTSS. It only does this if it started RTSS itself; an RTSS you opened yourself stays open.

## Adding games or changing limits
Edit `config.ini` in this package folder:
```ini
[FrameLimits]
ChromeSingle.exe=60
ChromeNet.exe=60
SomeOtherGame.exe=144
```
Then run **Install.cmd** again. Use `0` to remove a limit. Any Steam game can use the launcher with the same launch option, even without a frame-limit line.

Comments must be on their own line starting with `;`. Use the game's real exe, not its launcher, and avoid generic names like `Game.exe`: RTSS matches profiles by file name, so a generic name would cap unrelated programs too.

## Other RTSS settings
Any setting in an RTSS profile can be set from `config.ini`, written as `Section.Key=Value` to match the `[Section]` and `Key=` in `RTSS\Profiles\<exe>.cfg`:
```ini
; Applies to every game listed. "On-Screen Display support" off:
[ProfileSettings]
OSD.EnableOSD=0

; Overrides for one game:
[Profile:ChromeNet.exe]
OSD.EnableOSD=1
```
To find the name of any setting, change it in the RTSS window, close RTSS, and see which line changed in that game's `.cfg` file.

## Troubleshooting
- **Log file:** `%LOCALAPPDATA%\RTSSLauncher\launcher.log`
- **RTSS closes while you're still in the game's launcher menu, or never starts the limiter:** increase `InitialWaitMs` or `StartupDelayMs` in `config.ini`, then re-run Install.cmd.
- **"schtasks failed" in the log:** re-run Install.cmd. This happens after moving or reinstalling RTSS, or when using a different Windows account.
- **A leftover RTSS tray icon after quitting:** RTSS is force-closed, so Windows leaves a ghost icon until you move the mouse over it. It's harmless.
- **RTSS stays open after the game:** check that RTSS's **Start with Windows** is off and that RTSS wasn't already open before you clicked Play.
- **Anti-cheat games:** some block RTSS hooks however it's launched.

## FAQ
- **Do I need MSI Afterburner?** No. Only RTSS is needed. If Afterburner is running it may start RTSS itself; the launcher then leaves that RTSS open, since it didn't start it.
- **Does it work with non-Steam games?** It's built for Steam's `%command%` launch option. Other launchers that can wrap a game's command line may work but aren't tested.
- **Why not just set RTSS to start with Windows?** That keeps RTSS hooking every app all the time. This starts it only for the games you choose and closes it afterwards.
- **Is it safe?** The source is one C# file and two PowerShell scripts. Nothing is downloaded; the exe is compiled on your machine from `src\RTSSLauncher.cs`.

## Uninstall
Double-click **Uninstall.cmd**, here or in `C:\Program Files\RTSS Launcher`. Then clear the game's Steam launch options. RTSS and its profiles are left in place.

## Files
```
Install.cmd / Uninstall.cmd   double-click entry points
config.ini                    RTSS path, timing, frame limits
scripts\Install.ps1           installer (self-elevates)
scripts\Uninstall.ps1         uninstaller
src\RTSSLauncher.cs           launcher source (C# 5, compiled on install)
```

## License
[MIT](LICENSE)
