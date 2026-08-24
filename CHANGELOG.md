# Changelog

All notable changes to the Herdr Agents plugin will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and
this project adheres to [Semantic Versioning](https://semver.org/).

## [0.2.2] — 2026-08-24

### Fixed
- Bar icon hover tooltip was broken: `PanelToolTip` bound to
  `button.containsMouse`, but `BarIconButton` does not expose that property.
  Replaced with the built-in `tooltipText` property on `BarIconButton`, which
  uses the bar's own tooltip system.

## [0.2.1] — 2026-08-23

### Added
- **Snapshot Adapter** (`snapshot.js`) — stateless pure functions (`parse`,
  `basename`, `isActive`, `buildRecords`, `diffRecords`) extracted from
  `Service.qml` for parsing Herdr snapshot data. Tested via Node.js.
- **Hyprland Window Adapter** (`hyprland.py`) — class-based module
  (`HyprlandWindow`) owning all Hyprland interaction: client discovery,
  process tree inspection, client ranking, special workspace management,
  and window raising. Constructed with an injected `herdr_checker` for
  testability.
- `tests/test_snapshot.py` — Node.js-backed unit tests for the Snapshot
  Adapter.
- `tests/test_hyprland.py` — unit tests for the Hyprland Window Adapter.

### Changed
- `bin/omarchy-herdr-focus` is now a thin orchestrator: focuses the agent
  inside the Herdr TUI, then delegates to `HyprlandWindow` for window
  discovery and raising.
- `Service.qml` delegates parsing to the Snapshot Adapter (`Snap.parse`,
  `Snap.buildRecords`, `Snap.diffRecords`).
- `tests/test_herdr_focus.py` now tests only the orchestrator's flow control;
  Hyprland-specific tests live in `tests/test_hyprland.py`.
- Deduplicated `_run` helper — orchestrator imports from `hyprland` instead
  of defining its own copy.
- Extracted `_hyprctl_json` in `HyprlandWindow` to share the
  run-hyprctl-parse-JSON shape between `hyprctlClients` and
  `_hyprctl_monitors`.

### Fixed
- `snapshot.js` header comment referenced wrong test file path
  (`test_snapshot.js` → `test_snapshot.py`).
- `AGENTS.md` and `docs/design.md` updated to document the new module
  boundaries and test locations.

## [0.2.0] — 2026-08-23

### Added
- **Clickable toasts** — "needs attention" and "finished" toasts now carry a
  shell command; clicking the toast jumps straight to the agent.
- **IPC `focusAgent <name>`** — jump to a running agent by name via
  `omarchy-shell ipc call mrpbennett.herdr-agents focusAgent <name>`.
- **Blocked-first `focus()`** — the IPC `focus` action now targets the first
  blocked agent, falling back to the first row.
- **Blocked agents pinned to top** — `resortModel()` stable-partitions the
  list so blocked rows are always visible at a glance.
- **PaneId-keyed cursor** — the panel keyboard cursor tracks agents by
  `paneId`, not row index, so reordering cannot strand it.
- **Window class fallback** — `windowClass` setting for Herdr-over-SSH
  setups where the process tree cannot be inspected locally.
- **Launch Herdr button** — when herdr is not running, the panel offers a
  button that launches the terminal.
- **Agent gone toast** — a blocked agent vanishing between polls surfaces as
  a normal-priority toast (gated by `notifyOnBlocked`).
- **Bar icon dims when disconnected** — the sheep glyph turns `Color.muted`
  while herdr is unreachable; counts reset on failure.
- **Focus watchdog** — a 10-second timer kills hung focus helpers so the
  running guard cannot lock out future jumps.
- **Elapsed time** — each agent row shows how long the agent has been in its
  current status (e.g. "3m 12s").
- **Search / filter** — type `/` or `f` in the panel to filter agents by
  name, workspace, or folder; Escape clears.
- **Bar icon tooltip** — hovering the sheep icon shows a one-line fleet
  summary without opening the panel.
- **Reconnect toast** — a normal-priority toast fires when herdr comes back
  online after being down.
- **Exponential backoff** — poll interval doubles on consecutive failures
  (up to 30s), resetting on success.
- **Config validation** — startup warnings for out-of-range
  `refreshIntervalSec` or empty `windowClass`.
- **Shell-safe quoting** — `jumpCommand` escapes single quotes in pane IDs.
- **Subprocess timeouts** — the focus helper enforces per-call timeouts
  (5s for herdr, 3s for hyprctl).

### Changed
- `client_rank` now detects special workspaces by name (`special:` prefix)
  instead of workspace ID sign, matching `ensure_special_visible`.
- `process_has_herdr` iterates all `/proc/<pid>/task/*/children` files
  (all threads), not just the main thread's children file.
- `syncModel` uses an O(1) `paneId→index` map instead of O(n) linear scans.
- Hint text updated to include keyboard shortcuts:
  `/ filter · ↑↓ navigate · Enter to jump · r refreshes`.
- `applySnapshot` guards against non-object JSON results before accessing
  `.result.snapshot`.

### Fixed
- `applySnapshot` no longer crashes when `JSON.parse` returns a non-object.
- `tasks/todo.md` notification plan corrected (`working→done`, not
  `working→idle`).

## [0.1.0] — 2026-08-20

### Added
- Initial release: bar icon, agent panel, click-to-jump, state-change
  toasts, poll-based snapshot sync, in-place ListModel updates.
