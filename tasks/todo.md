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
  - left `working` into `idle`/`done` -> notify "finished" (normal)
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

- [ ] Plugin id `mrpbennett.herdr-agents`, right bar section (with sesh/docker).
- [ ] State-change desktop toasts included (toggleable, default on).
- [ ] Poll interval default 2s.
