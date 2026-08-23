// Snapshot Adapter — stateless pure functions for Herdr snapshot data.
// Owned by Service.qml; tests live in tests/test_snapshot.js.

/**
 * Parse raw JSON from `herdr api snapshot` into a structured snapshot.
 * Returns { snapshot, error } where error is a string on failure.
 */
function parse(raw) {
  var parsed
  try {
    parsed = JSON.parse(raw)
  } catch (e) {
    return { snapshot: null, error: "herdr returned invalid JSON" }
  }
  var snapshot = (parsed && typeof parsed === "object" && parsed.result)
    ? parsed.result.snapshot : null
  if (!snapshot) {
    return { snapshot: null, error: "herdr snapshot unavailable" }
  }
  return { snapshot: snapshot, error: "" }
}

/**
 * Derive a human-readable basename from a path.
 */
function basename(path) {
  var text = String(path || "")
  var slash = text.lastIndexOf("/")
  return slash >= 0 ? text.slice(slash + 1) : text
}

/**
 * True when the agent status represents an active (non-idle) agent.
 */
function isActive(status) {
  return status === "working" || status === "blocked" || status === "done"
}

/**
 * Build per-pane agent records from a parsed snapshot.
 *
 * @param {Object} snapshot  - the parsed snapshot object
 * @param {Object} stateByPane - mutable map of paneId → { status, enteredAt }
 * @returns {{ byPane: Object, counts: { active, working, blocked } }}
 */
function buildRecords(snapshot, stateByPane) {
  var labelById = {}
  var workspaces = snapshot.workspaces || []
  for (var i = 0; i < workspaces.length; i++)
    labelById[workspaces[i].workspace_id] = String(workspaces[i].label || "")

  var byPane = {}
  var agentsIn = snapshot.agents || []
  var totalActive = 0
  var totalWorking = 0
  var totalBlocked = 0
  var now = Date.now()

  for (var a = 0; a < agentsIn.length; a++) {
    var agent = agentsIn[a]
    var status = String(agent.agent_status || "unknown")
    var paneId = String(agent.pane_id || "")

    // Preserve the original entered-at timestamp when the status has not
    // changed; start a new one when it has.
    var prevStatus = stateByPane[paneId] ? stateByPane[paneId].status : ""
    if (!stateByPane[paneId] || prevStatus !== status)
      stateByPane[paneId] = { status: status, enteredAt: now }

    var record = {
      name: String(agent.agent || "agent"),
      status: status,
      title: String(agent.terminal_title_stripped || ""),
      cwd: String(agent.cwd || ""),
      folder: basename(agent.cwd),
      paneId: paneId,
      workspaceId: String(agent.workspace_id || ""),
      workspaceLabel: labelById[agent.workspace_id] || String(agent.workspace_id || ""),
      focused: !!agent.focused,
      enteredAt: stateByPane[paneId].enteredAt
    }
    byPane[paneId] = record
    if (isActive(status)) totalActive++
    if (status === "working") totalWorking++
    if (status === "blocked") totalBlocked++
  }

  return {
    byPane: byPane,
    counts: { active: totalActive, working: totalWorking, blocked: totalBlocked }
  }
}

/**
 * Diff two per-pane maps. Returns added, removed, and transitioned panes.
 *
 * @param {Object} prevByPane - previous paneId → record map
 * @param {Object} currByPane - current paneId → record map
 * @returns {{ added: string[], removed: string[], transitions: Object[] }}
 */
function diffRecords(prevByPane, currByPane) {
  var added = []
  var removed = []
  var transitions = []

  // Panes in prev but not curr = removed.
  for (var pane in prevByPane)
    if (!currByPane[pane]) removed.push(pane)

  // Panes in curr: added or transitioned.
  for (var pane in currByPane) {
    var prev = prevByPane[pane]
    if (!prev) {
      added.push(pane)
    } else {
      var curr = currByPane[pane]
      if (prev.status !== curr.status)
        transitions.push({ paneId: pane, from: prev.status, to: curr.status, record: curr })
    }
  }

  return { added: added, removed: removed, transitions: transitions }
}

// Node.js export for testing; no-op in QML (functions are imported by name).
if (typeof module !== "undefined" && module.exports)
  module.exports = { parse, basename, isActive, buildRecords, diffRecords }
