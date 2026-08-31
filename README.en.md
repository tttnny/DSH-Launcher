# DSH Launcher — Menu Bar App for DeepSeek Harness

[中文](README.md) | **English**

A macOS menu bar app + main-window console that hands the dsh service over to launchd — **no terminal required**.

**Since v2.0 the service is fully manual (contract change)**: the dsh service is an independent launchd LaunchAgent (`com.dsh.web`) —

- Launching the app does **not** auto-start the service;
- Quitting the app does **not** stop the service;
- A crashed service is **not** auto-restarted (no KeepAlive in the plist).

All start/restart/stop actions live in the main window; the menu bar keeps only the three essentials.
Click the whale icon in the menu bar (🐋 green = running / orange = port occupied externally / red = crashed / gray = not running; the official dsh whale logo tinted by state): **Open Web**, **Show Main Window**, **Quit App**.
> Green requires **both** the launchd process running **and** HTTP 3080 actually reachable — neither alone turns it green.
The service process inherits your terminal's zsh environment (PATH etc.), so the agent's shell tools get node/npm/pnpm/bun directly.

![DSH main window](docs/screenshot.png)

## Do I need to run `npx @deepseek-ai/dsh web` first?

**No.** The only prerequisite is Node.js on the machine:

- On first launch with no local dsh, the main window opens automatically to guide you: click
  **Install dsh** (live download logs), then click **Start** — no terminal involved.
- An existing dsh (global install or npx cache) is reused as-is.
- If port 3080 is held by a `dsh web` running in a terminal, clicking **Start** ends it and takes over
  (no Ctrl+C needed); if the occupier is not dsh, a confirmation dialog appears first — nothing gets killed blindly.

## Menu bar (3 items only)

| Menu item | Action |
|---|---|
| Open Web (⌘O) | Opens http://127.0.0.1:3080 in the browser (grayed out while the service is stopped — start it in the main window first) |
| Show Main Window | Opens / brings back the DSH console window (closing it only hides it) |
| Quit App (⌘Q) | Quits this app only — **does not touch the dsh service** (it stays resident in launchd) |

## Main window (DSH console)

| Section | Content |
|---|---|
| dsh info | Service state, local version, latest npm version, latest GitHub Release (versions missing on npm are badged "not on npm" with a link to the release page), running profile, install location, node path, port |
| Service control | **Start / Restart / Stop**; shows **Install dsh** when not installed, **Uninstall dsh** and **Check for updates / Update → vX** when installed (install & update run in progress panels with live logs) |
| Profile | Lists profiles under `~/.dsh/profiles/` (subdirectories containing a package.json), shows each profile's bundles; select one and click Start to run it; "Open directory" reveals the profile folder |
| Service log | Live tail of `~/Library/Logs/DSHLauncher/dsh-web.log` — debug startup failures without a terminal |
| Settings | Launch this app at login (affects the app only, not the service), open `~/.dsh`, open the log directory |

### Service lifecycle (v2.0, fully manual)

| Action | Behavior |
|---|---|
| Start | Starts the service with the selected profile (port held by an external dsh → ends it and takes over; held by another program → confirms first; profile switched while running → asks before restarting) |
| Restart | Stops and re-launches with the current profile, no confirmation |
| Stop | Stops the service (`launchctl bootout` + killing any dsh left on the port); stays stopped until started manually |
| Crash | Red "crashed" state; **no auto-restart** — click Restart to bring it back |
| Start failure | **No modal dialog**; the Service control section shows a failure summary, details in the log section, click Restart to retry |
| Quit / reopen the app | Service keeps running / is not auto-started; the main window buttons are the single source of truth |
| Update dsh | If the service was running before the update it restarts automatically; if it was stopped it stays stopped; "Ignore this version" skips an unwanted upgrade (e.g. while waiting for an upstream fix) |

### About profiles

A dsh profile is a boot unit: plugin bundles layered in order plus your own overrides, living at
`~/.dsh/profiles/<name>`. The app scans that directory on startup (subdirectories containing a
package.json, `node_modules` skipped); `web`/`headless` are auto-initialized from templates by dsh
on first run, other profiles are created via `dsh plugin --profile <name> ...` (in a terminal).

- Selecting a profile only affects the next Start / Restart; only one profile can hold port 3080 at
  a time — **switching = restarting the service with the new profile**.
- The last selection is remembered; the "running profile" row shows what is actually running (started by this app).
- The launch command is `dsh --profile <name> --port 3080 --no-open` (`dsh web` is just an alias of `--profile web`).

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
Source layout: `Sources/main.swift` (launchd management, install/update, the AppModel state store) +
`Sources/MainWindow.swift` (the SwiftUI main window).

## Technical notes

- **Fully manual lifecycle**: the service LaunchAgent (`com.dsh.web`) has neither `RunAtLoad` nor
  `KeepAlive` — no login auto-start, no crash self-healing; start/stop is entirely under your
  control from the main window, and quitting the app never tears the service down.
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
- **Dual-channel update check**: 10s after launch and every 6 hours the app checks two channels silently:
  · **npm registry** (both `latest` and `next` dist-tags of `@deepseek-ai/dsh`, taking the higher
  semver version) — the only channel the one-click upgrade uses, compared against the installed
  version per SemVer 2.0 (correctly handling rc/alpha/beta prerelease numbers). When a newer
  version exists the main window shows an "Update → vX" button; targets from the `next` prerelease
  channel are marked as such. One click runs `npm install -g @deepseek-ai/dsh@<target>` (the
  exact detected version, not @latest).
  · **GitHub Releases** (deepseek-ai/deepseek-harness) — official releases sometimes run ahead of
  npm (e.g. alpha builds absent from npm). The info section shows the latest "GitHub Release"
  version, badges it "not on npm" and offers a "View Release" link; this channel is informational
  only (releases ship no artifacts to auto-install).
  Update log: `~/Library/Logs/DSHLauncher/dsh-update.log`.
- **Log rotation**: `dsh-web.log` is auto-rotated to `.1` before the next service restart once
  it exceeds 20MB, preventing unbounded disk growth.

## Uninstall dsh

Done with dsh? Click **Uninstall dsh** in the main window (shown only while installed), then pick one:

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

The service is an independent LaunchAgent — stop it in the main window first (or just use the bootout below), then:

```bash
launchctl bootout gui/$(id -u)/com.dsh.web 2>/dev/null
launchctl bootout gui/$(id -u)/com.dsh.menubar 2>/dev/null
rm -f ~/Library/LaunchAgents/com.dsh.web.plist ~/Library/LaunchAgents/com.dsh.menubar.plist
rm -rf ~/Applications/DSH\ Launcher.app
```
