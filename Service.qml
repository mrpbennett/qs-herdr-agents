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

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 2, 1, 60)
  readonly property bool notifyOnBlocked: boolSetting("notifyOnBlocked", true)
  readonly property bool notifyOnFinished: boolSetting("notifyOnFinished", true)

  // ------------------------------------------------------------ actions
  function refresh() {
    if (pollProcess.running) return
    pollProcess.command = ["herdr", "api", "snapshot"]
    pollProcess.running = true
  }

  // Focus the agent inside the Herdr TUI and raise the Herdr window so the
  // click lands on the agent's terminal no matter which workspace is active.
  function focusAgent(paneId) {
    if (!paneId || focusHelper === "") return
    Quickshell.execDetached([focusHelper, paneId])
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
    var snapshot = parsed && parsed.result ? parsed.result.snapshot : null
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
    for (var a = 0; a < agentsIn.length; a++) {
      var agent = agentsIn[a]
      var status = String(agent.agent_status || "unknown")
      var record = {
        name: String(agent.agent || "agent"),
        status: status,
        title: String(agent.terminal_title_stripped || ""),
        cwd: String(agent.cwd || ""),
        folder: root.basename(agent.cwd),
        paneId: String(agent.pane_id || ""),
        workspaceId: String(agent.workspace_id || ""),
        workspaceLabel: labelById[agent.workspace_id] || String(agent.workspace_id || ""),
        focused: !!agent.focused
      }
      byPane[record.paneId] = record
      if (root.isActive(status)) totalActive++
      if (status === "working") totalWorking++
      if (status === "blocked") totalBlocked++
    }

    if (root._baseline) {
      for (var pane in byPane) {
        var current = byPane[pane]
        var previous = root._prevByPane[pane]
        if (previous) root.detectTransition(previous, current)
      }
      root._prevByPane = byPane
    } else {
      // First successful poll is the baseline; it must not announce agents
      // that were already running when the plugin loaded.
      root._baseline = true
      root._prevByPane = byPane
    }

    root.syncModel(byPane)
    root.agentCount = byPaneCount(byPane)
    root.activeCount = totalActive
    root.workingCount = totalWorking
    root.blockedCount = totalBlocked
    root.connected = true
    root.error = ""
  }

  function byPaneCount(byPane) {
    var count = 0
    for (var pane in byPane) count++
    return count
  }

  // Keep the ListModel updated in place so the panel's scroll position and
  // keyboard cursor survive every poll.
  function syncModel(byPane) {
    var model = root.agents
    for (var i = model.count - 1; i >= 0; i--) {
      if (!byPane[model.get(i).paneId]) model.remove(i)
    }
    for (var pane in byPane) {
      var record = byPane[pane]
      var index = -1
      for (var j = 0; j < model.count; j++) {
        if (model.get(j).paneId === pane) {
          index = j
          break
        }
      }
      if (index >= 0) {
        var item = model.get(index)
        item.name = record.name
        item.status = record.status
        item.title = record.title
        item.cwd = record.cwd
        item.folder = record.folder
        item.workspaceId = record.workspaceId
        item.workspaceLabel = record.workspaceLabel
        item.focused = record.focused
      } else {
        model.append(record)
      }
    }
  }

  // ------------------------------------------------------------ toasts
  function detectTransition(previous, current) {
    var from = previous.status
    var to = current.status
    if (to === "blocked" && from !== "blocked") {
      if (root.notifyOnBlocked) {
        root.notify("Herdr · needs attention",
          current.name + " is waiting for input in " + current.workspaceLabel,
          "critical")
      }
    } else if (from === "working" && to === "done") {
      if (root.notifyOnFinished) {
        root.notify("Herdr · finished",
          current.name + " finished in " + current.workspaceLabel,
          "normal")
      }
    }
  }

  function notify(headline, body, urgency) {
    if (omarchyPath === "") return
    // The shell's own notification sender keeps the toast in the Omarchy
    // style and routes it through the same notification service.
    Quickshell.execDetached([
      omarchyPath + "/bin/omarchy-notification-send",
      headline, body, "-g", "󰳆", "-u", urgency
    ])
  }

  // ------------------------------------------------------------ polling
  Timer {
    interval: root.panelOpen ? 1000 : root.refreshIntervalSec * 1000
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
        root.connected = false
        root._baseline = false
        root._prevByPane = {}
        root.error = pollError.text.trim() || "herdr is not reachable"
      }
    }
  }
}
