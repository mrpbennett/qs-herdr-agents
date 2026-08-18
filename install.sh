#!/bin/bash

# Install the Herdr Agents Omarchy plugin (user-level, no sudo): symlink the
# plugin into the shell plugin directory, make the focus helper executable,
# then discover and place the bar widget in the right bar section.
# Idempotent: safe to rerun. Uninstall with ./uninstall.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ID="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["id"])' "$ROOT/manifest.json")"
PLUGINS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins"
PLUGIN_DIR="$PLUGINS_DIR/$PLUGIN_ID"

install -d "$PLUGINS_DIR"

if [[ -e "$PLUGIN_DIR" || -L "$PLUGIN_DIR" ]]; then
  current="$(readlink -f "$PLUGIN_DIR")"
  if [[ "$current" != "$ROOT" ]]; then
    echo "error: $PLUGIN_DIR already exists and is not this project ($ROOT)" >&2
    exit 1
  fi
  echo "plugin symlink already present: $PLUGIN_DIR"
else
  ln -s "$ROOT" "$PLUGIN_DIR"
  echo "linked $PLUGIN_DIR -> $ROOT"
fi

chmod +x "$ROOT/bin/omarchy-herdr-focus"
echo "focus helper is executable: $ROOT/bin/omarchy-herdr-focus"

# The shell only knows about plugins it has discovered; a brand-new symlink
# needs a rescan before it can be placed in the bar.
if ! omarchy-shell shell rescanPlugins >/dev/null 2>&1; then
  echo "warning: could not rescan plugins; run 'omarchy restart shell' after installing" >&2
fi

if omarchy plugin list --json 2>/dev/null | jq -e --arg id "$PLUGIN_ID" \
  'any(.[]; .id == $id and (.enabled == true))' >/dev/null 2>&1; then
  echo "plugin already enabled: $PLUGIN_ID"
else
  omarchy plugin enable "$PLUGIN_ID" --section right
fi

echo "Herdr Agents installed. Widget is live in the right bar section."
