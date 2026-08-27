import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One widget, many servers. Every configured server gets a Service with its own
// tunnel and heartbeat, all alive at once, so the picker shows live states and
// switching costs nothing — the panel just points at another socket.
Panel {
  id: root
  moduleName: "orsa.remote-cliamp"
  ipcTarget: "remote-cliamp"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool hideWhenOffline: Model.asBool(setting("hideWhenOffline", false), false)

  // The `servers` array from shell.json, with the old one-server-per-entry shape
  // still accepted so an existing single entry keeps working.
  readonly property var serverConfigs: {
    var out = []
    var raw = settings ? settings.servers : undefined
    if (raw && raw.length !== undefined) {
      for (var i = 0; i < raw.length; i++) {
        var s = raw[i]
        if (s && String(s.sshTarget || "").length > 0) out.push(s)
      }
    }
    if (out.length === 0 && settings && String(settings.sshTarget || "").length > 0)
      out.push({ label: settings.label, sshTarget: settings.sshTarget,
                 remoteCliamp: settings.remoteCliamp, remoteSocket: settings.remoteSocket })
    // Nothing configured at all: the local cliamp is the sensible zero-config
    // default, so the widget works the moment it lands in the bar.
    if (out.length === 0) out.push({ label: "local", sshTarget: "local" })
    return out
  }

  function serverSettings(i) {
    var cfg = serverConfigs[i] || {}
    var target = String(cfg.sshTarget || "")
    return {
      label: String(cfg.label || ""),
      sshTarget: target,
      remoteSocket: String(cfg.remoteSocket || ".config/cliamp/cliamp.sock"),
      // Locally cliamp sits on PATH; the user-writable install path is a
      // workaround for servers where system paths are not user-writable.
      remoteCliamp: String(cfg.remoteCliamp || (target === "local" ? "cliamp" : "~/.local/bin/cliamp")),
      statusIntervalSec: setting("statusIntervalSec", 2),
      lyricTrimMs: setting("lyricTrimMs", 0)
    }
  }

  property var services: []
  property int activeIndex: 0
  readonly property var cliamp: (activeIndex >= 0 && activeIndex < services.length)
    ? services[activeIndex] : null

  Instantiator {
    model: root.serverConfigs.length
    delegate: Service {
      settings: root.serverSettings(index)
      panelOpen: root.opened && root.activeIndex === index
      queueOpen: root.queueOpen && root.opened && root.activeIndex === index
    }
    onObjectAdded: function (i, obj) {
      var next = root.services.slice()
      next.splice(i, 0, obj)
      root.services = next
      root.applyPersistedActive()
    }
    onObjectRemoved: function (i, obj) {
      var next = root.services.slice()
      next.splice(i, 1)
      root.services = next
      if (root.activeIndex >= next.length) root.activeIndex = 0
    }
  }

  // The chosen server survives a shell restart by riding shell.json like any
  // other inline setting, written back the way the stock clock persists its own.
  function applyPersistedActive() {
    var wanted = String(setting("activeServer", ""))
    if (wanted.length === 0) return
    for (var i = 0; i < services.length; i++) {
      if (services[i].label === wanted) { activeIndex = i; return }
    }
  }

  function setActive(i) {
    if (i < 0 || i >= services.length || i === activeIndex) { serverOpen = false; return }
    activeIndex = i
    serverOpen = false
    // Copy the shell's CURRENT entry and change only activeServer. Assigning
    // the copy back to root.settings would sever the binding to the shell, so
    // every later write would push a stale snapshot over shell.json — external
    // edits (renamed servers, new settings) silently reverted.
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.activeServer = services[i].label
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function cycleActive(step) {
    if (services.length < 2) return
    setActive((activeIndex + step + services.length) % services.length)
  }

  // 1a spec: playing is unmistakable — accent, with the bars breathing. Idle
  // dims, offline dims further and flattens the bars.
  readonly property color barIconColor: cliamp && cliamp.isPlaying
    ? Color.accent
    : Qt.darker(root.barForeground, cliamp && cliamp.running ? 1.55 : 2.4)

  readonly property real seekStepSec: 5

  property bool serverOpen: false
  property bool libraryOpen: false
  property bool queueOpen: false
  property bool helpOpen: false
  property bool lyricsOpen: false
  property bool lightsOpen: false

  readonly property string ledfxUrl: String(setting("ledfxUrl", ""))

  // The house lights are per-house, not per-server, so the client lives here.
  LedFx {
    id: ledfxClient
    url: root.ledfxUrl
  }

  // One open list section at a time; the cursor belongs to whichever it is.
  function openSection(which) {
    serverOpen = which === "server"
    libraryOpen = which === "library"
    queueOpen = which === "queue"
    helpOpen = which === "help"
    lyricsOpen = which === "lyrics"
    lightsOpen = which === "lights"
    if (lightsOpen) ledfxClient.refresh()
    cursorIndex = which === "server" ? activeIndex
      : which === "queue" && cliamp ? cliamp.queueIndex : 0
    revealCursor()
  }
  property int phraseIndex: 0
  property int cursorIndex: 0

  readonly property int phraseIntervalMs: 2800

  readonly property var activePhrases: [
    "Playing in another room",
    "Verbs over ssh, bits stay home",
    "The DAC is down the hall",
    "One socket, forwarded",
    "Nothing streams through here",
    "Remote spindle spinning",
    "Latency is someone else's problem",
    "Self-hosted and elsewhere",
    "The music never left the server",
    "Whipping a distant terminal"
  ]
  // Offline is the hero's own concern now (urgent status line); the phrase
  // only ever carries the idle poetry.
  readonly property string heroPhraseText: !cliamp
    ? "add servers in shell.json"
    : activePhrases[phraseIndex % activePhrases.length]

  visible: !hideWhenOffline || (cliamp && cliamp.running)
  implicitWidth: barRow.implicitWidth
  implicitHeight: button.implicitHeight

  function cursorCount() {
    if (serverOpen) return services.length
    if (queueOpen) return cliamp ? cliamp.queue.length : 0
    if (lightsOpen) return lightsSection.rowCount
    return cliamp ? cliamp.results.length : 0
  }

  function moveCursor(delta) {
    var count = cursorCount()
    if (count === 0) return
    cursorIndex = (cursorIndex + delta + count) % count
    revealCursor()
  }

  // Page moves clamp instead of wrapping, the way a page scroll should.
  function movePage(delta) {
    var count = cursorCount()
    if (count === 0) return
    cursorIndex = Math.max(0, Math.min(count - 1, cursorIndex + delta))
    revealCursor()
  }

  // Two scroll areas stack here: the panel itself, and the results list inside it.
  // The list keeps the cursor row inside its own viewport; this keeps that viewport
  // inside the panel's, so a `j` press is always visible without touching a mouse.
  NumberAnimation {
    id: scrollAnim
    target: panelFlick
    property: "contentY"
    duration: 140
    easing.type: Easing.OutCubic
  }

  function revealItem(item) {
    if (!item || !panelFlick) return
    var top = item.mapToItem(panelFlick.contentItem, 0, 0).y
    var bottom = top + item.height
    var target = panelFlick.contentY
    var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
    if (bottom > target + panelFlick.height) target = Math.min(maxY, bottom - panelFlick.height)
    // Top wins when the section cannot fit whole, so the header stays readable.
    if (top < target) target = Math.max(0, top)
    if (Math.abs(target - panelFlick.contentY) < 1) return
    scrollAnim.stop()
    scrollAnim.from = panelFlick.contentY
    scrollAnim.to = target
    scrollAnim.start()
  }

  // Results and the queue arrive asynchronously and grow the section after it was
  // revealed, so the reveal re-runs when they land.
  Connections {
    target: root.cliamp
    ignoreUnknownSignals: true
    function onResultsChanged() { if (root.libraryOpen) root.revealCursor() }
    function onQueueChanged() { if (root.queueOpen) root.revealCursor() }
  }

  // The lists also grow over a few frames as delegates instantiate, with no data
  // signal at all — the section height is the one thing that always moves.
  Connections {
    target: library
    function onImplicitHeightChanged() { if (root.libraryOpen) root.revealCursor() }
  }
  Connections {
    target: queueSection
    function onImplicitHeightChanged() { if (root.queueOpen) root.revealCursor() }
  }
  Connections {
    target: helpSection
    function onImplicitHeightChanged() { if (root.helpOpen) root.revealCursor() }
  }
  Connections {
    target: lyricsSection
    function onImplicitHeightChanged() { if (root.lyricsOpen) root.revealCursor() }
  }
  Connections {
    target: lightsSection
    function onImplicitHeightChanged() { if (root.lightsOpen) root.revealCursor() }
  }

  // The help section has no cursor rows; j/k and the page keys scroll the panel
  // itself instead, so the keymap is browsable the same way everything else is.
  function scrollPanel(dy) {
    if (!panelFlick) return
    var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
    var target = Math.max(0, Math.min(maxY, panelFlick.contentY + dy))
    if (Math.abs(target - panelFlick.contentY) < 1) return
    scrollAnim.stop()
    scrollAnim.from = panelFlick.contentY
    scrollAnim.to = target
    scrollAnim.start()
  }

  function revealCursor() {
    // callLater so expansion/relayout settles before anything is measured. The
    // WHOLE section is revealed, not just its inner list: top-priority in
    // revealItem keeps the header and the search field on screen, and the inner
    // list scrolls the cursor row within its own capped viewport.
    Qt.callLater(function () {
      if (root.serverOpen) revealItem(serverList)
      else if (root.queueOpen) revealItem(queueSection)
      else if (root.libraryOpen) revealItem(library)
      else if (root.helpOpen) revealItem(helpSection)
      else if (root.lyricsOpen) revealItem(lyricsSection)
      else if (root.lightsOpen) revealItem(lightsSection)
    })
  }

  // The native search overlay's `a` and `q` on the highlighted row.
  function queueCursor() {
    if (!libraryOpen || !cliamp) return
    if (cursorIndex < 0 || cursorIndex >= cliamp.results.length) return
    cliamp.queueResult(cliamp.results[cursorIndex])
  }

  function activateCursor() {
    if (serverOpen) { setActive(cursorIndex); return }
    if (queueOpen) {
      if (cliamp && cursorIndex >= 0 && cursorIndex < cliamp.queue.length) cliamp.queueJump(cursorIndex)
      return
    }
    if (lightsOpen) { lightsSection.activate(cursorIndex); return }
    if (!libraryOpen || !cliamp) return
    if (cursorIndex < 0 || cursorIndex >= cliamp.results.length) return
    var item = cliamp.results[cursorIndex]
    cliamp.playResult(item)
    // Entering or leaving a drill-down swaps the whole list, so the cursor goes
    // home and the list is brought back on screen.
    if (item && (item.kind === "artist" || item.kind === "album" || item.kind === "back")) {
      cursorIndex = 0
      revealCursor()
    }
  }

  Timer {
    id: phraseTimer
    interval: root.phraseIntervalMs
    repeat: true
    running: root.opened && !(cliamp && cliamp.hasTrack)
    onTriggered: root.phraseIndex = (root.phraseIndex + 1) % root.activePhrases.length
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function playpause(): string { if (root.cliamp) root.cliamp.playPause(); return "ok" }
    function library(): string {
      root.openSection(root.libraryOpen ? "" : "library")
      return root.libraryOpen ? "open" : "closed"
    }
    function server(name: string): string {
      for (var i = 0; i < root.services.length; i++) {
        if (root.services[i].label === name) { root.setActive(i); return "ok: " + name }
      }
      return "unknown server: " + name
    }
    // Scriptable equivalents of the panel keys, so states can be driven without
    // a keyboard: omarchy-shell remote-cliamp search "galija", queuepanel, ...
    function queuepanel(): string {
      root.openSection(root.queueOpen ? "" : "queue")
      return root.queueOpen ? "open" : "closed"
    }
    function serverpanel(): string {
      root.openSection(root.serverOpen ? "" : "server")
      return root.serverOpen ? "open" : "closed"
    }
    function help(): string {
      root.openSection(root.helpOpen ? "" : "help")
      return root.helpOpen ? "open" : "closed"
    }
    function lyrics(): string {
      root.openSection(root.lyricsOpen ? "" : "lyrics")
      return root.lyricsOpen ? "open" : "closed"
    }
    function lights(): string {
      root.openSection(root.lightsOpen ? "" : "lights")
      return root.lightsOpen ? "open" : "closed"
    }
    function scene(name: string): string {
      ledfxClient.activateScene(name)
      return "ok: " + name
    }
    function search(query: string): string {
      root.openSection("library")
      if (root.cliamp) root.cliamp.search(query)
      return "ok"
    }
    function cursor(index: int): string {
      root.cursorIndex = Math.max(0, index)
      root.revealCursor()
      return String(root.cursorIndex)
    }
    function activate(): string {
      root.activateCursor()
      return "ok"
    }
  }

  Row {
    id: barRow
    anchors.fill: parent

    BarIconButton {
      id: button
      bar: root.bar
      iconComponent: Component {
        Item {
          CliampIcon {
            anchors.centerIn: parent
            iconSize: Style.space(12)
            color: root.barIconColor
            playing: !!(root.cliamp && root.cliamp.isPlaying)
            offline: !(root.cliamp && root.cliamp.running)
          }
        }
      }
      // The label moved into the tooltip; the icon alone marks the widget and the
      // active server is one hover (or one panel open) away.
      tooltipText: root.cliamp ? root.cliamp.label + " · " + root.cliamp.sshTarget : ""
      onPressed: function (buttonCode) {
        if (buttonCode === Qt.RightButton) { if (root.cliamp) root.cliamp.playPause() }
        else root.toggle()
      }
      onWheelMoved: function (delta) { root.cycleActive(delta > 0 ? -1 : 1) }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    // Keys the catcher does not answer bubble up here: the native overlay's
    // Ctrl+N/Ctrl+P cursor moves, Ctrl+U/Ctrl+D page scroll, and Backspace to
    // walk back out of an artist drill-down. The search field consumes its own
    // Ctrl combos first, so nothing here fights the editor.
    Item {
      id: extraKeys
      anchors.fill: parent

      Keys.onPressed: function (event) {
        var listOpen = keyCatcher.listOpen
        if (event.modifiers & Qt.ControlModifier) {
          if (event.key === Qt.Key_K) { root.openSection(root.helpOpen ? "" : "help"); event.accepted = true }
          else if (root.helpOpen && event.key === Qt.Key_D) { root.scrollPanel(panelFlick.height * 0.8); event.accepted = true }
          else if (root.helpOpen && event.key === Qt.Key_U) { root.scrollPanel(-panelFlick.height * 0.8); event.accepted = true }
          else if (event.key === Qt.Key_N) { root.moveCursor(1); event.accepted = true }
          else if (event.key === Qt.Key_P) { root.moveCursor(-1); event.accepted = true }
          else if (listOpen && event.key === Qt.Key_D) { root.movePage(8); event.accepted = true }
          else if (listOpen && event.key === Qt.Key_U && !library.searchFocused) { root.movePage(-8); event.accepted = true }
          return
        }
        if (root.helpOpen && event.key === Qt.Key_PageDown) { root.scrollPanel(panelFlick.height * 0.8); event.accepted = true; return }
        if (root.helpOpen && event.key === Qt.Key_PageUp) { root.scrollPanel(-panelFlick.height * 0.8); event.accepted = true; return }
        if (listOpen && event.key === Qt.Key_PageDown) { root.movePage(8); event.accepted = true; return }
        if (listOpen && event.key === Qt.Key_PageUp) { root.movePage(-8); event.accepted = true; return }
        if (event.key === Qt.Key_Backspace && !library.searchFocused && root.libraryOpen
            && root.cliamp && root.cliamp.breadcrumb.length > 0) {
          root.cliamp.goBack()
          root.cursorIndex = 0
          root.revealCursor()
          event.accepted = true
        }
      }

      PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: library.searchFocused

      // Every section whose rows the panel cursor walks. Add new sections HERE
      // or j/k/enter silently fall through to seek/play-pause.
      readonly property bool listOpen: root.serverOpen || root.libraryOpen || root.queueOpen || root.lightsOpen

      onMoveRequested: function (dx, dy) {
        if (root.helpOpen && dy !== 0) { root.scrollPanel(dy * Style.space(36)); return }
        if (root.lyricsOpen && dy !== 0) { lyricsSection.scrollBy(dy); return }
        if (keyCatcher.listOpen && dy !== 0) { root.moveCursor(dy); return }
        if (dx !== 0 && root.cliamp) root.cliamp.seekBy(dx > 0 ? root.seekStepSec : -root.seekStepSec)
      }
      onActivateRequested: {
        if (keyCatcher.listOpen) root.activateCursor()
        else if (root.cliamp) root.cliamp.playPause()
      }
      // Esc walks out one layer at a time: an expanded section collapses
      // first; only with everything shut does the panel itself close.
      onCloseRequested: {
        if (root.serverOpen || root.libraryOpen || root.queueOpen || root.helpOpen || root.lyricsOpen || root.lightsOpen) {
          root.openSection("")
          return
        }
        root.close()
      }
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (t) {
        var key = String(t).toLowerCase()
        var anyList = keyCatcher.listOpen
        // Ctrl combos arrive here as control characters on some platforms, so
        // they are answered in both places; whichever fires first wins.
        if (t === "\u000e") { root.moveCursor(1); return }        // Ctrl+N
        if (t === "\u0010") { root.moveCursor(-1); return }       // Ctrl+P
        if (t === "\u0004") {                                         // Ctrl+D
          if (root.helpOpen) root.scrollPanel(panelFlick.height * 0.8)
          else if (anyList) root.movePage(8)
          return
        }
        if (t === "\u0015") {                                         // Ctrl+U
          if (root.helpOpen) root.scrollPanel(-panelFlick.height * 0.8)
          else if (anyList) root.movePage(-8)
          return
        }
        // Native cliamp's `A`, the queue manager, before the lowercase keys.
        if (t === "A") { root.openSection(root.queueOpen ? "" : "queue"); return }
        // Native cliamp's `?`: the keymap.
        if (t === "?") { root.openSection(root.helpOpen ? "" : "help"); return }
        // The house lights, when a LedFx URL is configured.
        if (t === "L" && root.ledfxUrl.length > 0) { root.openSection(root.lightsOpen ? "" : "lights"); return }
        if (key === "o") root.openSection(root.serverOpen ? "" : "server")
        // `/` opens the library or, when it is already open, hands the keyboard
        // back to the search field — the native flow, where `/` always means
        // "type a query" and Esc is what climbs back out.
        else if (key === "/") {
          if (!root.libraryOpen) root.openSection("library")
          library.focusSearch()
          root.revealCursor()
        }
        else if (!root.cliamp) return
        else if (root.libraryOpen && (key === "a" || key === "q")) root.queueCursor()
        else if (key === "f") root.cliamp.openPlayer()
        // Native cliamp's `y`: the lyric sheet.
        else if (key === "y") root.openSection(root.lyricsOpen ? "" : "lyrics")
        else if (!root.cliamp.running) return
        else if (key === "n") root.cliamp.next()
        else if (key === "b") root.cliamp.previous()
        else if (key === "s") root.cliamp.toggleShuffle()
        // While the lyric sheet is open, `r` retries the lookup — the native
        // meaning of `r` in that context. Everywhere else it cycles repeat.
        else if (key === "r") root.lyricsOpen ? root.cliamp.retryLyrics() : root.cliamp.cycleRepeat()
        // The native track screen's `p`: play the open album from the top.
        else if (key === "p" && root.libraryOpen && root.cliamp.browseAlbum)
          root.cliamp.playResult({ kind: "playall", id: String(root.cliamp.browseAlbum.id), name: "" })
        // Native cliamp's volume keys: +/- walk the gain 1 dB at a time.
        // `=` is the unshifted + on most layouts, so it counts too. On the
        // local server they walk the PipeWire stream volume in 5% steps,
        // the same control the slider drives.
        else if (t === "+" || t === "=") {
          if (root.cliamp.hasStreamVolume) root.cliamp.setStreamVolume(root.cliamp.streamVolume + 0.05)
          else root.cliamp.setVolumeDb(root.cliamp.shownVolumeDb + 1)
        }
        else if (t === "-") {
          if (root.cliamp.hasStreamVolume) root.cliamp.setStreamVolume(root.cliamp.streamVolume - 0.05)
          else root.cliamp.setVolumeDb(root.cliamp.shownVolumeDb - 1)
        }
        // The native playlist manager's `[`/`]`: move the highlighted queue row.
        else if (root.queueOpen && (t === "[" || t === "]")) {
          var to = root.cursorIndex + (t === "]" ? 1 : -1)
          if (to >= 0 && to < root.cliamp.queue.length) {
            root.cliamp.queueMove(root.cursorIndex, to)
            root.cursorIndex = to
            root.revealCursor()
          }
        }
      }

      // The catcher's `x`, the native remove key, aimed at the queue row.
      onDeleteRequested: {
        if (!root.queueOpen || !root.cliamp) return
        if (root.cursorIndex < 0 || root.cursorIndex >= root.cliamp.queue.length) return
        root.cliamp.queueRemove(root.cursorIndex)
        if (root.cursorIndex >= root.cliamp.queue.length - 1)
          root.cursorIndex = Math.max(0, root.cliamp.queue.length - 2)
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
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded; interactive: false }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(16)

          NowPlaying {
            width: parent.width
            service: root.cliamp
            phrase: root.heroPhraseText
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Transport {
            width: parent.width
            bar: root.bar
            service: root.cliamp
            foreground: root.foreground
            fontFamily: root.fontFamily
            onQueueRequested: root.openSection(root.queueOpen ? "" : "queue")
          }

          LyricsView {
            id: lyricsSection
            width: parent.width
            // Summoned by `y`, invisible otherwise — the collapsed header row
            // was one line of noise the panel does not need.
            visible: root.lyricsOpen
            service: root.cliamp
            foreground: root.foreground
            fontFamily: root.fontFamily
            expanded: root.lyricsOpen
            onToggleRequested: root.openSection(root.lyricsOpen ? "" : "lyrics")
          }

          QueueList {
            id: queueSection
            width: parent.width
            service: root.cliamp
            foreground: root.foreground
            fontFamily: root.fontFamily
            expanded: root.queueOpen
            cursorIndex: root.queueOpen ? root.cursorIndex : -1
            onToggleRequested: root.openSection(root.queueOpen ? "" : "queue")
          }

          ServerList {
            id: serverList
            width: parent.width
            services: root.services
            activeIndex: root.activeIndex
            foreground: root.foreground
            fontFamily: root.fontFamily
            expanded: root.serverOpen
            cursorIndex: root.serverOpen ? root.cursorIndex : -1
            onToggleRequested: root.openSection(root.serverOpen ? "" : "server")
            onSelectRequested: function (index) { root.setActive(index) }
          }

          Library {
            id: library
            width: parent.width
            service: root.cliamp
            foreground: root.foreground
            fontFamily: root.fontFamily
            expanded: root.libraryOpen
            cursorIndex: root.libraryOpen ? root.cursorIndex : -1
            onMoveRequested: function (delta) { root.moveCursor(delta) }
            onActivateRequested: root.activateCursor()
            onToggleRequested: root.openSection(root.libraryOpen ? "" : "library")
          }

          LightsView {
            id: lightsSection
            width: parent.width
            visible: root.lightsOpen
            ledfx: ledfxClient
            foreground: root.foreground
            fontFamily: root.fontFamily
            expanded: root.lightsOpen
            cursorIndex: root.lightsOpen ? root.cursorIndex : -1
            onToggleRequested: root.openSection(root.lightsOpen ? "" : "lights")
          }

          Help {
            id: helpSection
            width: parent.width
            // Same treatment: `?` summons it, nothing shows otherwise.
            visible: root.helpOpen
            foreground: root.foreground
            fontFamily: root.fontFamily
            expanded: root.helpOpen
            onToggleRequested: root.openSection(root.helpOpen ? "" : "help")
          }
        }
      }
      }
    }
  }

  onOpenedChanged: {
    if (!opened) { serverOpen = false; libraryOpen = false; queueOpen = false; helpOpen = false; return }
    if (panelFlick) panelFlick.contentY = 0
    cursorIndex = 0
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }
}
