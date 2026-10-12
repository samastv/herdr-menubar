#!/bin/bash
# Installs the app to ~/Applications and starts it at login via a LaunchAgent.
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL="dev.herdr-menubar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

./scripts/build-app.sh
mkdir -p "$HOME/Applications" "$(dirname "$PLIST")"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# bootout returns before the process is gone; a straggler would hold the old binary and a second status item.
pkill -x HerdrMenubar || true
while pgrep -x HerdrMenubar >/dev/null; do sleep 0.1; done
rm -rf "$HOME/Applications/HerdrMenubar.app"
cp -R build/HerdrMenubar.app "$HOME/Applications/"

sed "s|__HOME__|$HOME|g" launchd/$LABEL.plist > "$PLIST"
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed; running as $LABEL"
