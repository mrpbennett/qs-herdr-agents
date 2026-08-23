# Herdr Agents — Omarchy plugin plan

Bar-widget plugin that turns the Herdr agent fleet into a live, clickable
Omarchy shell widget.

## Goal

One bar icon + one panel that shows every running Herdr agent, its current
state/progress, and the Herdr workspace it lives in. Clicking an agent raises
the Herdr window anywhere on the desktop and focuses that agent.

## Data source (verified)

- `herdr api snapshot` — single JSON call: agents[], workspaces[] (labels),
  focused workspace/tab/pane, protocol version. One poll = full picture.
- Agent fields used: `agent` (kind), `agent_status` (idle/working/blocked/
  done/unknown), `terminal_title_stripped` (progress), `cwd`, `pane_id`,
  `workspace_id`, `focused`.
- Workspace fields used: `workspace_id`, `label`.

## Focus mechanics (verified on Hyprland 0.56)

- `herdr agent focus <pane_id>` — focuses the pane inside the Herdr TUI.
- `hyprctl dispatch 'hl.dsp.focus({ window = "address:0x..." })'` — switches
  the active Hyprland workspace and focuses the Herdr terminal window.
- Herdr window found by scanning `hyprctl -j clients` and matching a terminal
  whose `/proc` subtree runs a `herdr` process (title is unstable: it tracks
  the active workspace label).

## Notification mechanics (verified)

- `Quickshell.execDetached([OMARCHY_PATH + "/bin/omarchy-notification-send", headline, body, "-g", glyph, "-u", urgency])`
  emits an Omarchy desktop toast. Test notification returned rc=0.

## File layout

```
manifest.json          plugin metadata + bar-widget defaults/schema
Panel.qml              bar icon + KeyboardPanel agent list
Service.qml            snapshot polling, model, state-change notifications
bin/omarchy-herdr-focus  focus agent + raise Herdr window (python stdlib)
install.sh             symlink into ~/.config/omarchy/plugins/ + bar layout entry
uninstall.sh           symmetric removal
AGENTS.md              agent guide
README.md              user docs
docs/design.md         architecture + verified API notes
tests/                 python unittest for the focus helper logic
tasks/todo.md          this plan
```

## Service design

- Poll `herdr api snapshot` via `Process` every `refreshIntervalSec` (default 2).
- Build a `ListModel` of agents with roles: name, status, title, folder, cwd,
  workspaceLabel, workspaceId, paneId, focused.
- First successful poll is the baseline (no notifications).
- On later polls, diff state per pane:
  - entered `working` -> notify "started working" (normal)
  - left `working` into `done` -> notify "finished" (normal)
  - entered `blocked` -> notify "needs attention" (critical)
- Each toggle is a setting; default: notifications on.
- `connected` / `lastError` surfaced to the panel (herdr down, no session).

## Panel design

- Bar button: agent glyph, status tint (accent = working, urgent = blocked),
  static icon, count badge of non-idle agents.
- Panel: hero (connected + count), scrollable agent rows. Row = status dot +
  name + workspace label + progress title (elided) + cwd folder + focused
  mark. Click / Enter -> `bin/omarchy-herdr-focus <pane_id>`.
- Empty states: "No agents running" / "Herdr is not running".

## Decisions to confirm

- [x] Plugin id `mrpbennett.herdr-agents`, right bar section (with sesh/docker).
- [x] State-change desktop toasts included (toggleable, default on).
- [x] Poll interval default 2s.

## Round 2 — jump-from-anywhere reliability

Click-to-jump must work even when the Herdr window sits in a special
workspace (scratchpad/minimize emulation), is hidden, or when several
terminals run herdr. Failed jumps must be visible instead of silent.

- [x] Helper: score candidate windows — prefer mapped + not hidden + normal
      workspace; fall back to special-workspace/hidden/unmapped matches
      (ties keep hyprctl order).
- [x] Helper: open the hosting special workspace before focusing
      (`hl.dsp.workspace.toggle_special`) unless a monitor already shows it;
      skip silently when `hyprctl -j monitors` is unavailable.
- [x] Helper: unit tests for candidate scoring and special-workspace logic.
- [x] Service: run the focus helper through a guarded Process and toast on
      failure (stderr detail), replacing fire-and-forget execDetached.
- [x] Docs: README "Click to jump", docs/design.md focus mechanics +
      limitations, AGENTS.md runtime flow.

### Review

- All matching clients are scored, not just the first proc-tree hit.
- Special workspaces open only when not already displayed on any monitor,
  so an already-visible scratchpad is never toggled closed.
- Focus runner guards on `running` like the poll process; panel close does
  not affect it (Service outlives the panel).
- Exit-code semantics unchanged: partial success (window raised despite a
  herdr-side failure) still exits 0, warned on stderr only.

## Round 3 — take-me-there from anywhere

- [x] Clickable toasts: state toasts carry `--exec '<helper>' '<paneId>'`;
      clicking "needs attention"/"finished" jumps to that agent.
- [x] IPC: `focus()` now jumps blocked-first; new `focusAgent <name>`.
- [x] Blocked agents pinned to top via stable-partition `resortModel()`;
      panel cursor re-keyed from row index to `paneId` so reordering cannot
      strand it.
- [x] Remote fallback: `windowClass` setting passed as helper arg 2;
      best-ranked class/initialClass match when no proc tree matched.
- [x] "Launch Herdr" button in the disconnected panel state
      (`omarchy-launch-terminal-herdr`, verified present).
- [x] Version 0.2.0 + CHANGELOG.md.
- [x] "Agent gone" toast when a previously blocked pane vanishes between
      polls (gated by notifyOnBlocked).
- [x] Bar icon dims to muted while herdr unreachable; counts reset on poll
      failure so the badge cannot go stale.

### Review

- Toast exec strings single-quote path and pane id; blank class arg is a
  no-op in the helper, so passing it unconditionally is safe.
- resortModel only ever moves delegates (ListModel.move), preserving model
  identity — scroll and hover survive; cursor follows the agent.
- detectExit walks panes missing from the current snapshot; herdr restarts
  reset the baseline first, so they never fire false "agent gone" toasts.
- Launch button uses Omarchy's own herdr terminal launcher rather than
  guessing a terminal emulator.
- 26 unit tests pass; manifest validates with the new string schema entry.
