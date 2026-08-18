#!/bin/bash

# Remove the Herdr Agents Omarchy plugin: disable it in the shell, drop the
# symlink, and rescan. User config in shell.json is left otherwise intact.
# Idempotent: safe to rerun. Install with ./install.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ID="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["id"])' "$ROOT/manifest.json")"
PLUGIN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$PLUGIN_ID"

if omarchy plugin list --json 2>/dev/null | jq -e --arg id "$PLUGIN_ID" \
  'any(.[]; .id == $id and (.enabled == true))' >/dev/null 2>&1; then
  omarchy plugin disable "$PLUGIN_ID"
  echo "disabled $PLUGIN_ID"
fi

if [[ -L "$PLUGIN_DIR" ]]; then
  target="$(readlink "$PLUGIN_DIR")"
  if [[ "$target" == "$ROOT" || "$(readlink -f "$target")" == "$ROOT" ]]; then
    rm "$PLUGIN_DIR"
    echo "removed symlink $PLUGIN_DIR"
  else
    echo "warning: $PLUGIN_DIR is a symlink to something else ($target); leaving it" >&2
  fi
elif [[ -e "$PLUGIN_DIR" ]]; then
  echo "warning: $PLUGIN_DIR is not a symlink; leaving it for manual review" >&2
fi

omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
echo "Herdr Agents uninstalled."
