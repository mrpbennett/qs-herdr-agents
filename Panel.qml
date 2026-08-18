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

  readonly property color barColor: service.blockedCount > 0
    ? Color.urgent
    : (service.workingCount > 0 ? Color.accent : root.foreground)

  readonly property bool showStatusLine: !!service
    && service.connected && service.agentCount > 0

  property int selectedIndex: 0
  property bool cursorActive: false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function moveCursor(dy) {
    var count = service.agents.count
    if (count === 0) return
    if (!cursorActive) {
      cursorActive = true
      selectedIndex = 0
    } else {
      selectedIndex = ((selectedIndex + dy) % count + count) % count
    }
    ensureVisible()
  }

  function focusSelected() {
    if (!cursorActive) return
    var item = service.agents.get(selectedIndex)
    if (!item || !item.paneId) return
    service.focusAgent(item.paneId)
    root.close()
  }

  function ensureVisible() {
    if (!agentList || !panelFlick) return
    var item = agentList.itemAt(selectedIndex)
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
    selectedIndex = 0
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
    function focus(): string {
      if (!service.agents.count) return "none"
      root.cursorActive = true
      root.selectedIndex = 0
      root.focusSelected()
      return "ok"
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
      onReturnRequested: root.focusSelected()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r" || t === "R") service.refresh() }

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
              : (service.connected ? "Live session snapshot" : "Waiting for Herdr…")
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
              required property string workspaceLabel
              required property bool focused

              width: parent.width
              agentName: name
              agentStatus: status
              agentTitle: title
              agentCwd: cwd
              agentFolder: folder
              agentWorkspace: workspaceLabel
              isFocused: focused
              hasCursor: root.cursorActive && root.selectedIndex === index
              current: focused

              onHovered: {
                root.cursorActive = true
                root.selectedIndex = index
              }
              onClicked: {
                root.cursorActive = true
                root.selectedIndex = index
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
            text: "Herdr is not running.\nLaunch it or check its server status, then open this panel again."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          Text {
            visible: service.connected && service.agentCount > 0
            width: parent.width
            topPadding: Style.space(2)
            text: "Click an agent to jump to it · r refreshes"
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
    signal hovered()
    signal clicked()

    foreground: root.foreground
    implicitHeight: rowLayout.implicitHeight + Style.spacing.controlPaddingY * 2

    readonly property color statusColor: root.statusColorFor(agentStatus)
    readonly property string statusLabel: root.statusLabelFor(agentStatus)

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
      visible: row.mouseHover
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
}