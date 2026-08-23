# Next-Level Improvements

Ideas organized by impact area. Each item includes what, why, and the files
affected.

---

## A. User Experience

### A1. Search / filter in panel
**What:** Typing while the panel is open filters the agent list by name,
workspace, or folder. Escape clears the filter.
**Why:** With many agents (5+), scanning the list is slow. Keyboard-first
filtering is the Omarchy way.
**Files:** `Panel.qml` (add a filter `property string` and guard the
`Repeater` model with a `DelegateModel` / proxy `ListModel`, or filter via
`visible` on each `AgentRow`).
**Effort:** Medium. The `PanelKeyCatcher` already captures text keys; adding
a filter string and matching against `agentName`/`agentFolder`/`agentWorkspace`
is straightforward. The main work is the filtered-model layer.

### A2. Elapsed time since status change
**What:** Show a live "3m 12s" or "working for 5m" counter on each agent
row, ticking every 10s or so.
**Why:** Users want to know *how long* an agent has been blocked or working,
not just that it is. A blocked agent for 30s is different from one blocked
for 20 minutes.
**Files:** `Service.qml` (store `_enteredAt` timestamp per pane on status
change), `Panel.qml` (display a formatted duration; use a `Timer` or
`Qt.callLater` to update labels periodically).
**Effort:** Medium. The timestamp is trivial to add in `detectTransition`.
The display needs a periodic update timer in the panel.

### A3. Bar icon tooltip
**What:** Hovering the bar sheep icon shows a one-line summary: "3 agents ·
1 working · 1 blocked" without opening the panel.
**Why:** Quick status check without the click-to-open overhead.
**Files:** `Panel.qml` (add a `PanelToolTip` on the `BarIconButton`).
**Effort:** Trivial.

### A4. Agent kind badge
**What:** Show the agent kind (e.g. "opencode") as a small muted label
next to the agent name in each row.
**Why:** When running multiple agent types, distinguishing "opencode" from
"claude" at a glance is valuable. Currently only the name (which *is*
the kind) is shown, but it blends with the status label.
**Files:** `Panel.qml` (add a small `Text` element in `AgentRow`).
**Effort:** Trivial. The `name` role already carries the kind.

### A5. Reconnect toast
**What:** When `connected` flips from `false` back to `true`, emit a
normal-priority "Herdr reconnected" toast.
**Why:** Users see the "not running" error but never get closure when
herdr comes back. A reconnect signal closes the loop.
**Files:** `Service.qml` (detect `connected` false→true transition in
`applySnapshot` after the baseline is re-established).
**Effort:** Low. One property change callback or a flag.

---

## B. Codebase Quality

### B1. Extract `AgentRow` to its own file
**What:** Move the 128-line `AgentRow` inline component from `Panel.qml`
to `AgentRow.qml`.
**Why:** `Panel.qml` is 576 lines. Extracting the row component improves
readability and makes the row independently testable if QML unit tests
are added later. Matches Omarchy's pattern of separate component files.
**Files:** `Panel.qml` (remove inline component, import `AgentRow.qml`),
new `AgentRow.qml`.
**Effort:** Low-Medium. Straightforward extraction; need to pass
`root.foreground`, `root.dim`, `root.fontFamily`, `root.statusColorFor`,
`root.statusLabelFor` as properties or use the existing `root` closure.

### B2. Type hints for the focus helper
**What:** Add `-> bool`, `-> str | None`, `-> dict | None` return type
annotations and parameter types to all functions in `bin/omarchy-herdr-focus`.
**Why:** Improves readability and catches type bugs early. Python stdlib
supports this natively.
**Files:** `bin/omarchy-herdr-focus`.
**Effort:** Low.

### B3. Shell-safe quoting in `jumpCommand`
**What:** The `jumpCommand` function in `Service.qml` builds a shell
string with single quotes. If a `paneId` ever contained a `'`, it would
break.
**Why:** Defensive correctness. Pane IDs are structured today, but this
is a latent bug.
**Files:** `Service.qml` (escape single quotes in the pane ID by
replacing `'` with `'\''`).
**Effort:** Trivial.

### B4. Expand test coverage
**What:** Add tests for:
- `ensure_special_visible` with empty monitor list (no monitors)
- `main()` with >2 arguments (usage error path)
- `find_herdr_client` when both proc-tree and class would match (verify
  proc-tree wins)
- `client_rank` with a workspace whose name starts with "special:" but
  has id >= 0 (regression guard for the recent fix)
**Files:** `tests/test_herdr_focus.py`.
**Effort:** Low.

### B5. CHANGELOG.md
**What:** Add a changelog documenting v0.1.0 → v0.2.0 changes ( Round 2
focus reliability, Round 3 IPC/clickable toasts/resort/launch button,
code review fixes).
**Why:** Users updating via `omarchy plugin update` see what changed.
Standard open-source practice.
**Files:** New `CHANGELOG.md`.
**Effort:** Low.

---

## C. Robustness

### C1. Exponential backoff on poll failure
**What:** When `herdr api snapshot` fails, double the poll interval
(up to a cap, e.g. 30s) on each consecutive failure. Reset to the
configured interval on success.
**Why:** If herdr is down, polling every 2s is wasteful. Backoff reduces
noise and resource use while still auto-recovering.
**Files:** `Service.qml` (track `_consecutiveFailures`, compute
`Math.min(baseInterval * 2^failures, 30) * 1000` for the timer interval).
**Effort:** Low-Medium.

### C2. Subprocess timeout in the focus helper
**What:** Add a `timeout` parameter to the `run()` helper so individual
`subprocess.run` calls cannot hang forever. Default 5s for herdr, 3s for
hyprctl.
**Why:** The QML watchdog kills the *process*, but if the subprocess hangs
on I/O, the script itself is stuck. A per-call timeout is more precise.
**Files:** `bin/omarchy-herdr-focus` (add `timeout=` to `subprocess.run`
calls).
**Effort:** Low. Python 3.3+ `subprocess.run` supports `timeout`.

### C3. Config validation on startup
**What:** Log a warning (to stderr) if `refreshIntervalSec` is outside
1–60 or `windowClass` is set but empty. Validate the manifest schema
on load.
**Why:** Misconfigurations silently produce wrong behavior. Early warnings
save debugging time.
**Files:** `Service.qml` (validate in the settings functions or on
`Component.onCompleted`).
**Effort:** Low.

---

## Prioritized Recommendation

| Priority | Item | Impact | Effort |
|----------|------|--------|--------|
| **P0** | A3 Bar icon tooltip | High (daily use) | Trivial |
| **P0** | B3 Shell-safe quoting | High (correctness) | Trivial |
| **P0** | B4 Expand test coverage | High (confidence) | Low |
| **P1** | A5 Reconnect toast | Medium (QoL) | Low |
| **P1** | A2 Elapsed time | Medium (insight) | Medium |
| **P1** | C1 Poll backoff | Medium (resource) | Low-Med |
| **P1** | B5 CHANGELOG | Medium (users) | Low |
| **P2** | A1 Search/filter | Medium (power users) | Medium |
| **P2** | B1 Extract AgentRow | Low (readability) | Low-Med |
| **P2** | B2 Type hints | Low (maintainability) | Low |
| **P2** | C2 Subprocess timeout | Low (defense) | Low |
| **P3** | A4 Agent kind badge | Low (cosmetic) | Trivial |
| **P3** | C3 Config validation | Low (DX) | Low |
