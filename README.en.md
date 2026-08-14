# DSH Launcher — Menu Bar App for DeepSeek Harness

[中文](README.md) | **English** | [Windows version (system tray app)](dsh-win-app/)

A macOS menu bar app that hands the `dsh web` service over to launchd — **no terminal required**.
**App on → service on: launching the app starts the service, quitting stops it.**
Click the whale icon in the menu bar (🐋 green = running / orange = port occupied externally / red = failed to start / gray = not running; the official dsh whale logo tinted by state) to control it.
A health check runs 3.5 s after launch; if the process exits, the log tail is shown.

![DSH Launcher menu bar](docs/screenshot.png)

## Do I need to run `npx @deepseek-ai/dsh web` first?

**No.** The only prerequisite is Node.js on the machine — you do not need to
have run `npx @deepseek-ai/dsh web` manually:

- The Web UI is a service running on this machine (http://127.0.0.1:3080);
  a `dsh web` process must be running to open it — and that process is
  exactly what **this app starts and manages**: clicking "Restart service"
  (or the auto-start on launch) runs `dsh web --port 3080` under launchd.
- If dsh is already available (global install or npx cache) it is reused;
  if not, the first start automatically runs `npx --yes @deepseek-ai/dsh`
  to download it (cached afterwards). No manual commands needed.
- Caveat: if you *did* run `npx @deepseek-ai/dsh web` in a terminal before,
  that process holds port 3080 and the app shows orange "external instance";
  press `Ctrl+C` there to stop it, then let the app take over
  (see "Switching from a terminal instance" below).

## Install (DMG release)

Download `DSH-Launcher-*.dmg` from the [Releases](https://github.com/tttnny/DSH-Launcher/releases) page:

1. Open the DMG and drag `DSH Launcher.app` into **Applications**
2. First launch (ad-hoc signed, not notarized — Gatekeeper will block it): right-click `DSH Launcher.app` in Finder → **Open**; or run
   ```bash
   xattr -dr com.apple.quarantine /Applications/DSH\ Launcher.app
   ```

Requirements: Apple Silicon Mac (M1/M2/M3/M4) · macOS 13 or later · Node.js installed (fnm / nvm / Homebrew all fine).

## Build

```bash
./build.sh        # produces dist/DSH Launcher.app (ad-hoc signed, no developer account needed)
```

The build output is installed to `~/Applications/DSH Launcher.app`. After changing code, re-run `./build.sh`
and overwrite with `cp -R dist/DSH\ Launcher.app ~/Applications/`.

## Menu features

| Menu item | Action |
|---|---|
| Status line | Whether the service is running (launchd-managed / external instance on port 3080) |
| Open Web UI (⌘O) | Opens http://127.0.0.1:3080 in the browser |
| Restart service | Always available: running = restart; failed/stopped = start; port taken by an external instance = dialog explaining who owns it |
| Launch at login | Shows the menu bar icon and starts the service after login |
| Open data directory | `~/.dsh` |
| Quit | Quits the app **and stops the service** (`launchctl bootout`; data is persisted, restored next time the app is opened) |

## Switching from a terminal instance (first use)

Port 3080 may still be held by a `dsh web` running in a terminal (the app shows orange "external instance").
To switch:

1. Press `Ctrl+C` in the terminal to stop the old `dsh web` (this session goes offline, but history stays in `~/.dsh/sessions/`)
2. Quit and reopen DSH Launcher (or click **Restart service**) — the service starts automatically
3. Once the status turns green, click **Open Web UI** — past sessions are fully resumable

## LAN access (optional, community plugin)

This app only hosts the local service (dsh upstream intentionally refuses binding `0.0.0.0` for safety, and
non-secure-context browsers break some features). For LAN access use the community plugin
[moxisuki/dsh-lan](https://github.com/moxisuki/dsh-lan) (verified against rc.6 — page, API, and
add-workspace all work). **No startup command change needed**:

```bash
# 1. Install the plugin once (already installed here, linked to ~/.dsh/plugins/dsh-lan)
dsh plugin --profile web add "/Users/$USER/.dsh/plugins/dsh-lan"

# 2. Copy dsh-lan's overlay into the profile patch layer once (auto-applied on every dsh web start)
cp "/Users/$USER/.dsh/plugins/dsh-lan/cordis.yml" \
   "/Users/$USER/.dsh/profiles/web/cordis.patch.yml"

# 3. Restart the service (click "Restart service" in the app menu); the command stays `dsh web --port 3080`
```

Open the `(LAN: http://<your-IP>:3080)` address printed at startup.
To turn LAN access off, restore `~/.dsh/profiles/web/cordis.patch.yml` to `[]` and restart the service.
Known limitation (upstream pins these to loopback clients): settings, credentials, and agent-preset
editing return 403 over LAN; the UI degrades gracefully.
⚠️ dsh web has no authentication layer — LAN access exposes remote code execution to your whole LAN;
use only on trusted networks.

## Technical notes

- **Service definition**: `~/Library/LaunchAgents/com.dsh.web.plist` (mode 600),
  runs `<fnm node> <npx-cached dsh bin.js> web --port 3080` directly, no PATH dependency —
  because launchd's login environment has no node (your node is a temporary fnm shim).
- **Launch-at-login definition**: `~/Library/LaunchAgents/com.dsh.menubar.plist` (app auto-start only; the service is never launched at login, `RunAtLoad` is always false — the user starts it manually).
- **API key**: the harness reads `~/.dsh/.credentials.yaml` directly; no extra configuration needed in the launchd environment.
- Each "Start service" re-resolves the node path and the latest dsh package path and rewrites the plist —
  after upgrading dsh (npx cache moves directories) no manual config changes are needed.
- Stopping the service = `launchctl bootout`; launchd terminates the whole process tree and persists the session.
- Logs: `~/Library/Logs/DSHLauncher/dsh-web.log`.

## Uninstall

```bash
launchctl bootout gui/$(id -u)/com.dsh.web 2>/dev/null
launchctl bootout gui/$(id -u)/com.dsh.menubar 2>/dev/null
rm -f ~/Library/LaunchAgents/com.dsh.web.plist ~/Library/LaunchAgents/com.dsh.menubar.plist
rm -rf ~/Applications/DSH\ Launcher.app
```
