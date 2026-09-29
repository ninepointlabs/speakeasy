import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// The Speakeasy panel: the list of tasks (attention first), a peek at the
// selected task's screen, and the form that starts a new one. It shows two
// ways: dropped from the bar icon, or (from a keybinding) as a window in
// the middle of the focused screen. The same content item moves between the
// two hosts, so there is one UI to keep keyboard-complete. Everything
// runs through the bundled `speakeasy` CLI; this file only renders state
// and forwards keys.
Panel {
  id: root
  moduleName: "ninepointlabs.speakeasy"

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string pluginDir: decodeURIComponent(Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string cli: pluginDir + "/bin/speakeasy"
  // Screenshot mode (IPC `capture`): a separate state directory holding demo
  // tasks, and a window that does not take the keyboard.
  property string demoStateHome: ""
  property bool capturing: false
  readonly property var procEnv: demoStateHome !== "" ? ({ XDG_STATE_HOME: demoStateHome }) : ({})
  readonly property string stateDir: (demoStateHome || Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/speakeasy"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color faint: Qt.darker(foreground, 2.1)

  // ---------------------------------------------------------------- state --

  property var tasks: []
  property var agentList: []
  property var prefs: ({})
  property bool loaded: false
  property bool tmuxOk: true
  property string error: ""
  property real nowMs: Date.now()

  readonly property int needsCount: countWhere(function(t) { return t.status === "needs-you" })
  readonly property int doneCount: countWhere(function(t) { return t.status !== "needs-you" && t.unseen === true })
  readonly property int workingCount: countWhere(function(t) { return t.status === "running" || t.status === "starting" })
  readonly property int finishedCount: countWhere(function(t) { return t.status === "exited" || t.status === "stopped" })

  function countWhere(pred) {
    var n = 0
    for (var i = 0; i < tasks.length; i++) if (pred(tasks[i])) n++
    return n
  }

  // Centered presentation (keybinding) instead of the bar dropdown.
  property bool centered: false
  property var targetScreen: null
  property Item keyHome: null
  readonly property bool shown: opened || centered

  // "list" or "new"
  property string view: "list"
  property int selected: 0
  property bool peekOn: false
  property string peekText: ""
  property string confirmId: ""
  readonly property var selectedTask: selected >= 0 && selected < tasks.length ? tasks[selected] : null

  // New-task form. formFocus: 0 agent, 1 model, 2 effort, 3 title,
  // 4 description, 5 folder. Rows an agent has no use for are skipped.
  property int agentIndex: 0
  property int modelIndex: 0
  property string effort: ""
  property int formFocus: 3
  property bool starting: false
  readonly property var installedAgents: agentList.filter(function(a) { return a.installed })
  readonly property var currentAgent: agentIndex >= 0 && agentIndex < installedAgents.length ? installedAgents[agentIndex] : null
  readonly property var currentModels: currentAgent ? currentAgent.models : []
  readonly property string currentModel: currentModels[modelIndex] || ""
  readonly property var currentEfforts: {
    if (!currentAgent) return []
    var per = currentAgent.modelEfforts ? currentAgent.modelEfforts[currentModel] : null
    return per && per.length ? per : (currentAgent.efforts || [])
  }
  readonly property var modelOptions: currentModels.map(function(m) { return { value: m, label: root.modelLabel(m) } })
  readonly property var effortOptions: [{ value: "", label: "Default" }].concat(
    currentEfforts.map(function(e) { return { value: e, label: e } }))

  // Keep the chosen effort valid when the model changes.
  onCurrentEffortsChanged: if (effort !== "" && currentEfforts.indexOf(effort) === -1) effort = ""

  function rowVisible(i) {
    if (i === 1) return currentModels.length > 1
    if (i === 2) return currentEfforts.length > 0
    return true
  }
  function moveFocus(dir) {
    var i = formFocus
    for (var n = 0; n < 6; n++) {
      i = (i + dir + 6) % 6
      if (rowVisible(i)) break
    }
    setFormFocus(i)
  }

  function applyState(text) {
    var data
    try { data = JSON.parse(text) } catch (e) { error = "Could not read task state."; return }
    var keepId = selectedTask ? selectedTask.id : ""
    tasks = data.tasks || []
    agentList = data.agents || []
    prefs = data.prefs || ({})
    tmuxOk = data.tmux !== false
    loaded = true
    nowMs = Date.now()
    if (keepId !== "") {
      for (var i = 0; i < tasks.length; i++) if (tasks[i].id === keepId) { selected = i; break }
    }
    if (selected >= tasks.length) selected = Math.max(0, tasks.length - 1)
    if (confirmId !== "" && !tasks.some(function(t) { return t.id === confirmId })) confirmId = ""
  }

  property bool refreshQueued: false
  function refresh() {
    if (stateProc.running) { refreshQueued = true; return }
    stateProc.running = true
  }

  function run(args, after) {
    if (actionProc.running) { Quickshell.execDetached([cli].concat(args)); refresh(); return }
    actionProc.after = after || null
    actionProc.command = [cli].concat(args)
    actionProc.running = true
  }

  // -------------------------------------------------------------- actions --

  function move(delta) {
    if (tasks.length === 0) return
    confirmId = ""
    selected = Math.max(0, Math.min(tasks.length - 1, selected + delta))
    peekText = ""
    if (peekOn) refreshPeek()
    ensureVisible()
  }

  function openSelected() {
    var t = selectedTask
    if (!t) return
    // A task that ended keeps its screen (tmux holds dead panes), so opening
    // it shows the final output, unless the session itself is gone.
    if (t.alive === false) { error = "That task's terminal is gone (after a reboot, say). Remove it with x."; return }
    Quickshell.execDetached([cli, "open", t.id])
    dismiss()
  }

  function stopOrRemove() {
    var t = selectedTask
    if (!t) return
    if (confirmId !== t.id) { confirmId = t.id; return }
    confirmId = ""
    var finished = t.status === "exited" || t.status === "stopped"
    run([finished ? "rm" : "stop", t.id])
  }

  function clearFinished() {
    if (finishedCount > 0) run(["clear"])
  }

  function togglePeek() {
    peekOn = !peekOn
    peekText = ""
    if (peekOn) refreshPeek()
  }

  function refreshPeek() {
    var t = selectedTask
    if (!t || peekProc.running) return
    peekProc.command = [cli, "peek", t.id, "-n", "14"]
    peekProc.running = true
  }

  function showNew() {
    confirmId = ""
    error = ""
    view = "new"
    // Pre-select the last agent and model used.
    var ai = 0
    for (var i = 0; i < installedAgents.length; i++) if (installedAgents[i].id === prefs.agent) ai = i
    agentIndex = ai
    var mi = currentModels.indexOf(prefs.model || "")
    modelIndex = mi >= 0 ? mi : 0
    effort = currentEfforts.indexOf(prefs.effort || "") >= 0 ? prefs.effort : ""
    titleField.text = ""
    descArea.text = ""
    folderField.text = prefs.cwd ? folderName(prefs.cwd) : ""
    setFormFocus(3)
  }

  function showList() {
    view = "list"
    error = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function setFormFocus(i) {
    formFocus = Math.max(0, Math.min(5, i))
    Qt.callLater(function() {
      var target = [formKeys, formKeys, formKeys, titleField, descArea, folderField][root.formFocus]
      if (target) target.forceActiveFocus()
    })
  }

  function cycleChoice(delta) {
    if (formFocus === 0 && installedAgents.length > 0) {
      agentIndex = (agentIndex + delta + installedAgents.length) % installedAgents.length
      modelIndex = 0
      effort = ""
    } else if (formFocus === 1 && currentModels.length > 0) {
      modelIndex = (modelIndex + delta + currentModels.length) % currentModels.length
    } else if (formFocus === 2 && effortOptions.length > 0) {
      var values = effortOptions.map(function(o) { return o.value })
      effort = values[(values.indexOf(effort) + delta + values.length) % values.length]
    }
  }

  // Enter / Space / ↓ on the model or effort row opens its dropdown.
  function openRowDropdown() {
    if (formFocus === 1) modelDrop.open()
    else if (formFocus === 2) effortDrop.open()
  }

  function submit() {
    if (!currentAgent || starting) return
    var title = titleField.text.trim()
    var prompt = descArea.text.trim()
    if (title === "" && prompt === "") { error = "Give the task a title or a description."; setFormFocus(3); return }
    error = ""
    starting = true
    // "--flag=value" so a title or description starting with "-" stays text.
    var args = ["new", "--json", "--agent=" + currentAgent.id, "--title=" + title, "--prompt=" + prompt]
    if (currentModel !== "") args.push("--model=" + currentModel)
    if (effort !== "") args.push("--effort=" + effort)
    if (folderField.text.trim() !== "") args.push("--cwd=" + folderField.text.trim())
    run(args, function(code, out, err) {
      root.starting = false
      if (code !== 0) { root.error = (err || "Could not start the task.").replace(/^speakeasy: /, ""); return }
      var id = ""
      try { id = JSON.parse(out).id } catch (e) {}
      root.pendingSelectId = id
      root.showList()
    })
  }
  property string pendingSelectId: ""
  onTasksChanged: {
    if (pendingSelectId === "") return
    for (var i = 0; i < tasks.length; i++) if (tasks[i].id === pendingSelectId) { selected = i; pendingSelectId = ""; break }
  }

  function ensureVisible() {
    Qt.callLater(function() {
      var row = taskRepeater.itemAt(root.selected)
      if (!row) return
      if (row.y < listFlick.contentY) listFlick.contentY = row.y
      else if (row.y + row.height > listFlick.contentY + listFlick.height)
        listFlick.contentY = row.y + row.height - listFlick.height
    })
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // Headless test hook: drive the panel by key name over IPC.
  function ipcKey(name) {
    if (!shown) return "closed"
    if (view === "list") {
      if (name === "down") move(1)
      else if (name === "up") move(-1)
      else if (name === "enter") openSelected()
      else if (name === "n") showNew()
      else if (name === "p") togglePeek()
      else if (name === "x") stopOrRemove()
      else if (name === "c") clearFinished()
      else if (name === "esc") { if (confirmId !== "") confirmId = ""; else dismiss() }
      else return "unknown key"
    } else {
      if (name === "esc") showList()
      else if (name === "tab") moveFocus(1)
      else if (name === "open") openRowDropdown()
      else if (name === "left") cycleChoice(-1)
      else if (name === "right") cycleChoice(1)
      else if (name === "submit") submit()
      else if (name.indexOf("focus:") === 0) setFormFocus(Number(name.slice(6)))
      else if (name.indexOf("title:") === 0) titleField.text = name.slice(6)
      else if (name.indexOf("desc:") === 0) descArea.text = name.slice(5)
      else if (name.indexOf("folder:") === 0) folderField.text = name.slice(7)
      else return "unknown key"
    }
    return "ok"
  }

  // Screenshot support: show the centered window on a named screen, reading
  // demo state, without taking the keyboard from whoever is at it.
  function capture(which, screenName, stateHome) {
    if (!/^\/[^\0]*$/.test(stateHome) || stateHome.indexOf("/../") !== -1) return "bad state dir"
    if (centered) leaveCenter()
    demoStateHome = stateHome
    capturing = true
    tasks = []
    loaded = false
    present(which)
    var list = Quickshell.screens
    for (var i = 0; i < list.length; i++) if (list[i].name === screenName) targetScreen = list[i]
    return "ok"
  }

  function endCapture() {
    if (centered) leaveCenter()
    capturing = false
    demoStateHome = ""
    refresh()
    return "ok"
  }

  // The card's rectangle in layout coordinates of its screen (for grim).
  function cardGeometry() {
    if (!centered) return "{}"
    var p = centerCard.mapToItem(null, 0, 0)
    return JSON.stringify({ screen: targetScreen ? targetScreen.name : "", x: Math.round(p.x), y: Math.round(p.y),
                            width: Math.round(centerCard.width), height: Math.round(centerCard.height) })
  }

  function renderTo(path) {
    if (!/^\/.*\.png$/.test(path) || path.indexOf("/../") !== -1) return "bad path"
    content.grabToImage(function(result) { result.saveToFile(path) })
    return "ok"
  }

  // ---------------------------------------------------------- formatting --

  function age(iso) {
    var t = Date.parse(iso)
    if (isNaN(t)) return ""
    var s = Math.max(0, Math.round((nowMs - t) / 1000))
    if (s < 60) return "now"
    if (s < 3600) return Math.floor(s / 60) + "m"
    if (s < 86400) return Math.floor(s / 3600) + "h"
    return Math.floor(s / 86400) + "d"
  }

  function folderName(path) {
    var home = Quickshell.env("HOME")
    if (path === home) return "~"
    if (path.indexOf(home + "/") === 0) path = "~" + path.slice(home.length)
    return path
  }

  function statusGlyph(s) {
    if (s === "needs-you") return String.fromCodePoint(0xF0028)
    if (s === "ready") return String.fromCodePoint(0xF0369)
    if (s === "running") return String.fromCodePoint(0xF0996)
    if (s === "starting") return String.fromCodePoint(0xF051F)
    if (s === "stopped") return String.fromCodePoint(0xF0666)
    return String.fromCodePoint(0xF05E0)
  }

  function statusColor(t) {
    if (t.status === "needs-you") return urgent
    if (t.status === "ready") return accent
    if (t.status === "exited" && t.exitCode !== 0 && t.exitCode !== null) return urgent
    if (t.status === "running" || t.status === "starting") return foreground
    return faint
  }

  function statusLabel(s) {
    return ({ "needs-you": "needs you", "ready": "done", "running": "working", "starting": "starting",
              "exited": "ended", "stopped": "stopped" })[s] || s
  }

  // A task's model as the agent names it ("Opus · latest", "GPT-6-Sol").
  function taskModelLabel(t) {
    if (!t.model) return ""
    for (var i = 0; i < agentList.length; i++)
      if (agentList[i].id === t.agent && agentList[i].modelLabels && agentList[i].modelLabels[t.model])
        return agentList[i].modelLabels[t.model]
    return t.model
  }

  function modelLabel(m) {
    if (m === "") return "default"
    var labels = currentAgent && currentAgent.modelLabels ? currentAgent.modelLabels : ({})
    return labels[m] || m
  }

  readonly property string subtitle: {
    if (!loaded) return "Loading…"
    if (tasks.length === 0) return "No tabs open"
    var bits = []
    if (needsCount > 0) bits.push(needsCount + " need" + (needsCount === 1 ? "s" : "") + " you")
    if (doneCount > 0) bits.push(doneCount + " done")
    if (workingCount > 0) bits.push(workingCount + " working")
    if (bits.length === 0) bits.push(tasks.length + " tab" + (tasks.length === 1 ? "" : "s"))
    return bits.join("  ·  ")
  }

  implicitWidth: 1
  implicitHeight: 1

  function onShown() {
    confirmId = ""
    view = "list"
    error = ""
    refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  onOpenedChanged: {
    if (!opened) { if (!centered) { peekOn = false; confirmId = "" } return }
    // The bar dropdown wins over a centered window on the same monitor.
    if (centered) leaveCenter()
    onShown()
  }

  // Keybinding entry: show the centered window on the focused monitor.
  // `list` toggles; `new` always opens (straight into the form).
  function present(which) {
    if (centered && which !== "new") { dismiss(); return "hidden" }
    if (opened) close()
    targetScreen = focusedScreen()
    if (!centered) {
      keyCatcher.parent = centerHost
      centered = true
      onShown()
    }
    if (which === "new") {
      if (loaded) showNew()
      else pendingNew = true
    }
    return "ok"
  }

  function leaveCenter() {
    centered = false
    if (keyHome) keyCatcher.parent = keyHome
  }

  // Close whichever way the panel is showing.
  function dismiss() {
    confirmId = ""
    peekOn = false
    if (centered) leaveCenter()
    else close()
  }

  function focusedScreen() {
    var name = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    var list = Quickshell.screens
    for (var i = 0; i < list.length; i++) if (list[i].name === name) return list[i]
    return list.length > 0 ? list[0] : null
  }

  Component.onCompleted: {
    keyHome = keyCatcher.parent
    refresh()
  }

  // ------------------------------------------------------------ processes --

  Process {
    id: stateProc
    environment: root.procEnv
    command: [root.cli, "state"]
    running: false
    stdout: StdioCollector { id: stateOut }
    stderr: StdioCollector { id: stateErr }
    onExited: function(code) {
      if (code === 0) { root.error = root.view === "list" ? "" : root.error; root.applyState(stateOut.text) }
      else root.error = (stateErr.text || "speakeasy state failed").trim()
      if (root.refreshQueued) { root.refreshQueued = false; Qt.callLater(root.refresh) }
    }
  }

  Process {
    id: actionProc
    environment: root.procEnv
    property var after: null
    running: false
    stdout: StdioCollector { id: actionOut }
    stderr: StdioCollector { id: actionErr }
    onExited: function(code) {
      var cb = actionProc.after
      actionProc.after = null
      if (cb) cb(code, actionOut.text, actionErr.text.trim())
      else if (code !== 0) root.error = actionErr.text.trim().replace(/^speakeasy: /, "")
      root.refresh()
    }
  }

  Process {
    id: peekProc
    environment: root.procEnv
    running: false
    stdout: StdioCollector { id: peekOut }
    onExited: function(code) { root.peekText = code === 0 ? peekOut.text.replace(/\s+$/, "") : "" }
  }

  property bool pendingNew: false
  onLoadedChanged: if (loaded && pendingNew) { pendingNew = false; showNew() }

  // The CLI touches `rev` on every state change, hooks included.
  FileView {
    path: root.stateDir + "/rev"
    watchChanges: true
    printErrors: false
    onFileChanged: { reload(); root.refresh() }
  }

  Timer {
    interval: root.shown ? 4000 : 20000
    repeat: true
    running: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 2000
    repeat: true
    running: root.shown && root.peekOn && root.view === "list"
    onTriggered: root.refreshPeek()
  }

  // --------------------------------------------------------------- pieces --

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: root.view === "list" ? keyCatcher : titleField
    contentWidth: panel.fittedContentWidth(Style.space(620))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(900))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.view !== "list"
      onCloseRequested: {
        if (root.confirmId !== "") { root.confirmId = ""; return }
        if (root.peekOn) { root.peekOn = false; return }
        root.dismiss()
      }
      onTabRequested: function(direction) { if (!root.centered) root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.move(dy) }
      onActivateRequested: {
        if (root.confirmId !== "") root.stopOrRemove()
        else root.openSelected()
      }
      onDeleteRequested: root.stopOrRemove()
      onTextKey: function(t) {
        if (t === "n" || t === "N") root.showNew()
        else if (t === "p" || t === "P") root.togglePeek()
        else if (t === "c" || t === "C") root.clearFinished()
        else if (t === "y" && root.confirmId !== "") root.stopOrRemove()
      }

      Column {
        id: content
        anchors.fill: parent
        spacing: Style.space(10)

        // ------------------------------------------------------- header --
        Item {
          width: parent.width
          implicitHeight: Math.max(titleColumn.implicitHeight, headerActions.implicitHeight)

          Column {
            id: titleColumn
            anchors.left: parent.left
            anchors.right: headerActions.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Row {
              spacing: Style.space(6)
              Text {
                textFormat: Text.PlainText
                text: String.fromCodePoint(0xF0356)
                color: root.needsCount > 0 ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                anchors.verticalCenter: parent.verticalCenter
              }
              Text {
                textFormat: Text.PlainText
                text: root.view === "new" ? "New task" : "Speakeasy"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.view === "new" ? "Runs in a hidden terminal. You get a notification when it needs you or is done." : root.subtitle
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }
          }

          Row {
            id: headerActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            Button {
              visible: root.view === "list" && root.finishedCount > 0
              text: "Clear finished"
              tooltipText: "Remove every ended or stopped task (c)"
              foreground: root.dim
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(3)
              onClicked: root.clearFinished()
            }
            Button {
              visible: root.view === "list"
              iconText: String.fromCodePoint(0xF0415)
              text: "New task"
              tooltipText: "Start a task in a hidden terminal (n)"
              bordered: true
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              iconSize: Style.font.body
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(3)
              onClicked: root.showNew()
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        // ------------------------------------------------ setup problems --
        Text {
          visible: root.loaded && !root.tmuxOk
          width: parent.width
          textFormat: Text.PlainText
          text: "Speakeasy needs tmux to keep terminals out of sight. Install it with `omarchy pkg add tmux` (or your distribution's package manager)."
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.Wrap
        }

        // ---------------------------------------------------------- list --
        Text {
          visible: root.view === "list" && root.loaded && root.tasks.length === 0
          width: parent.width
          topPadding: Style.space(8)
          bottomPadding: Style.space(8)
          textFormat: Text.PlainText
          text: "Nothing on the tab. Press n to hand an agent a task; it works out of sight and taps you on the shoulder when it needs you."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.Wrap
        }

        Flickable {
          id: listFlick
          visible: root.view === "list" && root.tasks.length > 0
          width: parent.width
          height: Math.min(listColumn.implicitHeight, Style.space(root.peekOn ? 300 : 520))
          contentWidth: width
          contentHeight: listColumn.implicitHeight
          boundsBehavior: Flickable.StopAtBounds
          clip: true

          Column {
            id: listColumn
            width: listFlick.width
            spacing: Style.space(6)

            Repeater {
              id: taskRepeater
              model: root.tasks

              Rectangle {
                id: row
                required property var modelData
                required property int index
                readonly property bool isSelected: index === root.selected
                readonly property bool confirming: root.confirmId === modelData.id
                readonly property bool finished: modelData.status === "exited" || modelData.status === "stopped"
                width: listColumn.width
                radius: Style.cornerRadius
                color: isSelected || rowMouse.containsMouse ? Style.hoverFillFor(root.foreground, root.accent) : Style.normalFillFor(root.foreground, root.accent)
                border.width: isSelected ? Math.max(1, Style.space(2)) : Style.spacing.hairline
                border.color: isSelected ? root.accent : Style.normalBorderFor(root.foreground, root.accent)
                implicitHeight: rowColumn.implicitHeight + Style.space(16)

                MouseArea {
                  id: rowMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: { root.selected = row.index; root.openSelected() }
                }

                Text {
                  id: rowGlyph
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.leftMargin: Style.space(10)
                  anchors.topMargin: Style.space(8)
                  textFormat: Text.PlainText
                  text: root.statusGlyph(modelData.status)
                  color: root.statusColor(modelData)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                }

                Column {
                  id: rowColumn
                  anchors.left: rowGlyph.right
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  anchors.topMargin: Style.space(8)
                  spacing: Style.space(2)

                  Item {
                    width: parent.width
                    implicitHeight: titleText.implicitHeight

                    Text {
                      id: titleText
                      anchors.left: parent.left
                      anchors.right: stateText.left
                      anchors.rightMargin: Style.space(8)
                      textFormat: Text.PlainText
                      text: (modelData.unseen ? "● " : "") + modelData.title
                      color: row.finished ? root.dim : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: modelData.unseen === true || modelData.status === "needs-you"
                      elide: Text.ElideRight
                    }
                    Text {
                      id: stateText
                      anchors.right: parent.right
                      textFormat: Text.PlainText
                      text: root.statusLabel(modelData.status) + "  " + root.age(modelData.updatedAt)
                      color: root.statusColor(modelData)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: [modelData.agentName, root.taskModelLabel(modelData), modelData.effort || ""].filter(function(x) { return x !== "" }).join(" · ")
                          + "  ·  " + root.folderName(modelData.cwd) + (modelData.attached ? "  ·  on screen" : "")
                    color: root.faint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideMiddle
                  }

                  Text {
                    visible: text !== ""
                    width: parent.width
                    textFormat: Text.PlainText
                    text: row.confirming
                      ? (row.finished ? "Remove this task and its terminal? x or Enter to confirm, Esc to cancel" : "Stop this task? x or Enter to confirm, Esc to cancel")
                      : (modelData.detail || "")
                    color: row.confirming ? root.urgent : (modelData.status === "needs-you" ? root.urgent : root.dim)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                  }
                }
              }
            }
          }
        }

        // ---------------------------------------------------------- peek --
        Rectangle {
          visible: root.view === "list" && root.peekOn && root.selectedTask !== null
          width: parent.width
          height: Style.space(260)
          radius: Style.cornerRadius
          color: Qt.rgba(0, 0, 0, 0.25)
          border.width: Style.spacing.hairline
          border.color: Style.normalBorderFor(root.foreground, root.accent)
          clip: true

          Text {
            anchors.fill: parent
            anchors.margins: Style.space(8)
            textFormat: Text.PlainText
            text: root.peekText !== "" ? root.peekText : "…"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
            verticalAlignment: Text.AlignBottom
          }
        }

        // ---------------------------------------------------------- form --
        Column {
          visible: root.view === "new"
          width: parent.width
          spacing: Style.space(10)

          Text {
            visible: root.installedAgents.length === 0
            width: parent.width
            textFormat: Text.PlainText
            text: "No supported agent is installed. Speakeasy knows Claude Code, Codex, Gemini (Antigravity CLI), opencode, Cursor Agent and Crush; others can be added in ~/.config/speakeasy/config.json."
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
          }

          // Agent chips and the model / effort dropdowns share one key
          // handler: ←/→ change the choice in place, Enter / Space / ↓ open
          // a dropdown (type to filter), Tab moves on.
          FocusScope {
            id: formKeys
            width: parent.width
            implicitHeight: pickerColumn.implicitHeight
            activeFocusOnTab: false

            Keys.onPressed: function(event) {
              var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
              var onDrop = root.formFocus === 1 || root.formFocus === 2
              if (event.key === Qt.Key_Escape) { root.showList(); event.accepted = true }
              else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && ctrl) { root.submit(); event.accepted = true }
              else if (event.key === Qt.Key_Left || event.text === "h") { root.cycleChoice(-1); event.accepted = true }
              else if (event.key === Qt.Key_Right || event.text === "l") { root.cycleChoice(1); event.accepted = true }
              else if (onDrop && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space || event.key === Qt.Key_Down)) {
                root.openRowDropdown(); event.accepted = true
              }
              else if (event.key === Qt.Key_Backtab || event.key === Qt.Key_Up) { root.moveFocus(-1); event.accepted = true }
              else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Down || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.moveFocus(1); event.accepted = true
              }
            }

            Column {
              id: pickerColumn
              width: parent.width
              spacing: Style.space(8)

              Row {
                width: parent.width
                spacing: Style.space(6)

                Text {
                  id: agentLabel
                  width: Style.space(84)
                  topPadding: Style.space(4)
                  textFormat: Text.PlainText
                  text: "Agent"
                  color: formKeys.activeFocus && root.formFocus === 0 ? root.accent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: formKeys.activeFocus && root.formFocus === 0
                }

                Flow {
                  width: parent.width - agentLabel.width - parent.spacing
                  spacing: Style.space(6)

                  Repeater {
                    model: root.installedAgents

                    Rectangle {
                      id: chip
                      required property var modelData
                      required property int index
                      readonly property bool chosen: index === root.agentIndex
                      radius: Style.cornerRadius
                      implicitWidth: chipText.implicitWidth + Style.space(18)
                      implicitHeight: chipText.implicitHeight + Style.space(8)
                      color: chosen ? Style.hoverFillFor(root.foreground, root.accent) : "transparent"
                      border.width: chosen ? Math.max(1, Style.space(2)) : Style.spacing.hairline
                      border.color: chosen ? (formKeys.activeFocus && root.formFocus === 0 ? root.accent : root.dim) : Style.normalBorderFor(root.foreground, root.accent)

                      Text {
                        id: chipText
                        anchors.centerIn: parent
                        textFormat: Text.PlainText
                        text: chip.modelData.name
                        color: chip.chosen ? root.foreground : root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        font.bold: chip.chosen
                      }

                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                          root.agentIndex = chip.index
                          root.modelIndex = 0
                          root.effort = ""
                          root.setFormFocus(0)
                        }
                      }
                    }
                  }
                }
              }

              Row {
                visible: root.rowVisible(1)
                width: parent.width
                spacing: Style.space(6)

                Text {
                  id: modelLabelText
                  width: Style.space(84)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: "Model"
                  color: formKeys.activeFocus && root.formFocus === 1 ? root.accent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: formKeys.activeFocus && root.formFocus === 1
                }

                SearchableDropdown {
                  id: modelDrop
                  width: parent.width - modelLabelText.width - parent.spacing
                  showLabel: false
                  options: root.modelOptions
                  value: root.currentModel
                  placeholderText: "Type to filter models…"
                  hasCursor: formKeys.activeFocus && root.formFocus === 1
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onChanged: function(v) {
                    var i = root.currentModels.indexOf(v)
                    if (i >= 0) root.modelIndex = i
                    root.setFormFocus(1)
                  }
                  onPopupOpenChanged: if (!popupOpen && root.view === "new" && root.formFocus === 1) root.setFormFocus(1)
                }
              }

              Row {
                visible: root.rowVisible(2)
                width: parent.width
                spacing: Style.space(6)

                Text {
                  id: effortLabelText
                  width: Style.space(84)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: "Effort"
                  color: formKeys.activeFocus && root.formFocus === 2 ? root.accent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: formKeys.activeFocus && root.formFocus === 2
                }

                Dropdown {
                  id: effortDrop
                  width: Style.space(220)
                  showLabel: false
                  options: root.effortOptions
                  value: root.effort
                  hasCursor: formKeys.activeFocus && root.formFocus === 2
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onChanged: function(v) { root.effort = v; root.setFormFocus(2) }
                  onPopupOpenChanged: if (!popupOpen && root.view === "new" && root.formFocus === 2) root.setFormFocus(2)
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            text: "Title"
            color: titleField.activeFocus ? root.accent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          TextField {
            id: titleField
            width: parent.width
            placeholderText: "What the tab is called, e.g. Fix the login redirect"
            foreground: root.foreground
            accent: root.accent
            font.family: root.fontFamily
            onActiveFocusChanged: if (activeFocus) root.formFocus = 3
            Keys.onReturnPressed: function(event) { if (event.modifiers & Qt.ControlModifier) root.submit(); else root.setFormFocus(4) }
            Keys.onEnterPressed: function(event) { if (event.modifiers & Qt.ControlModifier) root.submit(); else root.setFormFocus(4) }
            Keys.onTabPressed: root.moveFocus(1)
            Keys.onBacktabPressed: root.moveFocus(-1)
            Keys.onEscapePressed: root.showList()
          }

          Text {
            textFormat: Text.PlainText
            text: "Description"
            color: descArea.activeFocus ? root.accent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          Rectangle {
            width: parent.width
            height: Style.space(150)
            radius: Style.cornerRadius
            color: Style.controlFill(descArea.activeFocus, false, root.foreground, root.accent)
            border.width: descArea.activeFocus ? Math.max(1, Style.space(2)) : Style.spacing.hairline
            border.color: descArea.activeFocus ? root.accent : Style.normalBorderFor(root.foreground, root.accent)

            ScrollView {
              anchors.fill: parent
              anchors.margins: Style.space(2)

              TextArea {
                id: descArea
                placeholderText: "Tell the agent what to do. Enter adds a line; Ctrl+Enter starts the task."
                placeholderTextColor: Qt.darker(root.foreground, 1.6)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: TextEdit.Wrap
                selectByMouse: true
                background: null
                onActiveFocusChanged: if (activeFocus) root.formFocus = 4
                Keys.onPressed: function(event) {
                  var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
                  if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && ctrl) { root.submit(); event.accepted = true }
                  else if (event.key === Qt.Key_Tab) { root.moveFocus(1); event.accepted = true }
                  else if (event.key === Qt.Key_Backtab) { root.moveFocus(-1); event.accepted = true }
                  else if (event.key === Qt.Key_Escape) { root.showList(); event.accepted = true }
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            text: "Folder"
            color: folderField.activeFocus ? root.accent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          TextField {
            id: folderField
            width: parent.width
            placeholderText: "~/Projects/something"
            foreground: root.foreground
            accent: root.accent
            font.family: root.fontFamily
            onActiveFocusChanged: if (activeFocus) root.formFocus = 5
            Keys.onReturnPressed: root.submit()
            Keys.onEnterPressed: root.submit()
            Keys.onTabPressed: root.moveFocus(1)
            Keys.onBacktabPressed: root.moveFocus(-1)
            Keys.onEscapePressed: root.showList()
          }

          Row {
            spacing: Style.space(6)
            Button {
              text: root.starting ? "Starting…" : "Start task"
              bordered: true
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.body
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.submit()
            }
            Button {
              text: "Back"
              foreground: root.dim
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.body
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.showList()
            }
          }
        }

        // --------------------------------------------------------- error --
        Text {
          visible: root.error !== ""
          width: parent.width
          textFormat: Text.PlainText
          text: root.error
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.Wrap
        }

        // --------------------------------------------------------- hints --
        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.view === "new"
            ? "Tab next field  ·  ←→ choose  ·  Enter open list, type to filter  ·  Ctrl+Enter start  ·  Esc back"
            : (root.tasks.length > 0 ? "Enter open  ·  n new  ·  p peek  ·  x stop / remove  ·  c clear finished  ·  Esc close"
                                     : "n new  ·  Esc close")
          color: root.faint
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }

  // ------------------------------------------------------ centered window --

  PanelWindow {
    id: centerWin
    visible: root.centered
    screen: root.targetScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-speakeasy"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.capturing ? WlrKeyboardFocus.None : WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    onVisibleChanged: if (visible) Qt.callLater(function() {
      if (root.view === "new") root.setFormFocus(root.formFocus)
      else keyCatcher.forceActiveFocus()
    })

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.45)
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: centerCard
      anchors.centerIn: parent
      width: Math.min(parent.width - Style.space(80), Style.space(680))
      height: Math.min(parent.height - Style.space(80), content.implicitHeight + Style.spacing.popupPadding * 2)
      radius: Style.cornerRadius
      color: Color.popups.background
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))

      // Clicks inside the card must not reach the scrim's dismiss.
      MouseArea { anchors.fill: parent }

      Item {
        id: centerHost
        anchors.fill: parent
        anchors.margins: Style.spacing.popupPadding
      }
    }
  }
}
