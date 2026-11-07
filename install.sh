#!/bin/bash
# Builds and installs usage-tracker. "./install.sh uninstall" reverses it.
set -euo pipefail

cd "$(dirname "$0")"

BIN="$HOME/.local/bin/usage-tracker"
LABEL="local.usage-tracker"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SETTINGS="$HOME/.claude/settings.json"
DATA_DIR="$HOME/.claude/usage-tracker"
PREFIX="$BIN --statusline | "
DOMAIN="gui/$(id -u)"

current_command() {
  jq -r '.statusLine.command // empty' "$SETTINGS"
}

set_command() {
  local tmp
  tmp=$(mktemp "$SETTINGS.XXXXXX")
  jq --arg command "$1" '.statusLine.command = $command' "$SETTINGS" >"$tmp"
  chmod "$(stat -f %Lp "$SETTINGS")" "$tmp"
  mv "$tmp" "$SETTINGS"
}

stop_agent() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
}

write_plist() {
  cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
</dict>
</plist>
EOF
}

do_install() {
  local command
  command=$(current_command)
  if [ -z "$command" ]; then
    echo "No statusLine.command in $SETTINGS." >&2
    echo "Set up a status line first: this tool pipes into it." >&2
    exit 1
  fi

  mkdir -p "$(dirname "$BIN")" "$(dirname "$PLIST")"
  swiftc -O main.swift selfcheck.swift -o "$BIN.new"
  "$BIN.new" --self-check || {
    rm -f "$BIN.new"
    exit 1
  }
  # Replace rather than overwrite: macOS can kill a binary rewritten in place.
  mv -f "$BIN.new" "$BIN"

  write_plist
  stop_agent
  launchctl bootstrap "$DOMAIN" "$PLIST"

  if [[ "$command" != "$PREFIX"* ]]; then
    set_command "$PREFIX$command"
  fi
  echo "Installed. Limits appear after the next Claude Code response."
}

do_uninstall() {
  local command
  command=$(current_command)
  # Restore the status line first so it never points at a missing binary.
  if [[ "$command" == "$PREFIX"* ]]; then
    set_command "${command#"$PREFIX"}"
  fi
  stop_agent
  rm -f "$PLIST" "$BIN" "$DATA_DIR/rate-limits.json"
  rmdir "$DATA_DIR" 2>/dev/null || true
  echo "Uninstalled."
}

case "${1:-install}" in
  install) do_install ;;
  uninstall) do_uninstall ;;
  *)
    echo "usage: $0 [install | uninstall]" >&2
    exit 2
    ;;
esac
