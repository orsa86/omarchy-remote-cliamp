import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// A cliamp on another machine. The remote instance speaks the same newline delimited
// JSON on its unix socket as a local one, so the whole difference is one ssh -L that
// brings that socket here. Audio never crosses the wire: this sends verbs, the server
// pulls its own streams and plays them on its own output. Everything the local plugin
// derives from PipeWire — the verdict, the meter, routing, rate following — describes
// an audio graph that lives on the far machine, so none of it exists here.
Item {
  id: root

  property var settings: ({})
  property bool panelOpen: false

  property var status: Model.defaultStatus()
  property string lastError: ""

  readonly property string sshTarget: String(setting("sshTarget", ""))
  // "local" is a server like any other, minus the wire: the socket is connected
  // directly and every helper subprocess runs without ssh. A cliamp started any
  // way at all — TUI in a terminal, daemon — owns the one per-user socket, so
  // whatever is running is what this controls.
  readonly property bool isLocal: sshTarget === "local"
  readonly property string label: String(setting("label", "") || sshTarget || "unset")
  readonly property string remoteSocket: String(setting("remoteSocket", ".config/cliamp/cliamp.sock"))
  readonly property string remoteCliamp: String(setting("remoteCliamp", "~/.local/bin/cliamp"))
  readonly property int statusIntervalMs: intSetting("statusIntervalSec", 2, 1, 10) * 1000

  readonly property string slug: {
    var raw = String(setting("label", "") || sshTarget)
    var cleaned = raw.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "")
    return cleaned.length > 0 ? cleaned : "default"
  }

  // The forwarded end of the remote socket, per instance so two servers never
  // fight over one path — or, locally, cliamp's own socket as it is.
  readonly property string socketPath: isLocal
    ? (Quickshell.env("HOME") || "") + "/.config/cliamp/cliamp.sock"
    : (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/remote-cliamp." + slug + ".sock"

  // Every ssh this instance makes shares one multiplexed connection. The tunnel
  // becomes the master, so a verb or a visstream is a channel open on a live
  // connection — tens of milliseconds — instead of a full handshake per call.
  readonly property string controlPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp")
    + "/remote-cliamp." + slug + ".ctl"

  // One remote shell line per call. BatchMode so a missing key fails instead of
  // hanging the shell on a password prompt it can never answer. Locally the same
  // line just runs in a shell here.
  function sshCommand(remoteLine) {
    if (isLocal) return ["bash", "-c", remoteLine]
    return ["ssh", "-T",
      "-o", "BatchMode=yes",
      "-o", "ConnectTimeout=5",
      "-o", "ControlMaster=auto",
      "-o", "ControlPath=" + root.controlPath,
      "-o", "ControlPersist=60",
      root.sshTarget, remoteLine]
  }

  // ---- the tunnel ----

  // sshd resolves a forwarded unix socket path as absolute only, so a relative
  // setting has to be anchored to the remote home first. Probed once per target.
  property string remoteHome: ""

  readonly property string resolvedRemoteSocket: remoteSocket.indexOf("/") === 0
    ? remoteSocket
    : (remoteHome.length > 0 ? remoteHome + "/" + remoteSocket : "")

  Process {
    id: homeProbe
    command: root.sshCommand('printf %s "$HOME"')
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var home = String(text || "").trim()
        if (home.indexOf("/") === 0) root.remoteHome = home
      }
    }
    // Success feeds startTunnel a resolved path; failure lands back in the retry.
    onExited: tunnelRetry.restart()
  }

  // Locally there is no wire to be down; the socket file is the whole story.
  readonly property bool tunnelUp: isLocal || tunnelProcess.running

  Process {
    id: tunnelProcess
    command: ["ssh", "-N", "-T",
      "-o", "BatchMode=yes",
      "-o", "ExitOnForwardFailure=yes",
      "-o", "ConnectTimeout=5",
      "-o", "ServerAliveInterval=15",
      "-o", "ServerAliveCountMax=3",
      // A crashed shell leaves the local socket file behind, and ssh refuses to
      // bind over it without this.
      "-o", "StreamLocalBindUnlink=yes",
      "-o", "ControlMaster=auto",
      "-o", "ControlPath=" + root.controlPath,
      "-o", "ControlPersist=60",
      "-L", root.socketPath + ":" + root.resolvedRemoteSocket,
      root.sshTarget]
    running: false
    onExited: tunnelRetry.restart()
  }

  // Unreachable hosts land here every ConnectTimeout, so the retry is slow enough
  // not to churn but fast enough that a rebooted server comes back on its own.
  Timer {
    id: tunnelRetry
    interval: 8000
    repeat: false
    onTriggered: root.startTunnel()
  }

  function startTunnel() {
    if (isLocal || sshTarget.length === 0 || tunnelProcess.running) return
    if (resolvedRemoteSocket.length === 0) {
      if (!homeProbe.running) homeProbe.running = true
      return
    }
    tunnelProcess.running = true
  }

  // Settings land after the component completes, so the target is empty at
  // onCompleted and the tunnel has to chase the value instead.
  onSshTargetChanged: {
    tunnelProcess.running = false
    remoteHome = ""
    tunnelKick.restart()
  }

  Timer {
    id: tunnelKick
    interval: 300
    repeat: false
    onTriggered: root.startTunnel()
  }

  Component.onCompleted: startTunnel()
  Component.onDestruction: tunnelProcess.running = false

  // ---- state read off the socket ----

  readonly property bool running: status.ok === true
  readonly property bool hasTrack: running && (title.length > 0 || artist.length > 0)
  readonly property bool isPlaying: status.ok === true && status.state === "playing"
  readonly property string title: String(status.title || "")
  readonly property string artist: String(status.artist || "")
  readonly property string album: String(status.album || "")

  // cliamp publishes no artUrl anywhere, so the cover is derived from the Subsonic
  // stream URL in its status. That URL points at the Navidrome server, which this
  // machine reaches directly — the tunnel is not involved in artwork.
  property string artUrl: ""
  property int artSizePx: 300

  readonly property string resolvedArtUrl: running
    ? safeArtUrl(Model.coverArtUrlFromStreamPath(status.path, artSizePx))
    : ""

  onResolvedArtUrlChanged: if (running) artUrl = resolvedArtUrl

  function safeArtUrl(raw) {
    var url = String(raw || "")
    if (url.indexOf("https://") === 0) return url
    return ""
  }

  readonly property real lengthSec: status.durationSec > 0 ? status.durationSec : 0
  readonly property bool hasProgress: running && lengthSec > 0
  readonly property bool canSeek: hasProgress && !isStream

  // Fired when a seek lands on a track cliamp cannot reposition (an HTTP
  // stream: seeking one stops playback outright, measured on 1.63.2), so the
  // UI can say why nothing moved instead of staying silent.
  signal seekRefused()

  readonly property bool shuffle: status.shuffle === true
  readonly property string repeat: String(status.repeat || "Off")
  readonly property int total: Number(status.total || 0)
  readonly property bool isStream: status.isStream === true

  // No PipeWire stream node exists for a remote player; what CAN move is cliamp's
  // own gain, which the socket carries as dB in [-30, +6]. Held optimistically so
  // the slider tracks the drag instead of the poll.
  readonly property bool hasStreamVolume: false
  readonly property real volumeDb: Number(status.volumeDb || 0)
  property real pendingVolumeDb: -999
  readonly property real shownVolumeDb: pendingVolumeDb > -900 ? pendingVolumeDb : volumeDb

  function setVolumeDb(value) {
    var db = Math.max(-30, Math.min(6, Math.round(Number(value) || 0)))
    pendingVolumeDb = db
    volumeHold.restart()
    if (send('{"cmd":"volume","value":' + db + '}')) settleTimer.restart()
  }

  Timer {
    id: volumeHold
    interval: 1500
    repeat: false
    onTriggered: root.pendingVolumeDb = -999
  }

  property real positionSec: 0
  property bool _askedAtEnd: false

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function boolSetting(name, fallback) {
    return Model.asBool(setting(name, fallback), fallback)
  }

  function intSetting(name, fallback, min, max) {
    var value = parseInt(setting(name, fallback), 10)
    if (!isFinite(value)) value = fallback
    return Math.max(min, Math.min(max, value))
  }

  // ---- transport, over the socket ----

  property int pendingPlaying: -1
  readonly property bool showPlaying: pendingPlaying === -1 ? isPlaying : pendingPlaying === 1

  function playPause() {
    pendingPlaying = isPlaying ? 0 : 1
    playHold.restart()
    if (send('{"cmd":"toggle"}')) settleTimer.restart()
  }

  Timer {
    id: playHold
    interval: 2500
    repeat: false
    onTriggered: root.pendingPlaying = -1
  }

  function next() { if (send('{"cmd":"next"}')) settleTimer.restart() }
  function previous() { if (send('{"cmd":"prev"}')) settleTimer.restart() }

  // The socket seek takes a delta, not a position, measured on 1.63.2.
  function seekTo(targetSec) {
    if (!canSeek) {
      if (hasProgress) seekRefused()
      return
    }
    var target = Math.max(0, Math.min(lengthSec, Number(targetSec) || 0))
    var delta = Math.round(target - positionSec)
    positionSec = target
    if (send('{"cmd":"seek","value":' + delta + '}')) settleTimer.restart()
  }

  function seekBy(deltaSec) { seekTo(positionSec + Number(deltaSec || 0)) }

  function refreshStatus() {
    if (!ipcConnected) return
    ipcLoader.item.write('{"cmd":"status"}\n')
    ipcLoader.item.flush()
  }

  function send(payload) {
    if (!ipcConnected) return false
    ipcLoader.item.write(payload + "\n")
    ipcLoader.item.flush()
    return true
  }

  // ---- lyrics, same socket ----

  property var lyrics: []
  property string lyricsTrackPath: ""
  // "none" (nothing playing / not asked) · "loading" · "ok" · "notfound" —
  // cliamp answers "no lyrics found" explicitly, so absence is a real state.
  property string lyricsStatus: "none"

  readonly property bool hasLyrics: lyrics.length > 0
  // The sink whose latency would matter is in another room. The words on this screen
  // can never line up with air pressure there, so only the manual trim is applied.
  readonly property int outputLatencyMs: 0
  readonly property int lyricTrimMs: intSetting("lyricTrimMs", 0, -1000, 1000)

  readonly property int activeLyricIndex: Model.activeLyricIndex(lyrics, positionSec - (outputLatencyMs + lyricTrimMs) / 1000)
  readonly property string activeLyric: activeLyricIndex >= 0
    ? String(lyrics[activeLyricIndex].text || "")
    : ""

  property string lyricsPendingPath: ""

  function refreshLyrics() {
    var path = String(status.path || "")
    if (path.length === 0) { lyrics = []; lyricsTrackPath = ""; lyricsStatus = "none"; return }
    if (path === lyricsTrackPath) return
    lyrics = []
    if (lyricsPendingPath.length > 0) return
    if (send('{"cmd":"lyrics"}')) {
      lyricsPendingPath = path
      lyricsTrackPath = path
      lyricsStatus = "loading"
      lyricsTimeout.restart()
    }
  }

  // The native `r` while lyrics are open: forget this track's answer and ask
  // cliamp again — it re-runs its own chain (tags → LRCLIB → NetEase).
  function retryLyrics() {
    lyricsPendingPath = ""
    lyricsTrackPath = ""
    refreshLyrics()
  }

  Timer {
    id: lyricsTimeout
    interval: 5000
    repeat: false
    onTriggered: root.lyricsPendingPath = ""
  }

  function dropLyricsRequest() {
    if (lyricsPendingPath.length === 0) return
    lyricsPendingPath = ""
    lyricsTrackPath = ""
  }

  function acceptLyrics(raw) {
    var wanted = lyricsPendingPath
    lyricsPendingPath = ""
    lyricsTimeout.stop()
    if (wanted === String(status.path || "")) {
      lyrics = Model.parseLyrics(raw)
      if (lyrics.length > 0) { lyricsStatus = "ok"; return }
      tryLyricsFallback()
      return
    }
    lyricsTrackPath = ""
    refreshLyrics()
  }

  // ---- local .lrc fallback ----
  // When the remote cliamp's own chain (tags → LRCLIB → NetEase) comes up empty,
  // look for "<artist> - <title>.lrc" in ~/.local/share/remote-cliamp/lyrics on
  // THIS machine. Covers tracks whose LRCLIB record exists but their search
  // cannot find (e.g. the "Reboot, Dongle, Config file" scoring bug).
  property string lyricsFallbackFor: ""

  function tryLyricsFallback() {
    if (artist.length === 0 && title.length === 0) { lyricsStatus = "notfound"; return }
    var name = (artist + " - " + title).replace(/[\/\\:*?"<>|]/g, "_")
    lyricsFallbackFor = String(status.path || "")
    lrcFileProcess.command = ["cat",
      Quickshell.env("HOME") + "/.local/share/remote-cliamp/lyrics/" + name + ".lrc"]
    lrcFileProcess.running = true
  }

  Process {
    id: lrcFileProcess
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.lyricsFallbackFor !== String(root.status.path || "")) return
        var lines = Model.parseLrcText(text)
        if (lines.length > 0) { root.lyrics = lines; root.lyricsStatus = "ok" }
        else root.lyricsStatus = "notfound"
      }
    }
  }

  function syncPosition() {
    if (status.ok === true) positionSec = Number(status.positionSec || 0)
    if (panelOpen) refreshStatus()
  }

  // ---- the queue, over the same socket ----

  // The panel writes queueOpen so a shut queue costs nothing: refreshes happen
  // only while someone is looking, plus once per track change.
  property bool queueOpen: false
  property var queue: []
  property int queueIndex: 0

  function refreshQueue() { send('{"cmd":"queue.list"}') }

  // Every mutation answers with the fresh track list, so the panel updates from
  // the reply itself — no follow-up read. Indices are 0-based, verified in
  // ipc_extended.go and live against 1.63.2.
  function queueJump(i) {
    if (send('{"cmd":"queue.play","index":' + Number(i) + '}')) settleTimer.restart()
  }

  function queueRemove(i) {
    if (send('{"cmd":"queue.remove","index":' + Number(i) + '}')) settleTimer.restart()
  }

  function queueMove(i, to) {
    if (to < 0 || to >= queue.length) return
    if (send('{"cmd":"queue.move","index":' + Number(i) + ',"to":' + Number(to) + '}')) settleTimer.restart()
  }

  onQueueOpenChanged: if (queueOpen) refreshQueue()

  // ---- the server's own radio stations, via the radio provider ----

  // The stations configured on the server: radios.toml entries (l:), the built-in
  // "cliamp radio" list (l:0), and favorites (f:). Listed over the socket.
  property var stations: []
  property bool _stationsPending: false
  // Set while a provider.tracks reply is owed for a station queue — its reply
  // carries a tracks field exactly like queue.list, so the router needs to know
  // which question is outstanding.
  property string _stationQueuePending: ""

  function refreshStations() {
    if (send('{"cmd":"provider.playlists","provider":"radio"}')) {
      _stationsPending = true
      stationsTimeout.restart()
    }
  }

  // ---- generic provider browse ("p:"), the whole cliamp source list ----

  // Whatever the server's cliamp has configured — Spotify, Jellyfin, Local, … —
  // browsed through the same provider.* verbs the radio view uses.
  property var providers: []
  property bool _providersPending: false
  property var browseProvider: null
  property var providerPlaylists: []
  property bool _provListsPending: false

  function refreshProviders() {
    if (send('{"cmd":"provider.list"}')) {
      _providersPending = true
      stationsTimeout.restart()
    }
  }

  function enterProvider(item) {
    browseProvider = { id: String(item.id), name: String(item.name || "") }
    providerPlaylists = []
    if (send('{"cmd":"provider.playlists","provider":' + JSON.stringify(String(item.id)) + '}')) {
      _provListsPending = true
      stationsTimeout.restart()
    }
    _recomputeResults()
  }

  function playProviderPlaylist(item) {
    if (!browseProvider) return
    // Same shape as a station: provider.load replaces the queue, then play.
    if (send('{"cmd":"provider.load","provider":' + JSON.stringify(String(browseProvider.id))
        + ',"playlist":' + JSON.stringify(String(item.id)) + '}')) {
      send('{"cmd":"play"}')
      settleTimer.restart()
    }
  }

  function queueProviderPlaylist(item) {
    if (!browseProvider || _stationQueuePending.length > 0) return
    if (send('{"cmd":"provider.tracks","provider":' + JSON.stringify(String(browseProvider.id))
        + ',"playlist":' + JSON.stringify(String(item.id)) + '}')) {
      _stationQueuePending = String(item.id)
      stationsTimeout.restart()
    }
  }

  function playStation(item) {
    // provider.load replaces the queue with the station but lands paused,
    // measured on 1.63.2; requests are served in order, so play follows it.
    if (send('{"cmd":"provider.load","provider":"radio","playlist":' + JSON.stringify(String(item.id)) + '}')) {
      send('{"cmd":"play"}')
      settleTimer.restart()
    }
  }

  function queueStation(item) {
    if (_stationQueuePending.length > 0) return
    if (send('{"cmd":"provider.tracks","provider":"radio","playlist":' + JSON.stringify(String(item.id)) + '}')) {
      _stationQueuePending = String(item.id)
      stationsTimeout.restart()
    }
  }

  Timer {
    id: stationsTimeout
    interval: 5000
    repeat: false
    onTriggered: {
      root._stationsPending = false
      root._stationQueuePending = ""
      root._providersPending = false
      root._provListsPending = false
    }
  }

  // One re-read per track change while the queue is on screen, keyed on the
  // fields a change actually moves.
  property string _queueSeen: ""

  function _maybeRefreshQueue() {
    // The collapsed summary line shows the playing row, so the list stays fresh
    // whenever the panel is open, not only while the queue section is.
    if (!panelOpen) return
    // A provider.tracks reply is outstanding and looks exactly like a queue
    // reply, so nothing else that answers with tracks may be sent until it lands.
    if (_stationQueuePending.length > 0) return
    var seen = String(status.index) + "|" + String(status.total) + "|" + String(status.path)
    if (seen === _queueSeen) return
    _queueSeen = seen
    refreshQueue()
  }

  // ---- the socket itself ----

  // Same hazard as the local plugin, plus one of this setup's own: the ssh listener
  // accepts a connection even when the far socket is gone, and only then fails the
  // channel. So "connected" can flap while the remote daemon is down, and a stale
  // status would otherwise survive that flapping forever. freshTimer is the answer:
  // only an actual status reply keeps the panel claiming the server is up.
  readonly property bool ipcConnected: !!(ipcLoader.item && ipcLoader.item.connected)

  Loader {
    id: ipcLoader
    active: true
    sourceComponent: Socket {
      path: root.socketPath
      connected: true

      onConnectionStateChanged: {
        if (connected) { root.refreshStatus(); return }
        root.dropLyricsRequest()
      }

      parser: SplitParser {
        splitMarker: "\n"
        onRead: function (line) {
          var raw = String(line || "")
          var kind = Model.messageKind(raw)
          if (kind === "providers") {
            root._providersPending = false
            root.providers = Model.parseProviders(raw)
            root._recomputeResults()
            return
          }
          if (kind === "stations") {
            // Same reply shape serves two askers: the radio view and a
            // provider drill-down. Whoever asked last owns it.
            if (root._provListsPending) {
              root._provListsPending = false
              var rows = Model.parseStations(raw)
              for (var pi = 0; pi < rows.length; pi++) rows[pi].kind = "provplaylist"
              root.providerPlaylists = rows
            } else {
              root._stationsPending = false
              root.stations = Model.parseStations(raw)
            }
            root._recomputeResults()
            return
          }
          if (kind === "queue") {
            // Same shape as a queue reply; ownership decides the meaning.
            if (root._stationQueuePending.length > 0) {
              root._stationQueuePending = ""
              // parseQueue drops the path field, so the raw reply is what queues.
              var data = null
              try { data = JSON.parse(raw) } catch (e) { data = null }
              var list = data && data.tracks && data.tracks.length !== undefined ? data.tracks : []
              for (var ti = 0; ti < list.length; ti++) {
                var p = list[ti] ? String(list[ti].path || "") : ""
                if (p.length > 0) root.send('{"cmd":"queue","path":' + JSON.stringify(p) + '}')
              }
              if (list.length > 0) settleTimer.restart()
              return
            }
            var q = Model.parseQueue(raw)
            if (q.ok) { root.queue = q.tracks; root.queueIndex = q.index }
            return
          }
          if (kind === "lyrics") { root.acceptLyrics(raw); return }
          if (kind === "ack") { root.lastError = Model.ackError(raw); return }
          if (kind !== "status") return
          var parsed = Model.parseStatus(raw)
          root.status = parsed
          root.lastError = parsed.ok ? "" : parsed.lastError
          if (parsed.ok) { root.positionSec = Number(parsed.positionSec || 0); freshTimer.restart() }
        }
      }
    }
  }

  Timer {
    id: reconnectTimer
    interval: 1500
    repeat: true
    running: !root.ipcConnected && root.tunnelUp
    onTriggered: {
      if (root.ipcConnected) return
      ipcLoader.active = false
      ipcLoader.active = true
    }
  }

  // The only thing that keeps status.ok true. A daemon restart on the server is
  // shorter than this, so the panel does not blank for it; a dead daemon or a dead
  // tunnel is longer, and the panel goes honestly offline.
  Timer {
    id: freshTimer
    interval: 25000
    repeat: false
    onTriggered: {
      root.status = Model.defaultStatus()
      root.artUrl = ""
    }
  }

  // The heartbeat doubles as the poll. Fast while something is watching, slow but
  // never off while the panel is shut, so the bar icon tracks the server on its own.
  Timer {
    id: statusTimer
    interval: root.panelOpen ? root.statusIntervalMs : 10000
    repeat: true
    running: root.ipcConnected
    triggeredOnStart: true
    onTriggered: root.refreshStatus()
  }

  Timer {
    id: positionTimer
    interval: 250
    repeat: true
    running: root.panelOpen && root.isPlaying
    onTriggered: {
      var next = root.positionSec + interval / 1000
      if (root.lengthSec > 0 && next >= root.lengthSec) {
        if (!root._askedAtEnd) { root._askedAtEnd = true; root.refreshStatus() }
        return
      }
      root._askedAtEnd = false
      root.positionSec = next
    }
  }

  // cliamp's 10 band spectrum, streamed over ssh instead of a local pipe. One frame
  // per tick of NDJSON is nothing on a LAN, and it only runs while the panel is open.
  property var bands: []

  Process {
    id: visProcess
    command: root.sshCommand(root.remoteCliamp + " visstream --fps 20")
    running: root.panelOpen && root.isPlaying && root.sshTarget.length > 0
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function (line) {
        var frame = Model.parseBands(line)
        if (frame.length > 0) root.bands = frame
      }
    }
    onRunningChanged: if (!running) root.bands = []
  }

  onPanelOpenChanged: {
    if (!panelOpen) return
    syncPosition()
    refreshQueue()
    readPlaylists()
    readLibrary()
  }

  onIsPlayingChanged: {
    if (pendingPlaying !== -1 && isPlaying === (pendingPlaying === 1)) pendingPlaying = -1
  }

  onStatusChanged: {
    if (panelOpen) refreshLyrics()
    _maybeRefreshQueue()
  }

  // ---- library, straight off the Subsonic server ----

  property var playlists: []
  property var results: []
  property string libraryQuery: ""

  property var _libraryRows: []

  readonly property string libraryHelper: String(Qt.resolvedUrl("remote-cliamp-library")).replace("file://", "")

  // Set while drilled into an artist's albums or an album's tracks, the panel's
  // version of the native provider browser. A new search always climbs back out.
  property var browseArtist: null
  property var browseAlbum: null
  readonly property string breadcrumb: {
    var parts = []
    if (browseArtist) parts.push(String(browseArtist.name || ""))
    if (browseAlbum) parts.push(String(browseAlbum.name || ""))
    return parts.join(" / ")
  }

  function _row(kind, id, name) {
    return { kind: kind, id: String(id), name: name, artist: "", album: "", albumId: "", songCount: 0, duration: 0 }
  }

  function _recomputeResults() {
    if (browseAlbum) {
      // The native track screen: Enter on a row plays from it; `p` there is "play
      // all from the top", which is this screen's own first row.
      results = [
        _row("back", "", "‹ " + (browseAlbum.artist ? browseAlbum.artist + " · " : "") + String(browseAlbum.name || "")),
        _row("playall", browseAlbum.id, "▶ Play album from the top")
      ].concat(_libraryRows)
      return
    }
    if (browseArtist) {
      // The native By Artist mode loads every track when an artist is selected;
      // here that is its own row, above the album drill-down.
      results = [
        _row("back", "", "‹ " + String(browseArtist.name || "")),
        _row("artistplay", browseArtist.id, "▶ Play all by " + String(browseArtist.name || ""))
      ].concat(_libraryRows)
      return
    }
    if (Model.isProviderMode(libraryQuery)) {
      if (browseProvider) {
        results = [_row("back", "", "‹ " + String(browseProvider.name || ""))].concat(providerPlaylists)
        return
      }
      results = Model.fuzzyFilter(providers, Model.providerQuery(libraryQuery))
      return
    }
    if (Model.isRadioMode(libraryQuery)) {
      // Bare "r:" lists the server's own stations plus the builtin list expanded
      // into individual streams; with a query, the Radio Browser results.
      results = Model.radioQuery(libraryQuery).length > 0
        ? _libraryRows
        : stations.concat(_libraryRows)
      return
    }
    var rows = _libraryRows
    // While the server round trip is in flight the rows on screen answer the OLD
    // query, so they are re-ranked fuzzily against the new one instead of sitting
    // there stale — the same feel as cliamp's incremental local filter.
    if (libraryQuery.length > 0 && _dispatchedQuery !== libraryQuery)
      rows = Model.fuzzyFilter(rows, libraryQuery)
    results = Model.matchPlaylists(playlists, libraryQuery).concat(rows)
  }

  property string _dispatchedQuery: ""

  function readLibrary() { _dispatchLibrary() }

  function search(query) {
    var next = String(query || "")
    // Leaving provider mode (or changing the prefix) climbs out of a drill-down.
    if (!Model.isProviderMode(next)) browseProvider = null
    libraryQuery = next
    browseArtist = null
    browseAlbum = null
    _recomputeResults()
    _dispatchLibrary()
  }

  function enterArtist(item) {
    browseArtist = { id: String(item.id), name: String(item.name || "") }
    browseAlbum = null
    _libraryRows = []
    _recomputeResults()
    _dispatchLibrary()
  }

  function enterAlbum(item) {
    browseAlbum = { id: String(item.id), name: String(item.name || ""), artist: String(item.artist || "") }
    _libraryRows = []
    _recomputeResults()
    _dispatchLibrary()
  }

  // One level at a time: tracks → the artist's albums (when there is one) → search.
  function goBack() {
    if (browseProvider) { browseProvider = null; _recomputeResults(); return }
    if (browseAlbum) browseAlbum = null
    else if (browseArtist) browseArtist = null
    else return
    _libraryRows = []
    _recomputeResults()
    _dispatchLibrary()
  }

  function exitArtist() {
    browseArtist = null
    browseAlbum = null
    _libraryRows = []
    _recomputeResults()
    _dispatchLibrary()
  }

  // The current stream URL rides along so the helper can skip its own ssh probe
  // for the Subsonic token when something is already playing.
  function _helperBase() {
    return [libraryHelper, sshTarget, remoteCliamp, controlPath, String(status.path || "")]
  }

  function _dispatchLibrary() {
    if (sshTarget.length === 0) return
    // Provider mode is answered entirely over the socket.
    if (Model.isProviderMode(libraryQuery) && !browseArtist && !browseAlbum) {
      _dispatchedQuery = libraryQuery
      if (!browseProvider) refreshProviders()
      _recomputeResults()
      return
    }
    var radio = Model.radioQuery(libraryQuery)
    // The bare radio prefix asks the socket for the configured stations and the
    // helper for the builtin m3u expanded into individual streams.
    if (Model.isRadioMode(libraryQuery) && radio.length === 0 && !browseArtist && !browseAlbum) {
      refreshStations()
      if (!albumProcess.running) {
        _dispatchedQuery = libraryQuery
        _libraryRows = []
        albumProcess.command = _helperBase().concat(["radio-builtin"])
        albumProcess.running = true
      }
      _recomputeResults()
      return
    }
    if (albumProcess.running) return
    _dispatchedQuery = libraryQuery
    albumProcess.command = browseAlbum
      ? _helperBase().concat(["album-songs", String(browseAlbum.id)])
      : browseArtist
        ? _helperBase().concat(["artist-albums", String(browseArtist.id)])
        : radio.length > 0
          ? _helperBase().concat(["radio", radio])
          : libraryQuery.length > 0
            ? _helperBase().concat(["search", libraryQuery])
            : _helperBase().concat(["albums", "200"])
    albumProcess.running = true
  }

  function playResult(item) {
    if (!item) return
    if (item.kind === "back") { goBack(); return }
    if (item.kind === "station") { playStation(item); return }
    if (item.kind === "provider") { enterProvider(item); return }
    if (item.kind === "provplaylist") { playProviderPlaylist(item); return }
    if (item.kind === "artist") { enterArtist(item); return }
    // The native browser's Enter on an album opens its tracks; playing the whole
    // thing is the track screen's own "from the top" row.
    if (item.kind === "album") { enterAlbum(item); return }
    if (item.kind === "playlist") { loadPlaylist(String(item.name)); return }
    if (albumPlayProcess.running || !item.id) return
    albumPlayProcess.command = item.kind === "radio"
      ? _helperBase().concat(["play-radio", String(item.id), String(item.name || "")])
      : item.kind === "artistplay"
        ? _helperBase().concat(["play-artist", String(item.id)])
        : item.kind === "playall"
          ? _helperBase().concat(["play", String(item.id)])
          : item.kind === "albumsong"
            // Native track-screen Enter: play this track and queue the rest.
            ? _helperBase().concat(["play-from", String(item.albumId), String(item.id)])
            : _helperBase().concat(["play-song", String(item.id)])
    albumPlayProcess.running = true
  }

  // The native search overlay's `a` and `q`: add to the queue without touching what
  // is playing. The socket queue verb takes a path, so a radio row queues directly
  // and albums/songs resolve their stream URLs through the helper first.
  function queueResult(item) {
    if (!item) return
    if (item.kind === "station") { queueStation(item); return }
    if (item.kind === "provplaylist") { queueProviderPlaylist(item); return }
    if (item.kind === "radio") {
      if (send('{"cmd":"queue","path":' + JSON.stringify(String(item.id)) + '}')) settleTimer.restart()
      return
    }
    var verbByKind = { song: "url-song", albumsong: "url-song", album: "urls",
                       playall: "urls", artist: "urls-artist", artistplay: "urls-artist" }
    var verb = verbByKind[item.kind]
    if (!verb) return
    if (queueProcess.running || !item.id) return
    queueProcess.command = _helperBase().concat([verb, String(item.id)])
    queueProcess.running = true
  }

  Process {
    id: queueProcess
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var rows = []
        try { rows = JSON.parse(String(text || "").trim()) } catch (e) { rows = [] }
        if (!rows || rows.length === undefined) rows = []
        for (var i = 0; i < rows.length; i++) {
          var path = rows[i] ? String(rows[i].path || "") : ""
          if (path.length > 0) root.send('{"cmd":"queue","path":' + JSON.stringify(path) + '}')
        }
        if (rows.length > 0) settleTimer.restart()
      }
    }
  }

  Process {
    id: albumProcess
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root._libraryRows = Model.parseResults(text)
        root._recomputeResults()
      }
    }
    onExited: if (root._dispatchedQuery !== root.libraryQuery) root._dispatchLibrary()
  }

  Process {
    id: albumPlayProcess
    command: []
    onExited: settleTimer.restart()
  }

  function readPlaylists() {
    if (playlistProcess.running || sshTarget.length === 0) return
    playlistProcess.command = sshCommand(remoteCliamp + " playlist list")
    playlistProcess.running = true
  }

  Process {
    id: playlistProcess
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.playlists = Model.parsePlaylists(text)
        root._recomputeResults()
      }
    }
  }

  function loadPlaylist(name) {
    if (!name) return
    if (send('{"cmd":"load","playlist":' + JSON.stringify(String(name)) + '}')) settleTimer.restart()
  }

  // Shuffle and repeat have no documented socket verb, so they go through the CLI on
  // the server, which talks to the daemon over the same socket from its own side.
  function toggleShuffle() {
    if (actionProcess.running || sshTarget.length === 0) return
    actionProcess.command = sshCommand(remoteCliamp + " shuffle")
    actionProcess.running = true
  }

  function cycleRepeat() {
    if (actionProcess.running || sshTarget.length === 0) return
    actionProcess.command = sshCommand(remoteCliamp + " repeat")
    actionProcess.running = true
  }

  // The remote counterpart of "start cliamp in a terminal": bring the daemon up on
  // the server. setsid + nohup so it survives the ssh session that spawned it. Only
  // offered while nothing owns the remote socket.
  function openPlayer() {
    if (running || sshTarget.length === 0) return
    Quickshell.execDetached(sshCommand(
      "setsid nohup " + remoteCliamp + " --daemon >/dev/null 2>&1 &"))
  }

  Process {
    id: actionProcess
    command: []
    onExited: settleTimer.restart()
  }

  Timer {
    id: settleTimer
    // Short: with the multiplexed connection a verb lands in tens of
    // milliseconds, so the re-read does not need to wait long for it.
    interval: 250
    repeat: false
    onTriggered: root.refreshStatus()
  }
}
