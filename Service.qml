import QtQuick
import Quickshell
import Quickshell.Io
import "snapshot.js" as Snap

// Data layer for the Herdr Agents panel. Polls the Herdr session snapshot,
// keeps a live ListModel of the running agents, and renders desktop toasts from
// Notification Intents produced by the Snapshot Adapter.
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

  property var _timeline: Snap.initialTimeline()
  property int _consecutiveFailures: 0

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
  function applySnapshot(text) {
    var result = Snap.parse(text)
    if (result.error) {
      root.handlePollFailure(result.error)
      return
    }

    var evolved = Snap.evolveTimeline(root._timeline, result.snapshot, Date.now())
    root._timeline = evolved.timeline

    root.syncModel(evolved.byPane)
    root.resortModel()
    root.agentCount = Object.keys(evolved.byPane).length
    root.activeCount = evolved.counts.active
    root.workingCount = evolved.counts.working
    root.blockedCount = evolved.counts.blocked
    root._consecutiveFailures = 0

    root.connected = true
    root.error = ""
    for (var i = 0; i < evolved.intents.length; i++)
      root.notifyIntent(evolved.intents[i])
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
        item.tabLabel = record.tabLabel
        item.focused = record.focused
        item.enteredAt = record.enteredAt
      } else {
        model.append(record)
      }
    }
  }

  // Group rows by urgency (blocked, working, done, then the rest) with stable
  // partitions via move(), so delegates survive and each group keeps snapshot
  // order. The panel tracks its keyboard cursor by paneId, so reordering
  // cannot strand it.
  function resortModel() {
    var model = root.agents
    var order = ["blocked", "working", "done"]
    var insertAt = 0
    for (var o = 0; o < order.length; o++) {
      for (var i = insertAt; i < model.count; i++) {
        if (model.get(i).status === order[o]) {
          if (i !== insertAt) model.move(i, insertAt, 1)
          insertAt++
        }
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

  function notifyIntent(intent) {
    if (intent.type === "blocked" && root.notifyOnBlocked) {
      root.notify("Herdr · needs attention",
        intent.name + " is waiting for input in " + intent.workspaceLabel,
        intent.urgency, root.jumpCommand(intent.paneId))
    } else if (intent.type === "finished" && root.notifyOnFinished) {
      root.notify("Herdr · finished",
        intent.name + " finished in " + intent.workspaceLabel,
        intent.urgency, root.jumpCommand(intent.paneId))
    } else if (intent.type === "agentGone" && root.notifyOnBlocked) {
      root.notify("Herdr · agent gone",
        intent.name + " left " + intent.workspaceLabel + " while still blocked",
        intent.urgency)
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

  function handlePollFailure(detail) {
    root._consecutiveFailures++
    root.connected = false
    root._timeline = Snap.initialTimeline()
    root.agentCount = 0
    root.activeCount = 0
    root.workingCount = 0
    root.blockedCount = 0
    root.error = detail || "herdr is not reachable"
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
        root.handlePollFailure(pollError.text.trim())
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
