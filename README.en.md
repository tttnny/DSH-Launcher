# DSH Launcher — Menu Bar App for DeepSeek Harness

[中文](README.md) | **English**

A macOS menu bar app that hands the `dsh web` service over to launchd — **no terminal required**.
**App on → service on: launching the app starts the service, quitting stops it.**
Click the whale icon in the menu bar (🐋 green = running / orange = port occupied externally / red = failed to start / gray = not running; the official dsh whale logo tinted by state) to open the control menu: Open Web UI, Restart service, Launch at login, Open data directory, or Quit.
> Green requires **both** the launchd process running **and** HTTP 3080 actually reachable — neither alone turns it green.
The service process inherits your terminal's zsh environment (PATH etc.), so the agent's shell tools get node/npm/pnpm/bun directly.

![DSH Launcher menu bar](docs/screenshot.png)

## Do I need to run `npx @deepseek-ai/dsh web` first?

**No.** The only prerequisite is Node.js on the machine:

- This app starts and manages `dsh web --port 3080` itself (auto-started on launch, or via "Restart service");
  an existing dsh (global install or npx cache) is reused.
- On first use (no local dsh) the app does not auto-download: the menu bar shows
  "dsh not installed" with an **Install dsh** button. Clicking it opens an install panel
  with live download logs; once installed, the service starts automatically — no app restart needed.
- If you ran `dsh web` in a terminal before, that process holds port 3080 and the app shows
  orange "external instance" — press `Ctrl+C` there to stop it, then let the app take over (steps below).

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

The output `dist/DSH Launcher.app` is directly runnable — copy it anywhere (e.g. `~/Applications/`).

## Menu features

| Menu item | Action |
|---|---|
| Status line | Whether the service is running (launchd-managed / external instance on port 3080) |
| Open Web UI (⌘O) | Opens http://127.0.0.1:3080 in the browser |
| Install dsh (shown only when not installed) | Installs dsh on first use with a live progress panel; starts the service automatically when done |
| Uninstall dsh (shown only when installed) | After confirmation, stops the service, runs `npm uninstall -g @deepseek-ai/dsh`, and clears the dsh npx cache. Two modes: **Uninstall only** (keeps `~/.dsh` for seamless reinstalling) or **Full uninstall** (also deletes `~/.dsh` data and the service LaunchAgent config — nothing left behind, irreversible) |
| Restart service | Always available: running = restart; failed/stopped = start; port taken by an external instance = dialog explaining who owns it |
| Update dsh / Check for updates | Auto-checks the npm registry for a newer dsh (10s after launch, then every 6 hours, silently): when available the menu becomes "Update dsh → vX"; one click upgrades (`npm install -g @deepseek-ai/dsh@latest`) and restarts the service. Otherwise click to check manually |
| dsh version: vX | Read-only info line showing the installed dsh version ("Not installed" when missing) |
| Launch at login | Shows the menu bar icon and starts the service after login |
| Open data directory | `~/.dsh` |
| Quit | Quits the app **and stops the service** (`launchctl bootout`; data is persisted, restored next time the app is opened) |

## Switching from a terminal instance (first use)

Port 3080 may still be held by a `dsh web` running in a terminal (the app shows orange "external instance").
To switch:

1. Press `Ctrl+C` in the terminal to stop the old `dsh web` (this session goes offline, but history stays in `~/.dsh/sessions/`)
2. Quit and reopen DSH Launcher (or click **Restart service**) — the service starts automatically
3. Once the status turns green, click **Open Web UI** — past sessions are fully resumable

## Technical notes

- **Environment inheritance**: launchd has no shell configuration of its own, so before every start
  the app captures your full environment with `zsh -lic` and writes it into the plist's
  `EnvironmentVariables` (PATH cleaned of volatile fnm multishell temp dirs, node directory first).
  The service and the agent's shell tools therefore get the same toolchain as your terminal
  (node/npm/pnpm/bun, ...); editing `.zshrc` takes effect after a service restart.
  **Note**: env vars containing token/secret/password/api-key/credential keywords (e.g.
  `DASHSCOPE_API_KEY`, `AWS_SECRET_ACCESS_KEY`) are deliberately stripped and never written
  to the plist in plain text — configure API keys in `~/.dsh` (dsh's native approach),
  don't rely on `.zshrc` env vars reaching the in-service agent.
- **dsh upgrades need no config**: every start re-resolves the node path and the latest dsh package
  path and rewrites `~/Library/LaunchAgents/com.dsh.web.plist`.
- **Auto update check**: 10s after launch and every 6 hours the app queries the npm registry
  (both `latest` and `next` dist-tags of `@deepseek-ai/dsh`, taking the higher semver version)
  and compares it with the installed version per SemVer 2.0 (correctly handling rc/alpha/beta
  prerelease numbers). When a newer version exists the menu shows "Update dsh → vX"; targets
  from the `next` prerelease channel are marked "（预发布/prerelease)". One click runs
  `npm install -g @deepseek-ai/dsh@<target>` (the exact detected version, not @latest) and
  restarts the service. Update log: `~/Library/Logs/DSHLauncher/dsh-update.log`.
- **Log rotation**: `dsh-web.log` is auto-rotated to `.1` before the next service restart once
  it exceeds 20MB, preventing unbounded disk growth.

## Uninstall dsh

Done with dsh? Click **Uninstall dsh** in the menu (shown only while installed), then pick one:

- **Uninstall only (keep ~/.dsh)**: stops the service → runs
  `npm uninstall -g @deepseek-ai/dsh` and clears the dsh npx cache, returning to the
  "not installed" state. The data directory `~/.dsh` (sessions, config) is untouched —
  click **Install dsh** anytime to reinstall seamlessly.
- **Full uninstall (delete ~/.dsh)**: on top of the above, also deletes the data
  directory `~/.dsh` and the service LaunchAgent config (`com.dsh.web.plist`) — for
  when you are done for good and want nothing left behind.
  **Irreversible; back up any sessions you need first.**

Uninstall log: `~/Library/Logs/DSHLauncher/dsh-uninstall.log`.

## Uninstall the app

```bash
launchctl bootout gui/$(id -u)/com.dsh.web 2>/dev/null
launchctl bootout gui/$(id -u)/com.dsh.menubar 2>/dev/null
rm -f ~/Library/LaunchAgents/com.dsh.web.plist ~/Library/LaunchAgents/com.dsh.menubar.plist
rm -rf ~/Applications/DSH\ Launcher.app
```
