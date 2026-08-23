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
- `snapshot.js`: Snapshot Adapter — stateless pure functions for parsing
  `herdr api snapshot` output, building agent records, and diffing per-pane
  state between polls. Imported by `Service.qml`; tested via Node.js.
- `Service.qml`: the data layer. Polls `herdr api snapshot` on a timer,
  delegates parsing to the Snapshot Adapter, keeps a live `ListModel` of
  agents, detects state transitions, and emits Omarchy desktop toasts.
- `hyprland.py`: Hyprland Window Adapter — class-based module that owns all
  Hyprland interaction: client discovery (`hyprctl -j clients`), process tree
  inspection, client ranking, special workspace management, and window raising.
  Constructed with an injected `herdr_checker` for testability.
- `Panel.qml`: the bar icon (tint + busy-count badge) and the
  `KeyboardPanel` agent list. Clicking or Entering a row calls
  `service.focusAgent(paneId)`.
- `bin/omarchy-herdr-focus`: Python (stdlib) orchestrator that focuses the
  agent inside the Herdr TUI, then delegates to the Hyprland Window Adapter
  for window discovery and raising.
- `install.sh` / `uninstall.sh`: idempotent user-level install/removal via
  plugin symlink + shell plugin commands.
- `tests/test_snapshot.py`: Node.js-backed unit tests for the Snapshot Adapter.
- `tests/test_hyprland.py`: unit tests for the Hyprland Window Adapter.
- `tests/test_herdr_focus.py`: orchestrator-only unit tests for the focus
  helper's flow control.

## Runtime Flow

`Service.qml` polls `herdr api snapshot` every `refreshIntervalSec` (default
2s; 1s while the panel is open). The first successful poll establishes a
baseline — no notifications for agents already running. Later polls diff
per-pane state:

- into `blocked` → toast "needs attention" (critical) when `notifyOnBlocked`
- `working` → `done` → toast "finished" (normal) when `notifyOnFinished`
- a previously blocked pane vanishing between polls → toast "agent gone"
  (normal) when `notifyOnBlocked`

The state toasts carry an Omarchy `--exec` action
(`'<focus-helper>' '<paneId>'`), so clicking the toast itself jumps to the
agent. Toasts go through `$OMARCHY_PATH/bin/omarchy-notification-send` via
`Quickshell.execDetached`, matching how the reminders plugin notifies.

The ListModel is updated in place (roles mutated, items appended/removed) so
the panel keeps its scroll position across polls; `resortModel()` then does a
stable partition (`ListModel.move`) pinning blocked rows to the top. The
panel's keyboard cursor tracks the selected agent by `paneId`, never by row
index, so reordering cannot strand it.

A click calls the focus helper through a guarded Quickshell `Process`
(`Service.qml`), passing `<paneId>` and the optional `windowClass` setting;
the helper:

1. runs `herdr agent focus <paneId>` (focuses inside the Herdr TUI),
2. finds the Herdr window among `hyprctl -j clients` by walking each client
   pid's `/proc` tree for a process named `herdr`, scoring all matches so a
   mapped, unhidden window on a normal workspace wins,
3. opens the hosting special workspace with `hl.dsp.workspace.toggle_special`
   when that workspace is not already shown on any monitor,
4. falls back to the best-ranked client matching the given window class
   (`class`/`initialClass`, case-insensitive) when no process tree matched —
   for Herdr over SSH in a local terminal,
5. dispatches `hl.dsp.focus({ window = "address:<addr>" })`, which switches
   the active Hyprland workspace and raises the window.

A non-zero helper exit surfaces as a critical "could not jump" toast using
the collected stderr; partial success (window raised despite herdr-side
failure) still exits 0.

If Hyprland is unavailable or no local Herdr window exists (headless/remote),
steps 2–5 are skipped; the in-TUI focus still applies.

When herdr is unreachable, counts reset to zero, the bar icon dims to
`Color.muted`, and the panel shows a "Launch Herdr" button that runs
`$OMARCHY_PATH/bin/omarchy-launch-terminal-herdr`.

Global keybinds jump without opening the panel: IPC `focus` targets the first
blocked agent (else the first row) and `focusAgent <name>` a named agent;
both run the same focus helper path.

## Correctness Invariants

- The first successful snapshot after (re)load is the baseline; never notify
  for state "changes" that merely reflect plugin startup.
- Notify only on real transitions (`blocked` entry, `working`→`done`); never
  spam on re-polls of a stable state.
- Neither the polling Process nor the click-to-jump Process may ever be
  started twice (guard on `running`).
- Keep the in-place model sync: never `clear()`+`append()` the ListModel,
  which would reset panel scroll/cursor.
- The panel keyboard cursor is keyed by `paneId`, never row index; reordering
  (blocked pinned to top) must not strand or retarget the cursor.
- The focus helper identifies the Herdr window by process tree, never by
  window title: Herdr sets the title to `{hostname}: {workspace}`, which
  changes as the active workspace changes. The class fallback only applies
  when no process tree matched.
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
- Add snapshot adapter tests in `tests/test_snapshot.py` when changing the
  Herdr snapshot format or record-building logic.
- Add Hyprland adapter tests in `tests/test_hyprland.py` when changing window
  ranking, class matching, or special workspace handling.
- Update `README.md` when user-visible behavior or settings change.
- Update `docs/design.md` when the data source, poll cadence, notification
  rules, or focus mechanics change.

## Agent skills

### Issue tracker

Issues are tracked on GitHub (`mrpbennett/qs-herdr-agents`) via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles use their default label strings (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout: one `CONTEXT.md` plus `docs/adr/` at the repo root. See `docs/agents/domain.md`.
