# herdr-menubar

A tiny macOS menu bar indicator for herdr agent sessions.

- `●` dim: nothing needs you (`● 2` = two agents working)
- `● N` pulsing **orange**: N agents finished and you haven't looked yet
- `● N` pulsing **red**: at least one agent is blocked waiting on you
- `◌`: herdr isn't running

A pane you are already looking at (focused in herdr, with iTerm2 frontmost) doesn't alert.
Click the icon for a per-workspace list; picking a row focuses that pane in herdr and brings iTerm2 forward.

## How it works

It subscribes to herdr's socket API (`~/.config/herdr/herdr.sock`) for pane/tab/workspace events.
`pane_updated` events are applied in place; other events trigger a debounced `session.snapshot`.
It reconnects automatically if herdr restarts.

## Install

```bash
scripts/install.sh   # builds, copies to ~/Applications, starts at login via LaunchAgent
```

or just `scripts/build-app.sh && open build/HerdrMenubar.app`.

Uninstall: `launchctl bootout gui/$(id -u)/dev.herdr-menubar && rm -rf ~/Applications/HerdrMenubar.app ~/Library/LaunchAgents/dev.herdr-menubar.plist`

**Status:** early. It builds and connects to herdr's socket; the pulse, alert colors, and click-to-focus have not been verified visually yet.

Requires macOS 13+ and the Swift toolchain (Command Line Tools is enough). If you use a terminal other than iTerm2, change `terminalBundleID` in `StatusItem.swift`.
