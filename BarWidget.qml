import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The bar chip: a cocktail glass, plus how many tasks need you (urgent) and
// how many are working. Click to open the task list.
BarWidget {
  id: root
  moduleName: "ninepointlabs.speakeasy"

  readonly property var panel: panelLoader.item
  readonly property int needsCount: panel ? panel.needsCount : 0
  readonly property int doneCount: panel ? panel.doneCount : 0
  readonly property int workingCount: panel ? panel.workingCount : 0
  readonly property bool showCounts: setting("showCounts", true) === true

  readonly property color chipColor: {
    if (!bar) return Color.foreground
    if (needsCount > 0) return bar.urgent
    if (workingCount > 0 || doneCount > 0) return bar.barForeground
    return Qt.darker(bar.barForeground, 1.5)
  }

  readonly property string labelText: {
    var parts = []
    if (needsCount > 0) parts.push("!" + needsCount)
    if (doneCount > 0) parts.push("✓" + doneCount)
    if (workingCount > 0) parts.push(String(workingCount))
    return parts.join(" ")
  }

  readonly property bool opened: panel ? panel.opened === true : false

  function anyOpened() {
    var items = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : [root]
    for (var i = 0; i < items.length; i++) if (items[i] && items[i].opened === true) return true
    return false
  }

  // IPC binds to one monitor's widget; test calls go to whichever panel is open.
  function openPanel() {
    var items = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : [root]
    for (var i = 0; i < items.length; i++) if (items[i] && items[i].opened === true) return items[i].panel
    return panel
  }

  function open() { if (panel) panel.open() }
  function close() { if (panel) panel.close() }
  function togglePanel() { if (panel) panel.toggle() }

  readonly property real openPanelIndicatorWidth: button.width
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  readonly property bool popoutSwitchClosing: panel ? panel.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panel) panel.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "ninepointlabs.speakeasy"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function isOpen(): string { return root.anyOpened() ? "true" : "false" }
    function status(): string {
      var p = root.openPanel()
      if (!p) return "{}"
      return JSON.stringify({ open: p.opened, view: p.view, loaded: p.loaded, tasks: p.tasks.length,
                              needs: p.needsCount, done: p.doneCount, working: p.workingCount,
                              selected: p.selected, error: p.error })
    }
    function key(name: string): string { var p = root.openPanel(); return p ? p.ipcKey(name) : "no panel" }
    function renderTo(path: string): string { var p = root.openPanel(); return p ? p.renderTo(path) : "no panel" }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    labelVisible: false
    hasVisualContent: true
    fixedWidth: root.vertical ? -1 : Math.round(chipRow.implicitWidth + Style.spaceReal(horizontalMargin) * 2)
    fixedHeight: root.vertical ? Style.bar.iconSlot : -1
    horizontalMargin: root.labelText !== "" && root.showCounts && !root.vertical ? 7 : 6
    tooltipText: {
      if (!root.panel || root.panel.tasks.length === 0) return "Speakeasy · no tasks"
      var bits = []
      if (root.needsCount > 0) bits.push(root.needsCount + " need you")
      if (root.doneCount > 0) bits.push(root.doneCount + " done")
      if (root.workingCount > 0) bits.push(root.workingCount + " working")
      return "Speakeasy · " + (bits.length ? bits.join(", ") : "nothing running")
    }

    onPressed: function(b) { root.togglePanel() }

    Row {
      id: chipRow
      anchors.centerIn: parent
      spacing: Style.space(5)

      OpticalGlyph {
        width: Style.bar.iconCanvas + Style.space(2)
        height: width
        anchors.verticalCenter: parent.verticalCenter
        text: String.fromCodePoint(0xF0356)
        fontFamily: button.fontFamily
        fontSize: Style.bar.iconFont
        color: root.chipColor
      }

      Text {
        visible: root.showCounts && !root.vertical && root.labelText !== ""
        textFormat: Text.PlainText
        text: root.labelText
        color: root.chipColor
        font.family: button.fontFamily
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }
}
