# DSH Launcher — System Tray App for DeepSeek Harness (Windows)

[中文](README.md) | **English**

A Windows system tray app that runs the `dsh web` service in the background — **no terminal required**.
**App on → service on: launching the app starts the service, quitting stops it.**
Click the whale icon in the tray (🐋 green = running / orange = port occupied externally / red = failed to start / gray = not running; the official dsh whale logo tinted by state) to control it.
A health check runs 3.5 s after launch; if the process exits, the log tail is shown.

This is the Windows counterpart of the macOS [DSH Launcher](https://github.com/tttnny/DSH-Launcher) (menu bar + launchd), with the same features and behavior.

## Install

Single-file exe, no installation required:

1. Download `DSH Launcher.exe` ([Releases](https://github.com/tttnny/DSH-Launcher/releases) or build it yourself),
   put it anywhere (e.g. Desktop or `%LOCALAPPDATA%\DSHLauncher\`) and double-click
2. First run may show a SmartScreen prompt: click **More info** → **Run anyway**
   (normal for an unsigned exe, same as the Gatekeeper warning on macOS)
3. The whale icon appears in the tray; a one-time balloon tip explains the status colors

Requirements: Windows 10/11 · Node.js installed (nvm-windows / fnm / official installer all fine).

> You do **not** need to run `npx @deepseek-ai/dsh web` manually first:
> the app locates node and the dsh package automatically (global install or npx cache);
> if neither exists, the first start runs `npx --yes @deepseek-ai/dsh` to download it (cached afterwards).
> Caveat: if you *did* run `dsh web` in a terminal, that process holds port 3080 and the app shows
> orange "external instance"; press `Ctrl+C` there and let the app take over
> (see "Switching from a terminal instance" below).

## Build

```bat
build.bat        :: produces dist\DSH Launcher.exe
```

- Compiled with the `csc.exe` built into .NET Framework 4.8 (ships with Windows 10/11) — **no SDK needed**
- Output is a single-file exe (icon, DPI manifest and the official whale SVG embedded);
  copy it to any Win10/11 machine and run
- If you have the .NET SDK, `dotnet build -c Release` works too (same source, `DSHLauncher.csproj`)

## Menu features

| Menu item | Action |
|---|---|
| Status line | Whether the service is running (app-managed / external instance on port 3080) |
| Open Web UI | Opens http://127.0.0.1:3080 in the browser |
| Restart service | Always available: running = restart; failed/stopped = start; port taken by an external instance = dialog explaining who owns it |
| Launch at login | Writes `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`; the app starts the service after login |
| Open data directory | `%USERPROFILE%\.dsh` |
| Quit | Quits the app **and stops the service** (kills the whole process tree; data is persisted, restored next time the app is opened) |

## Switching from a terminal instance (first use)

Port 3080 may still be held by a `dsh web` running in a terminal (the app shows orange "external instance").
To switch:

1. Press `Ctrl+C` in the terminal to stop the old `dsh web` (this session goes offline, but history stays in `%USERPROFILE%\.dsh\sessions\`)
2. Restart DSH Launcher (or click **Restart service**) — the service starts automatically
3. Once the status turns green, click **Open Web UI** — past sessions are fully resumable

## LAN access (optional, community plugin)

This app only hosts the local service (dsh upstream intentionally refuses binding `0.0.0.0` for safety, and
non-secure-context browsers break some features). For LAN access use the community plugin
[moxisuki/dsh-lan](https://github.com/moxisuki/dsh-lan) (verified against rc.6 — page, API, and
add-workspace all work). **No startup command change needed**:

```bat
rem 1. Install the plugin once
dsh plugin --profile web add "%USERPROFILE%\.dsh\plugins\dsh-lan"

rem 2. Copy dsh-lan's overlay into the profile patch layer once (auto-applied on every dsh web start)
copy "%USERPROFILE%\.dsh\plugins\dsh-lan\cordis.yml" "%USERPROFILE%\.dsh\profiles\web\cordis.patch.yml"

rem 3. Restart the service (click "Restart service" in the app menu); the command stays `dsh web --port 3080`
```

Open the `(LAN: http://<your-IP>:3080)` address printed at startup.
To turn LAN access off, restore `%USERPROFILE%\.dsh\profiles\web\cordis.patch.yml` to `[]` and restart the service.
Known limitation (upstream pins these to loopback clients): settings, credentials, and agent-preset
editing return 403 over LAN; the UI degrades gracefully.
⚠️ dsh web has no authentication layer — LAN access exposes remote code execution to your whole LAN;
use only on trusted networks.

## Technical notes

- **Process model**: the app spawns `<node.exe> <npx-cached dsh bin.js> web --port 3080` in a hidden
  window (preferred); if no dsh cache exists it falls back to `cmd /c npx.cmd --yes @deepseek-ai/dsh web --port 3080`.
  Stopping = `taskkill /PID <pid> /T` (graceful first, then forced; kills the whole process tree and
  persists the session — the Windows equivalent of `launchctl bootout`).
  If the app itself is force-killed (Task Manager), the orphaned dsh process is detected and reclaimed
  on the next launch.
- **node resolution order**: registry memory → fnm (`%LOCALAPPDATA%\fnm\node-versions`) →
  nvm-windows (`%NVM_HOME%` or `%APPDATA%\nvm`) → official install dirs → `where node`.
  Each "Start service" re-resolves and remembers the paths, so upgrading node/dsh needs no config changes.
- **dsh package resolution**: npm global install (`%APPDATA%\npm\node_modules`) →
  npx cache (`%LOCALAPPDATA%\npm-cache\_npx` and `%APPDATA%\npm-cache\_npx`, newest wins).
- **State detection**: process alive → HTTP health check (127.0.0.1:3080, 4xx/5xx counts) →
  `netstat -ano` to find the port occupier (dialog shows PID and process name).
- **API key**: the harness reads `%USERPROFILE%\.dsh\.credentials.yaml` directly; no extra configuration needed.
- **Launch at login**: registry `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`
  (app auto-start only; the service is never launched at login — the app starts it).
- **Single instance**: named mutex; a second launch shows a message and exits.
- **Logs**: `%LOCALAPPDATA%\DSHLauncher\dsh-web.log`.

## Uninstall

1. Uncheck "Launch at login" in the tray menu (or delete the Run key manually)
2. Click **Quit** (stops the service)
3. Delete the exe and the `%LOCALAPPDATA%\DSHLauncher` folder
