# Design

Verified API details and architecture for the Herdr Agents plugin.

## Data source: `herdr api snapshot`

`Service.qml` polls one command, `herdr api snapshot`, and parses its
`result.snapshot`. The snapshot is a single JSON document (protocol 20)
containing `agents[]`, `workspaces[]`, `tabs[]`, `panes[]`, `layouts[]`, and
the focused pane/tab/workspace ids.

Agent records used by the plugin:

| Field | Purpose |
| --- | --- |
| `agent` | Agent kind, e.g. `opencode` (also the name shown). |
| `agent_status` | `idle`, `working`, `blocked`, `done`, `unknown`. |
| `terminal_title_stripped` | The agent's current activity, used as progress. |
| `cwd` | Working directory; its basename is the folder shown. |
| `pane_id` | Stable target for `herdr agent focus`. |
| `workspace_id` | Key into the workspaces array. |
| `focused` | Whether the agent is under the Herdr cursor. |

Workspace records provide `workspace_id` → `label` (e.g. `qs-herdr-agents`).

## Poll cadence

A `Timer` runs a `Process` that executes `herdr api snapshot`. The interval is
`refreshIntervalSec` (default 2s) normally, tightened to 1s while the panel is
open. The `Process` guards on `running` so a poll can never overlap itself. On
failure (server down, herdr missing) the plugin flips `connected = false`,
drops its baseline, and reports the error; the next successful poll re-baselines.

## Notifications

Only real transitions notify, gated by settings and a first-poll baseline:

| Transition | Toast | Urgency |
| --- | --- | --- |
| any → `blocked` | "needs attention" | `critical` |
| `working` → `done` | "finished" | `normal` |

`working → idle` intentionally does not toast: `idle` after a turn usually
means the tab is seen, so the user is already watching. `done` is the unseen
background-work completion herdr reports, which is the case worth a toast.

Toasts are emitted with `Quickshell.execDetached([...omarchy-notification-send,
headline, body, "-g", "󰳆", "-u", urgency])` so they render in the Omarchy
notification service like every other first-party toast.

## Model sync

The agent `ListModel` is updated in place: panes no longer present are removed,
new panes appended, and existing rows have their roles mutated. This preserves
the panel's scroll offset and keyboard cursor across 2s polls. The `Repeater`
in `Panel.qml` binds roles (`name`, `status`, `title`, `folder`,
`workspaceLabel`, `focused`) to `required property` delegates.

## Focus mechanics

`Panel.qml` calls `service.focusAgent(paneId)`, which runs
`bin/omarchy-herdr-focus <paneId>` detached. Verified on Hyprland 0.56.2:

1. `herdr agent focus <paneId>` moves Herdr's cursor to the agent's
   workspace/tab/pane. This is a server API call and works regardless of
   where the Herdr window is (or whether it exists at all).
2. The helper scans `hyprctl -j clients`, and for each window walks
   `/proc/<pid>/task/<pid>/children` recursively for a process named `herdr`.
   The matching window's `address` is used to dispatch
   `hl.dsp.focus({ window = "address:0x…" })`.
3. Hyprland 0.56 switches the active workspace to the focused window, so the
   Herdr window is raised from any workspace.

The Herdr window must be found by process tree, not by window title: herdr's
`window_title = "{hostname}: {workspace}"` changes whenever the active
workspace changes. If Hyprland is unavailable or no local window runs herdr
(headless server, `--remote` attach), steps 2–3 are skipped and the in-TUI
focus still applies.

## Install / uninstall

`install.sh` symlinks the project into
`~/.config/omarchy/plugins/mrpbennett.herdr-agents`, chmods the helper, runs
`omarchy-shell shell rescanPlugins`, and enables the widget in the right bar
section via `omarchy plugin enable`. `uninstall.sh` disables the plugin,
removes only the symlink (verifying its target), and rescans. Neither script
touches the rest of `shell.json`; both are idempotent.

## Known limitations

- One Herdr window: if several terminal windows each run a `herdr` process,
  the helper raises the first match found.
- `done`/`idle` semantics come from herdr (focusing a tab marks it seen); the
  plugin only observes them.
- The panel shows agent kind as the name; herdr's live agent name (`agent
  rename`) is not yet read from the snapshot.
