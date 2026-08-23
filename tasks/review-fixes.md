# Code Review Fixes

## Bugs to fix

### 1. `applySnapshot` crash on malformed snapshot shape
**File:** `Service.qml:82-94`
**Problem:** `JSON.parse` success doesn't guarantee `parsed` is an object. If `parsed` is `null` or a primitive, `parsed.result` throws uncaught.
**Fix:** Guard `parsed` with a type check before accessing `.result`.

### 2. `client_rank` uses fragile ID sign check
**File:** `bin/omarchy-herdr-focus:89-91`
**Problem:** `workspace["id"] >= 0` assumes special workspaces always have negative IDs — undocumented Hyprland convention. `ensure_special_visible` already uses the more reliable `name.startsWith("special:")` pattern.
**Fix:** Use `workspace.get("name", "").startswith("special:")` to detect special workspaces, consistent with the rest of the file.

### 3. `process_has_herdr` only reads main-thread children
**File:** `bin/omarchy-herdr-focus:68`
**Problem:** `/proc/<pid>/task/<pid>/children` only shows children of the main thread. Some programs attach child processes to other threads.
**Fix:** Iterate all `/proc/<pid>/task/*/children` files, deduplicating with the existing `seen` set.

## Quality of life improvements

### 4. `syncModel` does O(n²) lookups
**File:** `Service.qml:162-184`
**Problem:** For each pane in `byPane`, the code linear-scans the model to find the matching index.
**Fix:** Build a `paneId → index` map once before the update loop, then use O(1) lookups.

### 5. Help text missing keyboard shortcuts
**File:** `Panel.qml:305`
**Problem:** Hint says "Click an agent to leap to it · r refreshes" but omits arrow-key navigation and Enter.
**Fix:** Update to "↑↓ navigate · Enter to jump · r refreshes".

### 6. `byPaneCount` reinvents `Object.keys`
**File:** `Service.qml:149-153`
**Fix:** Replace with `Object.keys(byPane).length`.

### 7. `focusProcess` can lock out permanently
**File:** `Service.qml:244-254`
**Problem:** If `herdr agent focus` hangs, the process never exits, the `running` guard blocks all future focus attempts.
**Fix:** Add a `Timer` that fires after ~10s and force-kills the focus process via `focusProcess.running = false` (SIGTERM). Emit a toast on timeout.

### 8. Tooltip shows empty text
**File:** `Panel.qml:437-446`
**Problem:** When both `agentTitle` and `agentCwd` are empty, the tooltip appears with blank content.
**Fix:** Add `visible: row.mouseHover && text !== ""` to `PanelToolTip`.

### 9. `tasks/todo.md` incorrect notification plan
**File:** `tasks/todo.md:59`
**Problem:** Says `working→idle` notifies, but implementation intentionally skips this (per `docs/design.md`).
**Fix:** Update the plan to match reality.

## Out of scope (not fixing)
- Badge "9+" threshold — works fine for realistic agent counts.
- `statusColorFor`/`statusLabelFor` location — minor style, not worth churning.
- Error recovery toast — nice-to-have but adds user-facing behavior change without explicit request.

## Verification
```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
bash -n install.sh uninstall.sh
```
