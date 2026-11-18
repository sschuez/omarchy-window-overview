import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Widgets
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Windows.js" as Windows

// Window Overview: every open window as a live thumbnail. Type to narrow them
// down; Enter, a click or a workspace's number jumps to one, Ctrl+W closes one.
//
// It is also an Alt+Tab switcher: opened that way, windows are ordered most
// recently used first and letting go of Alt jumps to the selected one.
//
// A plugin cannot bind keys. The user binds them in Hyprland (see the README)
// and they arrive through the global shortcuts at the bottom of this file.
Item {
  id: root

  property var shell: null
  property var manifest: null
  readonly property string pluginId: (manifest && manifest.id) || "io.github.sschuez.window-overview"

  // What was last asked for. The shell reads it to tell open from closed.
  property bool opened: false
  // Opened with Alt+Tab: most recently used first, no search.
  property bool switching: false
  // Letting go of Alt picks the selected window.
  property bool commitOnRelease: false
  // On screen. A quick Alt+Tab switches before the overview ever shows.
  property bool revealed: false
  property string filterText: ""
  // The selected window, by address: it stays selected while other windows
  // open, close or change place. Unknown means the first one shown.
  property string selectedAddress: ""
  readonly property int selectedIndex: slots[selectedAddress] === undefined ? 0 : slots[selectedAddress]
  // Window addresses, most recently focused first.
  property var recent: []

  // The menu's colours, so a theme that styles the menu styles this too.
  readonly property color background: Commons.Color.menu.background
  readonly property color foreground: Commons.Color.menu.text
  readonly property color accent: Commons.Color.menu.selectedText
  // Solid, whatever alpha the theme gives its menus: text showing through from
  // the desktop behind makes the thumbnails harder to read.
  readonly property color shade: Qt.rgba(background.r, background.g, background.b, 1)
  readonly property color placeholder: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.08)
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", Commons.Color.menu.border, Math.max(1, Style.space(2)))
  readonly property int cornerRadius: Style.cornerRadius
  readonly property string fontFamily: Style.font.menuFamily

  readonly property int outerMargin: Style.space(48)
  readonly property int tileGap: Style.space(32)
  readonly property int ringWidth: Math.max(2, Style.space(3))
  readonly property int ringGap: Style.space(4)
  readonly property int iconSize: Style.font.iconLarge
  readonly property int labelGap: Style.spacing.xl
  readonly property int labelHeight: labelGap + Math.max(iconSize, appMetrics.height) + titleMetrics.height
  readonly property int searchHeight: Math.max(Style.space(34), Style.font.heading + Style.spacing.controlPaddingY * 2)

  // Every window that can be shown, then the ones on screen in display order,
  // where each of those sits, and which slot a given window has.
  readonly property var windows: opened ? collect() : []
  readonly property var shown: {
    if (switching) return windows.slice().sort(Windows.byRecency(recent))
    if (filterText.trim()) return Windows.search(windows, filterText)
    return windows.slice().sort(Windows.byWorkspace)
  }
  readonly property var tiles: Windows.layout(shown.map(function(window) { return window.aspect }),
    grid.width, grid.height, tileGap, labelHeight, grid.height * 0.6)
  readonly property var slots: {
    var map = ({})
    for (var i = 0; i < shown.length; i++) map[shown[i].address] = i
    return map
  }

  // A new search starts on its best match.
  onFilterTextChanged: {
    selectedAddress = ""
    pointerGate.reset()
  }

  // ------------------------------------------------------------- windows

  function collect() {
    var out = []
    var toplevels = Hyprland.toplevels.values
    for (var i = 0; i < toplevels.length; i++) {
      var window = describe(toplevels[i])
      if (window) out.push(window)
    }
    return out
  }

  // What the overview needs to know about one window, or null for one it
  // leaves out: not on screen yet, or parked on a special workspace
  // (scratchpad, minimized).
  function describe(toplevel) {
    var ipc = toplevel.lastIpcObject || ({})
    var workspace = toplevel.workspace
    if (!toplevel.wayland || !workspace || !(workspace.id > 0) || ipc.mapped === false) return null

    var appId = String(toplevel.wayland.appId || ipc["class"] || "")
    var entry = entryFor(appId)
    var app = Windows.label(entry && entry.name ? entry.name : Windows.appName(appId))
    var title = Windows.label(toplevel.title || app)
    var at = ipc.at || [], size = ipc.size || []
    return {
      address: String(toplevel.address || ""),
      app: app,
      title: title,
      icon: iconFor(entry, appId),
      workspaceId: workspace.id,
      workspaceName: Windows.label(workspace.name || workspace.id),
      active: toplevel.activated === true,
      x: Number(at[0]) || 0,
      y: Number(at[1]) || 0,
      aspect: Windows.aspect(size[0], size[1]),
      focusHistory: typeof ipc.focusHistoryID === "number" ? ipc.focusHistoryID : 9999,
      haystack: (app + " " + title).toLowerCase()
    }
  }

  // The desktop entry behind a window. A web app's window names its site, not
  // its launcher, so it is matched by name: app.hey.com is the entry "HEY".
  function entryFor(appId) {
    var entry = DesktopEntries.heuristicLookup(appId)
    var host = Windows.webAppHost(appId)
    if (entry || !host) return entry
    var labels = host.toLowerCase().split(".")
    var entries = DesktopEntries.applications.values
    for (var i = 0; i < entries.length; i++)
      if (labels.indexOf(String(entries[i].name || "").toLowerCase()) >= 0) return entries[i]
    return null
  }

  // Only a desktop entry, a file this session installed, may point at an image
  // file. An app id is picked by the app itself, so it is only ever looked up
  // as the name of a theme icon.
  function iconFor(entry, appId) {
    var icon = entry && entry.icon ? String(entry.icon) : ""
    if (icon.charAt(0) === "/") return Util.fileUrl(icon)
    return Quickshell.iconPath(icon || Windows.iconName(appId) || "application-x-executable", "application-x-executable")
  }

  // ------------------------------------------------------- open and close

  // The shell calls open() with a payload: {} for the overview, or
  // {"switch": 1} / {"switch": -1} to start switching forward or back.
  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(String(payloadJson || "{}")) || ({}) } catch (e) {}
    show(payload["switch"] === 1 || payload["switch"] === -1 ? payload["switch"] : 0)
  }

  function show(step) {
    if (root.opened) return
    filterInput.text = ""
    root.switching = step !== 0
    root.commitOnRelease = root.switching
    root.opened = true
    pointerGate.reset()
    // Sizes and positions are only as fresh as the last refresh.
    Hyprland.refreshToplevels()

    // Where the window in use sits, or -1 on an empty workspace. Just after
    // the shell starts no window is marked active yet; the last one used is.
    var current = -1
    for (var i = 0; i < root.shown.length && current < 0; i++)
      if (root.shown[i].active) current = i
    if (current < 0 && root.slots[root.recent[0]] !== undefined) current = root.slots[root.recent[0]]
    if (!root.switching) {
      root.selectIndex(current)
      root.revealed = true
    } else {
      // Forward starts on the window used before this one, back on the oldest.
      root.selectIndex(step > 0 ? Math.min(current + 1, root.shown.length - 1) : root.shown.length - 1)
      root.revealed = false
      revealTimer.restart()
    }
    Qt.callLater(function() { filterInput.forceActiveFocus() })
  }

  // The shell closing the overview. Must not call back into the shell.
  function close() {
    root.opened = false
    root.revealed = false
    revealTimer.stop()
    // Focus may have moved while the overview was up: a window opened or closed.
    root.remember()
  }

  // Closing on our own account: Escape, a click, or a window picked.
  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.show(0)
  }

  // ------------------------------------------------------------ selection

  function selectIndex(index) {
    selectedAddress = shown[index] ? shown[index].address : ""
  }

  function select(delta) {
    if (shown.length > 0) selectIndex((selectedIndex + delta + shown.length) % shown.length)
  }

  function selectRow(direction) {
    selectIndex(Windows.neighbour(tiles, selectedIndex, direction))
  }

  // How a Hyprland dispatch names the window at `index`, or "" when there is
  // none. Omarchy configures Hyprland in Lua, where a dispatch is a Lua
  // expression, so only an address that is plain hex is ever pasted into one.
  function target(index) {
    var window = shown[index]
    return window && Windows.validAddress(window.address) ? "window = \"address:0x" + window.address + "\"" : ""
  }

  function activate(index) {
    var window = root.target(index)
    root.dismiss()
    if (!window) return
    Hyprland.dispatch("hl.dsp.focus({ " + window + " })")
    Hyprland.dispatch("hl.dsp.window.alter_zorder({ mode = \"top\", " + window + " })")
  }

  // Close the window at `index` and stay open, so several can go in a row.
  // The selection moves to the window that takes its place.
  function closeWindow(index) {
    var window = root.target(index)
    if (!window) return
    if (index === root.selectedIndex) root.selectIndex(index + 1 < shown.length ? index + 1 : index - 1)
    Hyprland.dispatch("hl.dsp.window.close({ " + window + " })")
  }

  // Jump to the window on the workspace with this number, the most recently
  // used one if it holds several. Nothing happens for an empty workspace.
  function activateWorkspace(name) {
    var there = shown.filter(function(window) { return window.workspaceName === name })
    if (there.length > 0) root.activate(shown.indexOf(there.sort(Windows.byRecency(recent))[0]))
  }

  // Alt+Tab, forward or back: start switching, or step on if already open.
  function cycle(step) {
    if (!root.opened) return root.show(step)
    root.select(step)
    root.commitOnRelease = true
    root.revealed = true
  }

  // Alt let go.
  function commit() {
    if (root.opened && root.commitOnRelease) root.activate(root.selectedIndex)
  }

  // Remember the order windows were used in. Hyprland's own focus history is
  // only as fresh as the last refresh, too stale for a quick Alt+Tab; it only
  // seeds the list, for the windows that were open before this plugin loaded.
  function seedRecent() {
    var known = collect().sort(function(a, b) { return a.focusHistory - b.focusHistory })
    var seeded = root.recent.slice()
    for (var i = 0; i < known.length; i++)
      if (seeded.indexOf(known[i].address) < 0) seeded.push(known[i].address)
    root.recent = seeded
  }

  Component.onCompleted: Hyprland.refreshToplevels()

  Timer {
    interval: 500
    running: true
    onTriggered: root.seedRecent()
  }

  // Put the window in use at the front of the list. Not while the overview is
  // open: the order on screen must hold still while it is being stepped through.
  function remember() {
    var active = Hyprland.activeToplevel
    if (!active || root.opened) return
    var address = String(active.address)
    if (root.recent[0] === address) return
    root.recent = [address].concat(root.recent.filter(function(other) { return other !== address })).slice(0, 64)
  }

  Connections {
    target: Hyprland
    function onActiveToplevelChanged() { root.remember() }
  }

  Timer {
    id: revealTimer
    interval: 150
    onTriggered: if (root.opened) root.revealed = true
  }

  PointerMoveGate { id: pointerGate; referenceItem: grid }

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  FontMetrics { id: appMetrics; font.family: root.fontFamily; font.pixelSize: Style.font.title }
  FontMetrics { id: titleMetrics; font.family: root.fontFamily; font.pixelSize: Style.font.body }

  // ------------------------------------------------------------------- UI

  OverlayWindow {
    id: panel
    shown: root.opened && root.revealed
    WlrLayershell.namespace: "window-overview"

    Rectangle {
      anchors.fill: parent
      color: root.shade
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    Item {
      id: keys

      Keys.onPressed: function(event) {
        var ctrl = event.modifiers & Qt.ControlModifier
        var alt = event.modifiers & Qt.AltModifier
        var key = Util.readingKey(event)
        if (event.key === Qt.Key_Escape) {
          if (root.filterText) filterInput.text = ""
          else root.dismiss()
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.activate(root.selectedIndex)
        } else if (key === Qt.Key_Left || event.key === Qt.Key_Backtab || (ctrl && event.key === Qt.Key_P)
                   || (alt && event.key === Qt.Key_BracketLeft)) {
          root.select(-1)
        } else if (key === Qt.Key_Right || event.key === Qt.Key_Tab || (ctrl && event.key === Qt.Key_N)
                   || (alt && event.key === Qt.Key_BracketRight)) {
          root.select(1)
        } else if (event.key === Qt.Key_Up) {
          root.selectRow(-1)
        } else if (event.key === Qt.Key_Down) {
          root.selectRow(1)
        } else if (ctrl && event.key === Qt.Key_U) {
          filterInput.text = ""
        } else if ((ctrl || alt) && event.key === Qt.Key_W) {
          root.closeWindow(root.selectedIndex)
        } else if (!root.filterText && !ctrl && event.key >= Qt.Key_0 && event.key <= Qt.Key_9) {
          // A number is a workspace until a search is under way, then it is text.
          root.activateWorkspace(event.key === Qt.Key_0 ? "10" : String(event.key - Qt.Key_0))
        } else {
          return
        }
        event.accepted = true
      }
    }

    // Search line. Hidden while switching, but still there: it holds the
    // keyboard focus either way.
    BorderSurface {
      id: searchBox
      anchors.top: parent.top
      anchors.topMargin: root.outerMargin
      anchors.horizontalCenter: parent.horizontalCenter
      width: Math.min(Style.space(420), parent.width - root.outerMargin * 2)
      height: root.searchHeight + contentTopInset + contentBottomInset
      radius: root.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.md
      leftPadding: Style.spacing.xxl
      rightPadding: Style.spacing.xxl
      opacity: root.switching ? 0 : 1

      // A click on the search line is not a click on the backdrop.
      MouseArea { anchors.fill: parent; enabled: !root.switching; onClicked: {} }

      FilterInput {
        id: filterInput
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: searchBox.contentLeftInset
        anchors.rightMargin: searchBox.contentRightInset
        anchors.verticalCenter: parent.verticalCenter
        keyHandler: keys
        readOnly: root.switching
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
        onTextChanged: root.filterText = text
      }

      Text {
        anchors.fill: filterInput
        verticalAlignment: Text.AlignVCenter
        visible: !filterInput.text && !filterInput.preeditText
        textFormat: Text.PlainText
        text: strings.t("search")
        color: root.foreground
        opacity: 0.58
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
        elide: Text.ElideRight
      }
    }

    Item {
      id: grid
      anchors.top: root.switching ? parent.top : searchBox.bottom
      anchors.topMargin: root.switching ? root.outerMargin : root.tileGap
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.leftMargin: root.outerMargin
      anchors.rightMargin: root.outerMargin
      anchors.bottomMargin: root.outerMargin

      // One tile per window Hyprland knows, not per search result: a tile, and
      // the capture feeding it, lives as long as its window, so typing only
      // moves and hides tiles and never restarts a thumbnail.
      Repeater {
        model: Hyprland.toplevels

        delegate: Item {
          id: tile

          required property var modelData
          readonly property int slot: {
            var found = root.slots[String(modelData.address)]
            return found === undefined ? -1 : found
          }
          readonly property var window: slot >= 0 ? root.shown[slot] : null
          readonly property var box: slot >= 0 ? root.tiles[slot] : null
          readonly property bool selected: slot === root.selectedIndex
          // The thumbnail once it has a frame, until then the placeholder.
          readonly property Item picture: shot.hasContent ? frame : thumb

          visible: !!window && !!box
          x: box ? box.x : 0
          y: box ? box.y : 0
          width: box ? box.width : 0
          height: box ? box.height : 0

          Rectangle {
            id: thumb
            width: parent.width
            height: parent.height - root.labelHeight
            radius: root.cornerRadius
            color: shot.hasContent ? "transparent" : root.placeholder

            IconImage {
              anchors.centerIn: parent
              implicitSize: Math.min(parent.width, parent.height) * 0.3
              source: tile.window ? tile.window.icon : ""
              visible: !shot.hasContent
            }
          }

          ClippingRectangle {
            id: frame
            anchors.centerIn: thumb
            width: shot.width
            height: shot.height
            radius: root.cornerRadius
            color: "transparent"
            opacity: shot.hasContent ? 1 : 0

            // Live, and that includes windows on other workspaces: Hyprland
            // renders a window for capture whether or not it is on screen.
            ScreencopyView {
              id: shot
              readonly property real fit: sourceSize.width > 0 && sourceSize.height > 0
                ? Math.min(thumb.width / sourceSize.width, thumb.height / sourceSize.height) : 0
              width: sourceSize.width * fit
              height: sourceSize.height * fit
              captureSource: root.revealed && tile.visible ? tile.modelData.wayland : null
              live: true
            }
          }

          Rectangle {
            anchors.fill: tile.picture
            anchors.margins: -(root.ringGap + root.ringWidth)
            radius: root.cornerRadius + root.ringGap
            color: "transparent"
            border.color: root.accent
            border.width: root.ringWidth
            visible: tile.selected
          }

          // Which workspace the window is on, and the key that jumps to it.
          Rectangle {
            anchors.left: tile.picture.left
            anchors.top: tile.picture.top
            anchors.margins: Style.spacing.md
            width: Math.max(height, workspaceText.implicitWidth + Style.spacing.xl * 2)
            height: workspaceText.implicitHeight + Style.spacing.sm * 2
            radius: root.cornerRadius
            color: root.accent

            Text {
              id: workspaceText
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: tile.window ? tile.window.workspaceName : ""
              color: root.background
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
            }
          }

          Column {
            anchors.top: thumb.bottom
            anchors.topMargin: root.labelGap
            width: parent.width

            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              height: Math.max(root.iconSize, appMetrics.height)
              spacing: Style.spacing.md

              IconImage {
                id: appIcon
                anchors.verticalCenter: parent.verticalCenter
                implicitSize: root.iconSize
                source: tile.window ? tile.window.icon : ""
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(0, Math.min(implicitWidth, tile.width - appIcon.width - parent.spacing))
                textFormat: Text.PlainText
                text: tile.window ? tile.window.app : ""
                color: tile.selected ? root.accent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
              }
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              text: tile.window ? tile.window.title : ""
              color: root.foreground
              opacity: tile.selected ? 0.9 : 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.MiddleButton
            cursorShape: Qt.PointingHandCursor
            // Only a pointer that moves selects: one resting where a tile
            // turns up leaves the selection alone.
            onPositionChanged: function(mouse) {
              if (pointerGate.moved(tile, mouse)) root.selectIndex(tile.slot)
            }
            onClicked: function(mouse) {
              if (mouse.button === Qt.MiddleButton) root.closeWindow(tile.slot)
              else root.activate(tile.slot)
            }
          }
        }
      }

      Text {
        anchors.centerIn: parent
        visible: root.shown.length === 0
        textFormat: Text.PlainText
        text: root.filterText.trim() ? strings.t("noMatches").arg(root.filterText.trim()) : strings.t("noWindows")
        color: root.foreground
        opacity: 0.7
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
      }
    }
  }

  // --------------------------------------------------------------- keys
  //
  // Bound in Hyprland as hl.dsp.global("window-overview:<name>"), which
  // reaches the shell without starting a process per keypress.

  GlobalShortcut {
    appid: "window-overview"
    name: "toggle"
    description: "Toggle Window Overview"
    onPressed: root.toggle()
  }

  GlobalShortcut {
    appid: "window-overview"
    name: "switch-next"
    description: "Switch to the next window"
    onPressed: root.cycle(1)
  }

  GlobalShortcut {
    appid: "window-overview"
    name: "switch-previous"
    description: "Switch to the previous window"
    onPressed: root.cycle(-1)
  }

  GlobalShortcut {
    appid: "window-overview"
    name: "switch-commit"
    description: "Jump to the window selected while switching"
    onPressed: root.commit()
  }
}
