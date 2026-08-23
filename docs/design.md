# Design

Verified API details and architecture for the Herdr Agents plugin.

## Modules

The codebase is split into focused modules with narrow interfaces:

- **Snapshot Adapter** (`snapshot.js`): stateless pure functions that parse
  `herdr api snapshot` output, build per-pane agent records, and diff
  consecutive snapshots. Imported by `Service.qml` as `Snap`. Tested via
  Node.js subprocess evaluation.
- **Hyprland Window Adapter** (`hyprland.py`): class-based module
  (`HyprlandWindow`) that owns all Hyprland interaction — client discovery,
  process tree inspection, client ranking, special workspace management, and
  window raising. Constructed with an injected `herdr_checker` callable for
  testability.
- **Focus Helper** (`bin/omarchy-herdr-focus`): thin orchestrator that focuses
  the agent inside Herdr TUI, then delegates to `HyprlandWindow` for window
  discovery and raising.
- **Service** (`Service.qml`): polls, delegates parsing to the Snapshot
  Adapter, keeps the ListModel in sync, detects transitions, emits toasts.
- **Panel** (`Panel.qml`): bar icon and agent list UI.

## Snapshot Adapter interface

`snapshot.js` exports five functions:

| Function | Signature | Purpose |
| --- | --- | --- |
| `parse` | `(raw: string) → { snapshot, error }` | Parse raw JSON; error is a string on failure. |
| `basename` | `(path: string) → string` | Derive basename from a path. |
| `isActive` | `(status: string) → boolean` | True for working/blocked/done. |
| `buildRecords` | `(snapshot, stateByPane) → { byPane, counts }` | Build per-pane agent records. Mutates `stateByPane` for enteredAt tracking. |
| `diffRecords` | `(prevByPane, currByPane) → { added, removed, transitions }` | Diff two pane maps. |

`Service.qml` calls `Snap.parse`, `Snap.buildRecords`, and `Snap.diffRecords`
in `applySnapshot`. The `stateByPane` parameter is Service's `_enteredAt` map,
which the adapter mutates to track when agents entered their current status.

## Hyprland Window Adapter interface

`HyprlandWindow.__init__(herdr_checker, hyprctl_bin)` — `herdr_checker` is a
callable `(pid: int) -> bool` that walks `/proc` to detect a `herdr` process.

| Method | Signature | Purpose |
| --- | --- | --- |
| `findClient` | `(clients) → Client \| None` | Best client whose process tree runs herdr. |
| `findByClass` | `(clients, window_class) → Client \| None` | Best-ranked client matching window class. |
| `ensureVisible` | `(client) → bool` | Open special workspace if hidden. |
| `raiseWindow` | `(address) → (ok, detail)` | Focus window by address (Hyprland 0.56+). |
| `hyprctlClients` | `() → list \| None` | Query compositor for all clients. |

Client ranking (lower is better): 0 = mapped, visible, normal workspace; 1 =
special workspace; 2 = hidden; 3 = unmapped.

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
drops its baseline, zeroes its counts (so the bar badge cannot go stale), and
reports the error; the next successful poll re-baselines.

## Notifications

Only real transitions notify, gated by settings and a first-poll baseline:

| Transition | Toast | Urgency |
| --- | --- | --- |
| any → `blocked` | "needs attention" | `critical` |
| `working` → `done` | "finished" | `normal` |
| blocked pane vanishes between polls | "agent gone" | `normal` |

The pane-vanish case covers an agent that is dealt with (or dies) entirely
between two polls: the diff loop also walks previous panes missing from the
current snapshot. Only previously-blocked agents announce this — a working
agent disappearing usually means its tab was closed on purpose.

`working → idle` intentionally does not toast: `idle` after a turn usually
means the tab is seen, so the user is already watching. `done` is the unseen
background-work completion herdr reports, which is the case worth a toast.

Toasts are emitted with
`Quickshell.execDetached([...omarchy-notification-send, headline, body, "-g", "󰳆", "-u", urgency])`
so they render in the Omarchy notification service like every other
first-party toast. The state toasts additionally pass
`--exec "'<focus-helper>' '<paneId>'"`; Omarchy runs that command when the
toast itself is clicked, so a click on "needs attention" jumps straight to
the agent.

## Model sync

The agent `ListModel` is updated in place: panes no longer present are removed,
new panes appended, and existing rows have their roles mutated. This preserves
the panel's scroll offset and keyboard cursor across 2s polls. After syncing,
`resortModel()` performs a stable partition via `ListModel.move()` so blocked
rows sit at the top while everything else keeps snapshot order; because it
moves delegates instead of rebuilding the model, no delegate state is lost.

Because rows can reorder mid-session, the panel's keyboard cursor tracks the
selected agent by `paneId`, never by row index (`Panel.qml` keeps
`selectedPane`; `hasCursor` compares against each row's `paneId`). The
`Repeater` in `Panel.qml` binds roles (`name`, `status`, `title`, `folder`,
`workspaceLabel`, `focused`) to `required property` delegates.

## Focus mechanics

`Panel.qml` calls `service.focusAgent(paneId)`, which runs
`bin/omarchy-herdr-focus <paneId>` through a guarded Quickshell `Process`
(guarded on `running`, like the poll process, so rapid clicks cannot overlap).
The orchestrator focuses inside Herdr TUI, then delegates to the Hyprland
Window Adapter (`hyprland.py`) for all compositor interaction. Verified on
Hyprland 0.56.2:

1. `herdr agent focus <paneId>` moves Herdr's cursor to the agent's
   workspace/tab/pane. This is a server API call and works regardless of
   where the Herdr window is (or whether it exists at all).
2. The helper scans `hyprctl -j clients`, and for each window walks
   `/proc/<pid>/task/<pid>/children` recursively for a process named `herdr`.
   All matches are scored: a mapped, unhidden window on a normal workspace is
   preferred over one inside a special workspace, then hidden, then unmapped;
   ties keep compositor order.
3. If the chosen window lives in a special workspace (`special:*`) that no
   monitor currently displays (checked via `hyprctl -j monitors`
   `specialWorkspace.name`), the helper dispatches
   `hl.dsp.workspace.toggle_special("<name>")` first — plain focus does not
   open hidden special workspaces, so scratchpad/minimize setups would
   otherwise look like dead clicks. Without monitor data the state is left
   untouched.
4. When no process tree matches but a window class was given
   (`windowClass` setting, passed as the helper's second argument), the
   best-ranked client whose `class`/`initialClass` matches case-insensitively
   is used instead. This covers Herdr running on a remote host inside a local
   terminal (over SSH), where no local `herdr` process exists.
5. The chosen window's `address` is used to dispatch
   `hl.dsp.focus({ window = "address:0x…" })`.
6. Hyprland 0.56 switches the active workspace to the focused window, so the
   Herdr window is raised from any workspace.

The Herdr window must be found by process tree first, not by window title:
herdr's `window_title = "{hostname}: {workspace}"` changes whenever the active
workspace changes; the class fallback only applies when the tree lookup finds
nothing. If Hyprland is unavailable or no local window matches (headless
server, `--remote` attach without a matching class), steps 2–5 are skipped
and the in-TUI focus still applies.

A failed jump must never be silent: `Service.qml` collects the helper's
stderr and, on a non-zero exit, emits a critical "Herdr · could not jump"
toast through the same notification path as the state toasts. Partial
success (window raised despite a herdr-side focus failure) still exits 0 and
only warns on stderr.

When herdr is unreachable, the bar icon dims (`Color.muted` instead of the
state tint) and the panel offers a "Launch Herdr" button that runs
`$OMARCHY_PATH/bin/omarchy-launch-terminal-herdr`.

## Known limitations

- One Herdr window: if several terminal windows each run a `herdr` process,
  the helper raises the best-scoring match (visible normal-workspace window
  first); it cannot tell which terminal hosts the clicked agent.
- `done`/`idle` semantics come from herdr (focusing a tab marks it seen); the
  plugin only observes them.
- The panel shows agent kind as the name; herdr's live agent name (`agent
  rename`) is not yet read from the snapshot.
