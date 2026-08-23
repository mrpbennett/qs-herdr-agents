import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Herdr Agents — one bar icon and one panel.
//
// Bar: a static agent glyph tinted by the fleet state (accent = someone
// working, urgent = someone blocked) with a badge counting busy agents.
//
// Panel: a live list of every running Herdr agent with its state, current
// activity (the agent's terminal title), and the Herdr workspace it lives in.
// Clicking or Entering a row jumps straight to that agent inside Herdr and
// raises the Herdr window, from any workspace.
Panel {
  id: root
  moduleName: "mrpbennett.herdr-agents"
  ipcTarget: "mrpbennett.herdr-agents"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property color barColor: !service.connected
    ? Color.muted
    : (service.blockedCount > 0
      ? Color.urgent
      : (service.workingCount > 0 ? Color.accent : root.foreground))

  readonly property bool showStatusLine: !!service
    && service.connected && service.agentCount > 0

  // Keyboard cursor tracks the agent (paneId), not the row index: the list
  // re-sorts as agents enter/leave blocked, so an index would drift.
  property string selectedPane: ""
  property bool cursorActive: false

  property bool filterActive: false
  property string filterText: ""
  property int _tick: 0

  // Periodic tick to update elapsed-time labels in agent rows.
  Timer {
    interval: 10000
    repeat: true
    running: root.opened
    onTriggered: root._tick++
  }

  function barSummary() {
    if (!service.connected) return "Herdr not running"
    if (service.agentCount === 0) return "No agents"
    var parts = [service.agentCount + " agent" + (service.agentCount === 1 ? "" : "s")]
    if (service.workingCount > 0) parts.push(service.workingCount + " working")
    if (service.blockedCount > 0) parts.push(service.blockedCount + " blocked")
    return parts.join(" · ")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function indexOfPane(paneId) {
    for (var i = 0; i < service.agents.count; i++)
      if (service.agents.get(i).paneId === paneId) return i
    return -1
  }

  function moveCursor(dy) {
    var count = service.agents.count
    if (count === 0) return
    var index = root.indexOfPane(root.selectedPane)
    if (!cursorActive || index < 0) {
      cursorActive = true
      selectedPane = service.agents.get(0).paneId
    } else {
      index = ((index + dy) % count + count) % count
      selectedPane = service.agents.get(index).paneId
    }
    ensureVisible()
  }

  function selectPane(paneId) {
    cursorActive = true
    selectedPane = paneId
  }

  function jumpToIndex(index) {
    var item = service.agents.get(index)
    if (!item || !item.paneId) return false
    selectPane(item.paneId)
    service.focusAgent(item.paneId)
    root.close()
    return true
  }

  function firstBlockedIndex() {
    for (var i = 0; i < service.agents.count; i++)
      if (service.agents.get(i).status === "blocked") return i
    return -1
  }

  // Jump to the first blocked agent, else the first row. The natural target
  // for a global keybind: leap straight to whatever needs attention.
  function jumpToBlocked() {
    if (service.agents.count === 0) return false
    var index = root.firstBlockedIndex()
    return jumpToIndex(index >= 0 ? index : 0)
  }

  function jumpToAgent(name) {
    var wanted = String(name || "").trim().toLowerCase()
    if (wanted === "") return false
    for (var i = 0; i < service.agents.count; i++)
      if (service.agents.get(i).name.toLowerCase() === wanted)
        return jumpToIndex(i)
    return false
  }

  function focusSelected() {
    if (!cursorActive || selectedPane === "") return
    service.focusAgent(selectedPane)
    root.close()
  }

  function ensureVisible() {
    if (!agentList || !panelFlick) return
    var item = agentList.itemAt(root.indexOfPane(root.selectedPane))
    if (!item) return
    if (item.y < panelFlick.contentY) panelFlick.contentY = item.y
    else if (item.y + item.height > panelFlick.contentY + panelFlick.height)
      panelFlick.contentY = item.y + item.height - panelFlick.height
  }

  function statusText() {
    if (!service.connected) return "Herdr is not running."
    if (service.agentCount === 0) return "No agents running."
    return service.activeCount > 0
      ? service.agentCount + " agent" + (service.agentCount === 1 ? "" : "s")
        + " · " + service.activeCount + " active"
      : service.agentCount + " agent" + (service.agentCount === 1 ? "" : "s") + " idle"
  }

  onOpenedChanged: if (opened) {
    cursorActive = false
    selectedPane = ""
    filterActive = false
    filterText = ""
    service.panelOpen = true
    if (panelFlick) panelFlick.contentY = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  } else {
    service.panelOpen = false
  }

  Component.onCompleted: {
    service.panelOpen = root.opened
    service.refresh()
  }

  Service { id: service }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { service.refresh(); return "ok" }
    function next(): string { root.moveCursor(1); return "ok" }
    // Jump to the first blocked agent (else the first row) and raise Herdr.
    function focus(): string { return root.jumpToBlocked() ? "ok" : "none" }
    // Jump to a running agent by name, e.g. focusAgent("opencode").
    function focusAgent(name: string): string {
      return root.jumpToAgent(name) ? "ok" : "none"
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        id: barIcon
        readonly property real glyphSize: Style.space(16)

        Text {
          id: barGlyph
          anchors.centerIn: parent
          text: "󰳆"
          color: root.barColor
          font.family: root.fontFamily
          font.pixelSize: barIcon.glyphSize
        }

        Rectangle {
          id: badge
          visible: service.activeCount > 0
          anchors.top: parent.top
          anchors.right: parent.right
          width: Math.max(badgeText.implicitWidth + Style.space(6), Style.space(13))
          height: Style.space(13)
          radius: height / 2
          color: root.barColor

          Text {
            id: badgeText
            anchors.centerIn: parent
            text: service.activeCount > 9 ? "9+" : String(service.activeCount)
            color: Color.background
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) service.refresh()
      else root.toggle()
    }

    PanelToolTip {
      visible: !root.opened && button.containsMouse
      text: root.barSummary()
      fontFamily: root.fontFamily
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(440))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: root.focusSelected()
      onReturnRequested: {
        if (root.filterActive) {
          root.filterActive = false
          root.filterText = ""
          filterField.visible = false
        } else {
          root.focusSelected()
        }
      }
      onCloseRequested: {
        if (root.filterActive) {
          root.filterActive = false
          root.filterText = ""
          filterField.visible = false
        } else {
          root.close()
        }
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (root.filterActive) return
        if (t === "/" || t === "f") {
          root.filterActive = true
          filterField.visible = true
        } else if (t === "r" || t === "R") {
          service.refresh()
        }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(10)

          PanelHero {
            width: parent.width
            title: "Herdr Agents"
            meta: root.statusText()
            detail: service.error !== "" && !service.connected
              ? service.error
              : (service.connected ? "Active" : "Waiting for Herdr…")
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: "󰳆"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Text {
            visible: root.showStatusLine && text !== ""
            width: parent.width
            text: {
              if (service.error !== "") return service.error
              var working = service.workingCount
              var blocked = service.blockedCount
              var parts = []
              if (working > 0) parts.push(working + " working")
              if (blocked > 0) parts.push(blocked + " blocked")
              return parts.length ? parts.join(" · ") : ""
            }
            color: service.blockedCount > 0 ? Color.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          PanelSeparator {
            width: parent.width
            foreground: root.foreground
          }

          TextField {
            id: filterField
            visible: root.filterActive
            width: parent.width
            placeholderText: "Type to filter…"
            color: root.foreground
            placeholderTextColor: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            background: Rectangle {
              radius: height / 2
              color: "transparent"
              border.color: root.dim
              border.width: 1
            }
            leftPadding: Style.space(10)
            rightPadding: Style.space(10)
            topPadding: Style.space(4)
            bottomPadding: Style.space(4)
            onTextChanged: root.filterText = text
            onVisibleChanged: if (visible) {
              forceActiveFocus()
              text = root.filterText
            }
          }

          Repeater {
            id: agentList
            model: service.agents

            delegate: AgentRow {
              required property int index
              required property string name
              required property string status
              required property string title
              required property string cwd
              required property string folder
              required property string paneId
              required property string workspaceLabel
              required property bool focused
              required property double enteredAt

              visible: root.filterText === ""
                || name.toLowerCase().indexOf(root.filterText.toLowerCase()) >= 0
                || folder.toLowerCase().indexOf(root.filterText.toLowerCase()) >= 0
                || workspaceLabel.toLowerCase().indexOf(root.filterText.toLowerCase()) >= 0
              width: parent.width
              agentName: name
              agentStatus: status
              agentTitle: title
              agentCwd: cwd
              agentFolder: folder
              agentWorkspace: workspaceLabel
              isFocused: focused
              agentEnteredAt: enteredAt
              hasCursor: root.cursorActive && root.selectedPane === paneId
              current: focused

              onHovered: root.selectPane(paneId)
              onClicked: {
                root.selectPane(paneId)
                root.focusSelected()
              }
            }
          }

          Text {
            visible: service.connected && service.agentCount === 0
            width: parent.width
            topPadding: Style.space(18)
            text: "No agents running.\nStart one in Herdr and it shows up here live."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          Text {
            visible: !service.connected
            width: parent.width
            topPadding: Style.space(18)
            text: "Herdr is not running.\nLaunch it or check its server status."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          Rectangle {
            id: launchButton
            visible: !service.connected
            anchors.horizontalCenter: parent.horizontalCenter
            readonly property bool hovered: launchArea.containsMouse
            width: launchRow.implicitWidth + Style.space(24)
            height: Style.space(30)
            radius: height / 2
            color: hovered ? Color.accent : "transparent"
            border.color: Color.accent
            border.width: 1

            Row {
              id: launchRow
              anchors.centerIn: parent
              spacing: Style.space(6)

              Text {
                text: ""
                color: launchButton.hovered ? Color.background : Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                text: "Launch Herdr"
                color: launchButton.hovered ? Color.background : Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }
            }

            MouseArea {
              id: launchArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                Quickshell.execDetached([
                  service.omarchyPath + "/bin/omarchy-launch-terminal-herdr"
                ])
                root.close()
              }
            }
          }

          Text {
            visible: service.connected && service.agentCount > 0
            width: parent.width
            topPadding: Style.space(2)
            text: "/ filter · ↑↓ navigate · Enter to jump · r refreshes"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // One agent row: status dot + name, the agent's current activity title,
  // and the Herdr workspace it is running in.
  component AgentRow: CursorSurface {
    id: row
    property string agentName: ""
    property string agentStatus: "unknown"
    property string agentTitle: ""
    property string agentCwd: ""
    property string agentFolder: ""
    property string agentWorkspace: ""
    property bool isFocused: false
    property bool mouseHover: false
    property double agentEnteredAt: 0
    signal hovered()
    signal clicked()

    foreground: root.foreground
    implicitHeight: rowLayout.implicitHeight + Style.spacing.controlPaddingY * 2

    readonly property color statusColor: root.statusColorFor(agentStatus)
    readonly property string statusLabel: root.statusLabelFor(agentStatus)
    readonly property string elapsedText: root._tick >= 0
      ? root.formatElapsed(agentEnteredAt) : ""

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: {
        row.mouseHover = true
        row.hovered()
      }
      onExited: row.mouseHover = false
      onClicked: row.clicked()
    }

    RowLayout {
      id: rowLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(10)

      StatusDot {
        Layout.alignment: Qt.AlignTop
        Layout.topMargin: Style.space(4)
        color: row.statusColor
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Text {
            id: nameText
            text: row.agentName
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
            Layout.fillWidth: true
          }

          Text {
            text: row.agentWorkspace
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            Layout.maximumWidth: Style.space(150)
          }

          Text {
            text: row.statusLabel
            color: row.statusColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Text {
            visible: row.elapsedText !== ""
            text: row.elapsedText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          visible: row.agentTitle !== ""
          Layout.fillWidth: true
          text: row.agentTitle
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Text {
            text: row.agentFolder
            color: Qt.darker(root.foreground, 1.75)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            Layout.fillWidth: true
          }

          Text {
            visible: row.isFocused
            text: "FOCUSED"
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }
      }
    }

    PanelToolTip {
      visible: row.mouseHover && text !== ""
      text: {
        var parts = []
        if (row.agentTitle !== "") parts.push(row.agentTitle)
        if (row.agentCwd !== "") parts.push(row.agentCwd)
        return parts.join("\n")
      }
      fontFamily: root.fontFamily
    }
  }

  // Small colored dot for the agent's current status.
  component StatusDot: Item {
    id: dot
    property color color: Color.muted

    implicitWidth: Style.space(8)
    implicitHeight: Style.space(8)
    width: Style.space(8)
    height: Style.space(8)

    Rectangle {
      id: dotFill
      anchors.fill: parent
      radius: width / 2
      color: dot.color
    }
  }

  function statusColorFor(status) {
    switch (status) {
      case "working": return Color.accent
      case "blocked": return Color.urgent
      case "done": return root.foreground
      case "idle": return Qt.darker(root.foreground, 1.35)
      default: return Color.muted
    }
  }

  function statusLabelFor(status) {
    switch (status) {
      case "working": return "WORKING"
      case "blocked": return "BLOCKED"
      case "done": return "DONE"
      case "idle": return "IDLE"
      default: return "UNKNOWN"
    }
  }

  function formatElapsed(enteredAt) {
    if (!enteredAt || enteredAt <= 0) return ""
    var sec = Math.floor((Date.now() - enteredAt) / 1000)
    if (sec < 5) return ""
    if (sec < 60) return sec + "s"
    var min = Math.floor(sec / 60)
    if (min < 60) return min + "m " + (sec % 60) + "s"
    var hr = Math.floor(min / 60)
    return hr + "h " + (min % 60) + "m"
  }
}
