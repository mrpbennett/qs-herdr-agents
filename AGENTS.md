# Agent Guide

## What This Application Does

`mrpbennett.herdr-agents` is an Omarchy `bar-widget` plugin that surfaces the
live state of a Herdr session in the status bar. It shows every running Herdr
agent, what the agent is currently doing, and which Herdr workspace it runs
in, and it jumps straight to an agent inside Herdr when clicked — from any
Hyprland workspace.

Read `README.md` for user-facing behavior and `docs/design.md` for the
verified API details.

## Architecture

- `manifest.json`: Omarchy plugin metadata and bar-widget entry point.
- `Service.qml`: the data layer. Polls `herdr api snapshot` on a timer, keeps
  a live `ListModel` of agents, detects state transitions, and emits Omarchy
  desktop toasts.
- `Panel.qml`: the bar icon (tint + busy-count badge) and the
  `KeyboardPanel` agent list. Clicking or Entering a row calls
  `service.focusAgent(paneId)`.
- `bin/omarchy-herdr-focus`: Python (stdlib) helper that runs
  `herdr agent focus <target>` and then raises the Herdr terminal window with
  a Hyprland dispatch.
- `install.sh` / `uninstall.sh`: idempotent user-level install/removal via
  plugin symlink + shell plugin commands.
- `tests/test_herdr_focus.py`: stdlib `unittest` coverage for the helper.

## Runtime Flow

`Service.qml` polls `herdr api snapshot` every `refreshIntervalSec` (default
2s; 1s while the panel is open). The first successful poll establishes a
baseline — no notifications for agents already running. Later polls diff
per-pane state:

- into `blocked` → toast "needs attention" (critical) when `notifyOnBlocked`
- `working` → `done` → toast "finished" (normal) when `notifyOnFinished`

Toasts go through `$OMARCHY_PATH/bin/omarchy-notification-send` via
`Quickshell.execDetached`, matching how the reminders plugin notifies.

The ListModel is updated in place (roles mutated, items appended/removed) so
the panel keeps its scroll position and keyboard cursor across polls.

A click calls `Quickshell.execDetached([focusHelper, paneId])`. The helper:

1. runs `herdr agent focus <paneId>` (focuses inside the Herdr TUI),
2. finds the Herdr window among `hyprctl -j clients` by walking each client
   pid's `/proc` tree for a process named `herdr`,
3. dispatches `hl.dsp.focus({ window = "address:<addr>" })`, which switches
   the active Hyprland workspace and raises the window.

If Hyprland is unavailable or no local Herdr window exists (headless/remote),
step 2/3 is skipped; the in-TUI focus still applies.

## Correctness Invariants

- The first successful snapshot after (re)load is the baseline; never notify
  for state "changes" that merely reflect plugin startup.
- Notify only on real transitions (`blocked` entry, `working`→`done`); never
  spam on re-polls of a stable state.
- The polling Process must never be started twice (guard on `running`).
- Keep the in-place model sync: never `clear()`+`append()` the ListModel,
  which would reset panel scroll/cursor.
- The focus helper identifies the Herdr window by process tree, never by
  window title: Herdr sets the title to `{hostname}: {workspace}`, which
  changes as the active workspace changes.
- The Hyprland dispatch is the 0.56 Lua form
  `hl.dsp.focus({ window = "address:0x…" })`; legacy `focuswindow class:…`
  is broken on 0.56.
- Installer changes must remain idempotent and have a symmetric uninstall path
  that leaves the rest of the user's `shell.json` untouched.

## Development Workflow

Run the unit tests and static checks:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
bash -n install.sh uninstall.sh
omarchy plugin validate .
git diff --check
```

`qmllint` works for syntax-level checks when pointed at a mirrored
`qs.*` module layout; the shell's own module resolution differs, so most
remaining warnings (unresolved `bar`/`Style` singletons, `exited` signal
parameter) are false positives shared with the working first-party plugins.

Do not run `install.sh`, `uninstall.sh`, or live focus tests merely as generic
verification — they modify the user's installed shell state. The unit tests
mock the subprocess boundaries instead.

## Change Guidance

- Add focused regressions in `tests/test_herdr_focus.py` for window finding
  and exit-code semantics.
- Update `README.md` when user-visible behavior or settings change.
- Update `docs/design.md` when the data source, poll cadence, notification
  rules, or focus mechanics change.
