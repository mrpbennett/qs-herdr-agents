import QtQuick
import Quickshell
import Quickshell.Io

// Data layer for the Herdr Agents panel. Polls the Herdr session snapshot,
// keeps a live ListModel of the running agents, and emits desktop toasts when
// an agent needs attention or finishes background work.
//
// One `herdr api snapshot` call returns everything the plugin needs: the
// agents array (state, current activity title, cwd, pane/workspace ids) and
// the workspaces array (label per workspace_id).
Item {
  id: root

  property var settings: ({})

  readonly property string omarchyPath: Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy"
  readonly property string focusHelper: Qt.resolvedUrl("bin/omarchy-herdr-focus")
    .toString().replace(/^file:\/\//, "")

  property bool connected: false
  property string error: ""
  property int agentCount: 0
  property int activeCount: 0
  property int workingCount: 0
  property int blockedCount: 0
  property ListModel agents: ListModel {}

  // panelOpen lets the poll cadence tighten while the panel is on screen.
  property bool panelOpen: false

  property var _prevByPane: ({})
  property bool _baseline: false
  property int _consecutiveFailures: 0
  property var _enteredAt: ({})

  // ------------------------------------------------------------ settings
  function intSetting(name, fallback, min, max) {
    var value = settings ? settings[name] : undefined
    if (value === undefined || value === null) value = fallback
    value = Math.floor(Number(value))
    if (!isFinite(value)) value = fallback
    return Math.max(min, Math.min(max, value))
  }

  function boolSetting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : !!value
  }

  function stringSetting(name, fallback) {
    var value = settings ? settings[name] : undefined
    if (value === undefined || value === null) return fallback
    return String(value)
  }

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 2, 1, 60)
  readonly property bool notifyOnBlocked: boolSetting("notifyOnBlocked", true)
  readonly property bool notifyOnFinished: boolSetting("notifyOnFinished", true)
  // Fallback terminal window class for setups where the Herdr process tree
  // cannot be inspected locally (Herdr over SSH in a local terminal).
  readonly property string windowClass: stringSetting("windowClass", "")

  // Validate settings on load and warn about misconfigurations.
  Component.onCompleted: {
    if (settings && settings.refreshIntervalSec !== undefined) {
      var v = Number(settings.refreshIntervalSec)
      if (!isFinite(v) || v < 1 || v > 60)
        console.warn("herdr-agents: refreshIntervalSec must be 1-60, got", settings.refreshIntervalSec)
    }
    if (settings && settings.windowClass !== undefined && settings.windowClass !== "") {
      var wc = String(settings.windowClass).trim()
      if (wc === "") console.warn("herdr-agents: windowClass is set but empty")
    }
  }

  // ------------------------------------------------------------ actions
  function refresh() {
    if (pollProcess.running) return
    pollProcess.command = ["herdr", "api", "snapshot"]
    pollProcess.running = true
  }

  // Focus the agent inside the Herdr TUI and raise the Herdr window so the
  // click lands on the agent's terminal no matter which workspace is active.
  // Runs through an owned Process (not execDetached) so a failed jump can
  // surface as a toast instead of looking like a dead click.
  function focusAgent(paneId) {
    if (!paneId || focusHelper === "") return
    if (focusProcess.running) return
    focusProcess.command = [focusHelper, paneId]
    focusProcess.running = true
    focusWatchdog.restart()
  }

  // ------------------------------------------------------------ parsing
  function basename(path) {
    var text = String(path || "")
    var slash = text.lastIndexOf("/")
    return slash >= 0 ? text.slice(slash + 1) : text
  }

  function isActive(status) {
    return status === "working" || status === "blocked" || status === "done"
  }

  function applySnapshot(text) {
    var parsed
    try {
      parsed = JSON.parse(text)
    } catch (e) {
      root.error = "herdr returned invalid JSON"
      return
    }
    var snapshot = (parsed && typeof parsed === "object" && parsed.result)
      ? parsed.result.snapshot : null
    if (!snapshot) {
      root.error = "herdr snapshot unavailable"
      return
    }

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
      var prevStatus = root._prevByPane[paneId]
        ? root._prevByPane[paneId].status : ""
      if (!root._enteredAt[paneId] || prevStatus !== status)
        root._enteredAt[paneId] = now
      var record = {
        name: String(agent.agent || "agent"),
        status: status,
        title: String(agent.terminal_title_stripped || ""),
        cwd: String(agent.cwd || ""),
        folder: root.basename(agent.cwd),
        paneId: paneId,
        workspaceId: String(agent.workspace_id || ""),
        workspaceLabel: labelById[agent.workspace_id] || String(agent.workspace_id || ""),
        focused: !!agent.focused,
        enteredAt: root._enteredAt[paneId]
      }
      byPane[paneId] = record
      if (root.isActive(status)) totalActive++
      if (status === "working") totalWorking++
      if (status === "blocked") totalBlocked++
    }

    if (root._baseline) {
      var pane
      // Agents that vanished since the last poll: a blocked agent that is
      // gone was either handled or died — worth surfacing either way.
      for (pane in root._prevByPane)
        if (!byPane[pane]) root.detectExit(root._prevByPane[pane])
      for (pane in byPane) {
        var previous = root._prevByPane[pane]
        if (previous) root.detectTransition(previous, byPane[pane])
      }
      root._prevByPane = byPane
    } else {
      // First successful poll is the baseline; it must not announce agents
      // that were already running when the plugin loaded.
      root._baseline = true
      root._prevByPane = byPane
    }

    root.syncModel(byPane)
    root.resortModel()
    root.agentCount = Object.keys(byPane).length
    root.activeCount = totalActive
    root.workingCount = totalWorking
    root.blockedCount = totalBlocked
    root._consecutiveFailures = 0

    // Emit a reconnect toast when herdr comes back online after being down.
    var wasDown = !root.connected
    root.connected = true
    root.error = ""
    if (wasDown && root._baseline)
      root.notify("Herdr reconnected", "", "normal")
  }

  // Keep the ListModel updated in place so the panel's scroll position and
  // keyboard cursor survive every poll.
  function syncModel(byPane) {
    var model = root.agents
    for (var i = model.count - 1; i >= 0; i--) {
      if (!byPane[model.get(i).paneId]) model.remove(i)
    }
    var indexByPane = {}
    for (var j = 0; j < model.count; j++)
      indexByPane[model.get(j).paneId] = j
    for (var pane in byPane) {
      var record = byPane[pane]
      var idx = indexByPane[pane]
      if (idx !== undefined) {
        var item = model.get(idx)
        item.name = record.name
        item.status = record.status
        item.title = record.title
        item.cwd = record.cwd
        item.folder = record.folder
        item.workspaceId = record.workspaceId
        item.workspaceLabel = record.workspaceLabel
        item.focused = record.focused
        item.enteredAt = record.enteredAt
      } else {
        model.append(record)
      }
    }
  }

  // Pin blocked rows to the top: stable partition via move(), so every
  // delegate survives and the rest keeps snapshot order. The panel tracks
  // its keyboard cursor by paneId, so reordering cannot strand it.
  function resortModel() {
    var model = root.agents
    var insertAt = 0
    for (var i = 0; i < model.count; i++) {
      if (model.get(i).status === "blocked") {
        if (i !== insertAt) model.move(i, insertAt, 1)
        insertAt++
      }
    }
  }

  // ------------------------------------------------------------ toasts
  // Shell command run when the toast is clicked: jump to the agent.
  // Single-quote both path and pane id, escaping any embedded single quotes.
  function jumpCommand(paneId) {
    if (focusHelper === "" || !paneId) return ""
    var safeHelper = focusHelper.replace(/'/g, "'\\''")
    var safePane = String(paneId).replace(/'/g, "'\\''")
    return "'" + safeHelper + "' '" + safePane + "'"
  }

  function detectTransition(previous, current) {
    var from = previous.status
    var to = current.status
    if (to === "blocked" && from !== "blocked") {
      if (root.notifyOnBlocked) {
        root.notify("Herdr · needs attention",
          current.name + " is waiting for input in " + current.workspaceLabel,
          "critical", root.jumpCommand(current.paneId))
      }
    } else if (from === "working" && to === "done") {
      if (root.notifyOnFinished) {
        root.notify("Herdr · finished",
          current.name + " finished in " + current.workspaceLabel,
          "normal", root.jumpCommand(current.paneId))
      }
    }
  }

  // The pane disappeared between polls. Only blocked agents announce this:
  // a working agent vanishing usually means its tab was closed on purpose.
  function detectExit(previous) {
    if (previous.status === "blocked" && root.notifyOnBlocked) {
      root.notify("Herdr · agent gone",
        previous.name + " left " + previous.workspaceLabel + " while still blocked",
        "normal")
    }
  }

  function notify(headline, body, urgency, execCommand) {
    if (omarchyPath === "") return
    // The shell's own notification sender keeps the toast in the Omarchy
    // style and routes it through the same notification service. An exec
    // command runs when the toast itself is clicked.
    var cmd = [
      omarchyPath + "/bin/omarchy-notification-send",
      headline, body, "-g", "󰳆", "-u", urgency
    ]
    if (execCommand && execCommand !== "")
      cmd.push("--exec", execCommand)
    Quickshell.execDetached(cmd)
  }

  // ------------------------------------------------------------ polling
  Timer {
    id: pollTimer
    interval: root.panelOpen ? 1000
      : Math.min(root.refreshIntervalSec * Math.pow(2, root._consecutiveFailures), 30) * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Process {
    id: pollProcess
    command: []
    stdout: StdioCollector { id: pollOutput; waitForEnd: true }
    stderr: StdioCollector { id: pollError; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.applySnapshot(pollOutput.text)
      } else {
        root._consecutiveFailures++
        root.connected = false
        root._baseline = false
        root._prevByPane = {}
        root.agentCount = 0
        root.activeCount = 0
        root.workingCount = 0
        root.blockedCount = 0
        root.error = pollError.text.trim() || "herdr is not reachable"
      }
    }
  }

  // Click-to-jump runner. Guarded on `running` like the poll process so two
  // rapid clicks can never overlap; a non-zero exit means the jump failed.
  Process {
    id: focusProcess
    command: []
    stderr: StdioCollector { id: focusError; waitForEnd: true }
    onExited: function(exitCode) {
      focusWatchdog.stop()
      if (exitCode === 0) return
      var detail = focusError.text.trim()
      root.notify("Herdr · could not jump",
        detail !== "" ? detail : "omarchy-herdr-focus failed", "critical")
    }
  }

  // Kill the focus helper if it hangs (e.g. herdr server stall) so the
  // running guard does not lock out all future focus attempts.
  Timer {
    id: focusWatchdog
    interval: 10000
    repeat: false
    onTriggered: {
      if (focusProcess.running) {
        focusProcess.running = false
        root.notify("Herdr · could not jump",
          "focus helper timed out", "critical")
      }
    }
  }
}
