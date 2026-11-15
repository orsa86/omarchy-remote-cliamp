import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
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

  // The target lands in ssh's argv and the cliamp path inside remote shell
  // lines, so both are whitelisted rather than escaped: a value that could read
  // as an ssh option ("-oProxyCommand=...") or as shell syntax never leaves
  // this file. The cliamp path keeps `~` unquoted on purpose — quoting would
  // kill the tilde expansion the default depends on — which is exactly why its
  // charset must stay this narrow. Invalid settings fall back to defaults.
  readonly property bool targetValid: isLocal
    || (sshTarget.length > 0 && sshTarget.length <= 256
        && sshTarget.charAt(0) !== "-" && /^[A-Za-z0-9_.@%-]+$/.test(sshTarget))

  readonly property string label: String(setting("label", "") || sshTarget || "unset")

  readonly property string remoteSocket: {
    var raw = String(setting("remoteSocket", ".config/cliamp/cliamp.sock"))
    return raw.length > 0 && raw.length <= 512 && raw.charAt(0) !== "-"
        && /^[A-Za-z0-9_.\/-]+$/.test(raw)
      ? raw : ".config/cliamp/cliamp.sock"
  }

  readonly property string remoteCliamp: {
    var raw = String(setting("remoteCliamp", "~/.local/bin/cliamp"))
    return raw.length > 0 && raw.length <= 512 && raw.charAt(0) !== "-"
        && /^[A-Za-z0-9_.\/~-]+$/.test(raw)
      ? raw : "~/.local/bin/cliamp"
  }
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
    // "--" ends option parsing, so the (already whitelisted) target can never
    // be read as an ssh option even if the whitelist is somehow bypassed.
    return ["ssh", "-T",
      "-o", "BatchMode=yes",
      "-o", "ConnectTimeout=5",
      "-o", "ControlMaster=auto",
      "-o", "ControlPath=" + root.controlPath,
      "-o", "ControlPersist=60",
      "--", root.sshTarget, remoteLine]
  }

  // A remote `head -c` bounds only a well-behaved server — the far side of an
  // ssh channel chooses what it actually streams back. This caps the bytes on
  // this side of the channel, and head exiting SIGPIPEs the producer, so a
  // hostile server can neither grow the StdioCollector nor keep the channel
  // busy past the cap. maxBytes is always one of our own numeric constants.
  function cappedCommand(argv, maxBytes) {
    return ["bash", "-c", '"$@" | head -c ' + Number(maxBytes), "--"].concat(argv)
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
    // Capped locally: StdioCollector would otherwise buffer whatever a hostile
    // server printed, without limit.
    command: root.cappedCommand(root.sshCommand('printf %s "$HOME"'), 4096)
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
      "--", root.sshTarget]
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
    if (isLocal || !targetValid || tunnelProcess.running) return
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

  // A remote player's PipeWire graph is in another room, so remote volume is
  // cliamp's own socket gain. Locally the player's playback stream DOES sit in
  // this machine's graph (node "alsa_playback.cliamp"), and PipeWire moves its
  // volume in float with a ramp — no clipping, no zipper — so the local slider
  // drives that instead. Matching stays on node.name: reading node.properties
  // before the node is bound can destabilize the Pipewire service (see the
  // stock audio panel's comment).
  readonly property var _pwStreamNode: {
    if (!isLocal || !Pipewire.nodes) return null
    var nodes = Pipewire.nodes.values
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (!n || !n.isStream) continue
      if (String(n.name || "").indexOf("cliamp") !== -1) return n
    }
    return null
  }

  PwObjectTracker { objects: root._pwStreamNode ? [root._pwStreamNode] : [] }

  readonly property bool hasStreamVolume: !!(_pwStreamNode && _pwStreamNode.audio)
  readonly property real streamVolume: hasStreamVolume ? _pwStreamNode.audio.volume : 0

  function setStreamVolume(v) {
    if (!hasStreamVolume) return
    _pwStreamNode.audio.volume = Math.max(0, Math.min(1, Number(v) || 0))
  }
  readonly property real volumeDb: Number(status.volumeDb || 0)
  property real pendingVolumeDb: -999
  readonly property real shownVolumeDb: pendingVolumeDb > -900 ? pendingVolumeDb : volumeDb

  // A drag emits one value per pixel; sending each one makes cliamp step its
  // gain dozens of times a second with no ramp — audible zipper noise. The
  // slider stays instant via pendingVolumeDb; the socket gets the first value
  // right away and then at most one send per 150 ms, always ending on the
  // final position.
  property real _volumeTargetDb: -999

  function setVolumeDb(value) {
    var db = Math.max(-30, Math.min(6, Math.round(Number(value) || 0)))
    pendingVolumeDb = db
    volumeHold.restart()
    _volumeTargetDb = db
    if (!volumeSend.running) {
      _sendVolume()
      volumeSend.restart()
    }
  }

  function _sendVolume() {
    if (_volumeTargetDb < -900) return
    var db = _volumeTargetDb
    _volumeTargetDb = -999
    if (request("volume", { "value": db })) settleTimer.restart()
  }

  Timer {
    id: volumeSend
    interval: 150
    repeat: false
    onTriggered: root._sendVolume()
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
    if (request("toggle")) settleTimer.restart()
  }

  Timer {
    id: playHold
    interval: 2500
    repeat: false
    onTriggered: root.pendingPlaying = -1
  }

  function next() { if (request("next")) settleTimer.restart() }
  function previous() { if (request("prev")) settleTimer.restart() }

  // The socket seek takes a delta, not a position, measured on 1.63.2.
  function seekTo(targetSec) {
    if (!canSeek) {
      if (hasProgress) seekRefused()
      return
    }
    var target = Math.max(0, Math.min(lengthSec, Number(targetSec) || 0))
    var delta = Math.round(target - positionSec)
    positionSec = target
    if (request("seek", { "value": delta })) settleTimer.restart()
  }

  function seekBy(deltaSec) { seekTo(positionSec + Number(deltaSec || 0)) }

  // ---- the wire ----

  // cliamp 2.0 replaced the socket protocol outright: 1.x takes bare
  // {"cmd":...} lines and answers each in place, 2.x takes only versioned
  // envelopes, runs every operation as a job and reports the outcome on an
  // event stream. One server picker can hold both generations, so the dialect
  // is found per connection: the first status goes out as 2.x, and a 1.x
  // daemon gives itself away by answering without a version. 0 = not known yet.
  property int protocol: 0
  // 2.x results arrive on the event stream, so nothing that expects one may
  // go out before the subscription stands.
  property bool eventsReady: false
  readonly property bool ipcReady: ipcConnected && (protocol === 1 || (protocol === 2 && eventsReady))

  // Doubles as the dialect probe while the protocol is still unknown.
  function refreshStatus() {
    if (!ipcConnected) return
    ipcLoader.item.write((protocol === 1 ? Model.v1Request("status") : Model.V2_STATE_REQUEST) + "\n")
    ipcLoader.item.flush()
  }

  // One verb, either dialect. Operation names and their arguments are the same
  // in both; only the envelope differs.
  function request(operation, params) {
    if (!ipcReady) return false
    ipcLoader.item.write((protocol === 2
      ? Model.v2Submit(operation, params)
      : Model.v1Request(operation, params)) + "\n")
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
    if (request("lyrics")) {
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

  function acceptLyrics(rows) {
    var wanted = lyricsPendingPath
    lyricsPendingPath = ""
    lyricsTimeout.stop()
    if (wanted === String(status.path || "")) {
      lyrics = rows
      lyricsStatus = lyrics.length > 0 ? "ok" : "notfound"
      return
    }
    lyricsTrackPath = ""
    refreshLyrics()
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

  function refreshQueue() {
    if (protocol !== 2) { request("queue.list"); return }
    _queueAcc = null
    _askQueuePage(0)
  }

  // 2.x pages the queue, V2_PAGE_SIZE rows at a time. Rows gather here and
  // reach the screen as one list, so a long queue never shows up cut short.
  property var _queueAcc: null
  property real _queueAccRevision: -1
  // The playlist revision the list on screen reflects; -1 while it may be stale.
  property real _queueRevision: -1

  function _askQueuePage(offset) {
    return request("queue.list", { "offset": offset, "limit": Model.V2_PAGE_SIZE })
  }

  // snapshot is the job's own: it says which revision of the list the page is.
  function _acceptQueuePage(page, snapshot) {
    var rev = snapshot ? snapshot.playlistRevision : -1
    if (page.offset > 0) {
      // A continuation counts only as the next page of the list being gathered.
      if (_queueAcc === null || page.offset !== _queueAcc.length || rev < _queueAccRevision) return
      // The list moved on under the read: start over.
      if (rev > _queueAccRevision) { _queueAcc = null; _queueRevision = -1; return }
      _queueAcc = _queueAcc.concat(page.tracks)
    } else {
      // Rows promised and none delivered is a page past the end of a list
      // that shrank, not a first page.
      if (page.tracks.length === 0 && page.total > 0) { _queueAcc = null; _queueRevision = -1; return }
      _queueAcc = page.tracks
      _queueAccRevision = rev
    }
    queueIndex = page.index
    var want = Math.min(page.total, Model.MAX_LIST_ITEMS)
    if (_queueAcc.length < want && page.tracks.length > 0 && panelOpen) { queueSync.restart(); return }
    queue = _queueAcc.slice(0, Model.MAX_LIST_ITEMS)
    _queueRevision = _queueAcc.length >= want ? _queueAccRevision : -1
    _queueAcc = null
  }

  Timer {
    id: queueSync
    // A mutation's own job record carries the fresh list and lands right
    // behind the state event that announces it; this is long enough for it to
    // win, so a change costs no extra read and a burst of them at most a few.
    interval: 120
    repeat: false
    onTriggered: {
      if (root.protocol !== 2 || !root.panelOpen) return
      if (root._queueAcc !== null) root._askQueuePage(root._queueAcc.length)
      else if (root.status.ok === true && root.status.playlistRevision !== root._queueRevision) root._askQueuePage(0)
    }
  }

  // Every mutation answers with the fresh track list, so the panel updates from
  // the reply itself — no follow-up read. Indices are 0-based, verified in
  // ipc_extended.go and live against 1.63.2.
  function queueJump(i) {
    if (request("queue.play", { "index": Number(i) })) settleTimer.restart()
  }

  function queueRemove(i) {
    if (request("queue.remove", { "index": Number(i) })) settleTimer.restart()
  }

  function queueMove(i, to) {
    if (to < 0 || to >= queue.length) return
    if (request("queue.move", { "index": Number(i), "to": Number(to) })) settleTimer.restart()
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
    if (request("provider.playlists", { "provider": "radio" })) {
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
    if (request("provider.list")) {
      _providersPending = true
      stationsTimeout.restart()
    }
  }

  function enterProvider(item) {
    browseProvider = { id: String(item.id), name: String(item.name || "") }
    providerPlaylists = []
    if (request("provider.playlists", { "provider": String(item.id) })) {
      _provListsPending = true
      stationsTimeout.restart()
    }
    _recomputeResults()
  }

  function playProviderPlaylist(item) {
    if (!browseProvider) return
    // Same shape as a station: provider.load replaces the queue, then play.
    if (request("provider.load", { "provider": String(browseProvider.id), "playlist": String(item.id) })) {
      request("play")
      settleTimer.restart()
    }
  }

  function queueProviderPlaylist(item) {
    if (!browseProvider || _stationQueuePending.length > 0) return
    _askTracks(String(browseProvider.id), String(item.id), 0)
  }

  // The provider.tracks question that is out, so a paged answer can be
  // continued: { provider, playlist, offset }.
  property var _tracksAsk: null

  function _askTracks(provider, playlist, offset) {
    var params = { "provider": provider, "playlist": playlist }
    // 2.x pages this list too; 1.x answers with all of it.
    if (protocol === 2) { params.offset = offset; params.limit = Model.V2_PAGE_SIZE }
    if (!request("provider.tracks", params)) return false
    _stationQueuePending = playlist
    _tracksAsk = { provider: provider, playlist: playlist, offset: offset }
    stationsTimeout.restart()
    return true
  }

  function _queuePaths(paths) {
    for (var i = 0; i < paths.length; i++) request("queue", { "path": paths[i] })
    if (paths.length > 0) settleTimer.restart()
  }

  function playStation(item) {
    // provider.load replaces the queue with the station but lands paused,
    // measured on 1.63.2; requests are served in order, so play follows it.
    if (request("provider.load", { "provider": "radio", "playlist": String(item.id) })) {
      request("play")
      settleTimer.restart()
    }
  }

  function queueStation(item) {
    if (_stationQueuePending.length > 0) return
    _askTracks("radio", String(item.id), 0)
  }

  Timer {
    id: stationsTimeout
    interval: 5000
    repeat: false
    onTriggered: {
      root._stationsPending = false
      root._stationQueuePending = ""
      root._tracksAsk = null
      root._providersPending = false
      root._provListsPending = false
    }
  }

  // One re-read per track change while the queue is on screen, keyed on the
  // fields a change actually moves.
  property string _queueSeen: ""

  function _maybeRefreshQueue() {
    if (protocol === 2) {
      // The snapshot names the playing row itself, and its playlist revision
      // says exactly when the list on screen went stale.
      if (status.ok !== true) return
      if (status.index >= 0) queueIndex = status.index
      if (!panelOpen) return
      if ((_queueAcc !== null || status.playlistRevision !== _queueRevision) && !queueSync.running) queueSync.start()
      return
    }
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

  // ---- what comes back ----

  function _handleLine(raw) {
    // The assembler already dropped anything this big, but keep the guard in
    // front of JSON.parse anyway.
    if (raw.length > Model.MAX_FRAME_BYTES) return
    if (protocol === 1 && !Model.looksLikeV2(raw)) { _handleV1Line(raw); return }
    var frame = Model.parseV2Frame(raw)
    if (frame.kind === "none") return
    var spoke = frame.kind === "legacy" ? 1 : 2
    if (spoke !== protocol) {
      // The first answer on a connection names the dialect. Unless it is a
      // 2.x daemon answering the 2.x probe, it answered a question asked in
      // the wrong dialect: drop it and ask for the status again in the right one.
      var probed = protocol === 0 && spoke === 2
      protocol = spoke
      if (!probed) { refreshStatus(); return }
    }
    if (spoke === 2) _handleV2Frame(frame)
  }

  // 2.x numbers its snapshots, and they arrive on two connections — the
  // poll's and the event stream's — so an older one can land after a newer.
  property real _stateRevision: -1

  function _applyStatus(parsed) {
    if (parsed.ok && protocol === 2) {
      // Stale, but still proof the daemon is alive.
      if (parsed.revision < _stateRevision) { freshTimer.restart(); return }
      _stateRevision = parsed.revision
    }
    status = parsed
    lastError = parsed.ok ? "" : parsed.lastError
    if (parsed.ok) { positionSec = Number(parsed.positionSec || 0); freshTimer.restart() }
  }

  // cliamp 1.x: one reply per request, in order, told apart by shape.
  function _handleV1Line(raw) {
    var kind = Model.messageKind(raw)
    if (kind === "providers") {
      _providersPending = false
      providers = Model.parseProviders(raw)
      _recomputeResults()
      return
    }
    if (kind === "stations") {
      // Same reply shape serves two askers: the radio view and a
      // provider drill-down. Whoever asked last owns it.
      if (_provListsPending) {
        _provListsPending = false
        var rows = Model.parseStations(raw)
        for (var pi = 0; pi < rows.length; pi++) rows[pi].kind = "provplaylist"
        providerPlaylists = rows
      } else {
        _stationsPending = false
        stations = Model.parseStations(raw)
      }
      _recomputeResults()
      return
    }
    if (kind === "queue") {
      // Same shape as a queue reply; ownership decides the meaning.
      if (_stationQueuePending.length > 0) {
        _stationQueuePending = ""
        _tracksAsk = null
        // parseQueue drops the path field, so the raw reply is what queues.
        _queuePaths(Model.trackPaths(Model.parseObject(raw)).paths)
        return
      }
      var q = Model.parseQueue(raw)
      if (q.ok) { queue = q.tracks; queueIndex = q.index }
      return
    }
    if (kind === "lyrics") { acceptLyrics(Model.parseLyrics(raw)); return }
    if (kind === "ack") { lastError = Model.ackError(raw); return }
    if (kind !== "status") return
    _applyStatus(Model.parseStatus(raw))
  }

  // cliamp 2.x: a state read answers in place; everything else answers with a
  // job whose final record — result and fresh snapshot — arrives as an event.
  // That stream reports every client's jobs, which is welcome for the queue
  // (the list follows changes made elsewhere) and filtered for the rest by
  // what this panel is actually waiting on.
  function _handleV2Frame(frame) {
    if (frame.kind === "state") { _applyStatus(frame.status); return }
    if (frame.kind === "job") { _handleJob(frame); return }
    if (frame.kind === "error") lastError = frame.message
    // "ack": accepted; the outcome follows on the event stream.
  }

  function _handleJob(job) {
    var op = job.operation
    if (!job.ok) {
      // A track without lyrics fails its job; that is an answer, not a fault.
      if (op !== "lyrics") lastError = job.error
      else if (lyricsPendingPath.length > 0) acceptLyrics([])
      return
    }
    // The queue page goes first: it settles which playlist revision the list
    // on screen reflects, so the snapshot behind it does not ask for it again.
    if (Model.isQueueOperation(op)) {
      _acceptQueuePage(Model.queuePageFromResult(job.result), job.status)
    } else if (op === "lyrics") {
      if (lyricsPendingPath.length > 0) acceptLyrics(Model.lyricsFromData(job.result))
    } else if (op === "provider.list") {
      _providersPending = false
      providers = Model.providersFromData(job.result)
      _recomputeResults()
    } else if (op === "provider.playlists") {
      _acceptPlaylists(job.result)
    } else if (op === "provider.tracks") {
      _acceptTracks(job.result)
    }
    if (job.status) _applyStatus(job.status)
  }

  // 2.x rows name their provider, which settles whose list this is: the radio
  // view's, the drill-down's, or — browsing the radio provider — both. An
  // empty list names nobody and goes to whoever asked last, as on 1.x.
  function _acceptPlaylists(result) {
    var key = Model.playlistsProvider(result)
    var toBrowse = key.length > 0
      ? browseProvider !== null && key === String(browseProvider.id)
      : _provListsPending
    var toStations = key.length > 0 ? key === "radio" : (!_provListsPending && _stationsPending)
    if (toBrowse) {
      _provListsPending = false
      var rows = Model.stationsFromData(result)
      for (var i = 0; i < rows.length; i++) rows[i].kind = "provplaylist"
      providerPlaylists = rows
    }
    if (toStations) {
      _stationsPending = false
      stations = Model.stationsFromData(result)
    }
    if (toBrowse || toStations) _recomputeResults()
  }

  // Only ever this panel's own question: these rows get queued, so somebody
  // else's provider.tracks must not land here.
  function _acceptTracks(result) {
    var ask = _tracksAsk
    if (_stationQueuePending.length === 0 || !ask) return
    var named = result ? String(result.playlist || "") : ""
    if (named.length > 0 && named !== ask.playlist) return
    var got = Model.trackPaths(result)
    _queuePaths(got.paths)
    var next = ask.offset + got.count
    var total = result ? Number(result.total) || 0 : 0
    if (got.count > 0 && next < total && next < Model.MAX_LIST_ITEMS
        && _askTracks(ask.provider, ask.playlist, next)) return
    _stationQueuePending = ""
    _tracksAsk = null
  }

  // ---- the socket itself ----

  // Same hazard as the local plugin, plus one of this setup's own: the ssh listener
  // accepts a connection even when the far socket is gone, and only then fails the
  // channel. So "connected" can flap while the remote daemon is down, and a stale
  // status would otherwise survive that flapping forever. freshTimer is the answer:
  // only an actual status reply keeps the panel claiming the server is up.
  readonly property bool ipcConnected: !!(ipcLoader.item && ipcLoader.item.connected)

  // A new connection may reach a different daemon — restarted, or upgraded
  // across the protocol break — so nothing learned from the old one survives.
  onIpcConnectedChanged: if (!ipcConnected) protocol = 0

  onProtocolChanged: {
    _stateRevision = -1
    _queueAcc = null
    _queueRevision = -1
    _openEvents()
  }

  Loader {
    id: ipcLoader
    active: true
    sourceComponent: Socket {
      id: ipcSocket
      path: root.socketPath
      connected: true

      // SplitParser's newline mode retains an unterminated line with no cap, so
      // a peer could grow that buffer forever without ever completing a line.
      // splitMarker "" hands over raw chunks instead — SplitParser retains
      // nothing — and this assembler reassembles lines under a hard byte
      // ceiling, dropping oversized ones and resyncing at the next newline.
      // Fresh per Socket instantiation, so a reconnect never inherits state.
      property var lineAssembler: Model.createLineAssembler(Model.MAX_FRAME_BYTES)

      onConnectionStateChanged: {
        if (connected) { root.refreshStatus(); return }
        root.dropLyricsRequest()
      }

      parser: SplitParser {
        splitMarker: ""
        onRead: function (chunk) {
          var lines = ipcSocket.lineAssembler.feed(chunk)
          for (var li = 0; li < lines.length; li++) root._handleLine(String(lines[li] || ""))
        }
      }
    }
  }

  // ---- the 2.x event stream ----

  // A second connection to the same socket, because a subscribed connection
  // is the server's to write on: it closes the moment anything else is sent.
  function _openEvents() {
    eventsReady = false
    eventLoader.active = false
    eventLoader.active = ipcConnected && protocol === 2
  }

  function _handleEventLine(raw) {
    if (raw.length > Model.MAX_FRAME_BYTES) return
    var frame = Model.parseV2Frame(raw)
    if (frame.kind === "ok" && frame.id === "events") {
      // Subscribed. Whatever happened before this moment was not reported
      // here, so read the state once and let it pull the rest along.
      eventsReady = true
      _queueRevision = -1
      refreshStatus()
      if (panelOpen) refreshQueue()
      return
    }
    // The stream fell behind and the server is about to close it: open a
    // fresh one, which re-reads the state as above.
    if (frame.kind === "overflow") { _openEvents(); return }
    // A refused subscription; eventRetry tries again at its own pace.
    if (frame.kind === "error" || frame.kind === "legacy") { eventsReady = false; eventLoader.active = false; return }
    if (eventsReady) _handleV2Frame(frame)
  }

  Loader {
    id: eventLoader
    active: false
    sourceComponent: Socket {
      id: eventSocket
      path: root.socketPath
      connected: true

      // Same capped assembler as the request socket, for the same reason.
      property var lineAssembler: Model.createLineAssembler(Model.MAX_FRAME_BYTES)

      onConnectionStateChanged: {
        if (!connected) { root.eventsReady = false; return }
        write(Model.V2_SUBSCRIBE_REQUEST + "\n")
        flush()
      }

      parser: SplitParser {
        splitMarker: ""
        onRead: function (chunk) {
          var lines = eventSocket.lineAssembler.feed(chunk)
          for (var li = 0; li < lines.length; li++) root._handleEventLine(String(lines[li] || ""))
        }
      }
    }
  }

  // Without the stream a 2.x daemon still answers status, but no job would
  // ever report back, so the stream is chased for as long as it is missing.
  Timer {
    id: eventRetry
    interval: 1500
    repeat: true
    running: root.ipcConnected && root.protocol === 2 && !root.eventsReady
    onTriggered: root._openEvents()
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
    running: root.panelOpen && root.isPlaying && root.targetValid
    // Same unbounded-retention hazard as the socket parser: newline mode would
    // buffer an unterminated line forever. Raw chunks plus a capped assembler.
    property var lineAssembler: Model.createLineAssembler(Model.MAX_VIS_FRAME_BYTES)
    stdout: SplitParser {
      splitMarker: ""
      onRead: function (chunk) {
        var lines = visProcess.lineAssembler.feed(chunk)
        for (var li = 0; li < lines.length; li++) {
          var frame = Model.parseBands(lines[li])
          if (frame.length > 0) root.bands = frame
        }
      }
    }
    onRunningChanged: {
      if (!running) root.bands = []
      // One stream, one assembler: never carry half a line into the next run.
      lineAssembler = Model.createLineAssembler(Model.MAX_VIS_FRAME_BYTES)
    }
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
  // A YouTube playlist opened from a "ytp:" result: its tracks, one level deep.
  property var browseYtList: null
  readonly property string breadcrumb: {
    var parts = []
    if (browseArtist) parts.push(String(browseArtist.name || ""))
    if (browseAlbum) parts.push(String(browseAlbum.name || ""))
    if (browseYtList) parts.push(String(browseYtList.name || ""))
    return parts.join(" / ")
  }

  function _row(kind, id, name) {
    return { kind: kind, id: String(id), name: name, artist: "", album: "", albumId: "", songCount: 0, duration: 0 }
  }

  function _recomputeResults() {
    if (browseYtList) {
      results = [
        _row("back", "", "‹ " + String(browseYtList.name || "")),
        _row("ytplayall", browseYtList.id, "▶ Play the whole playlist")
      ].concat(_libraryRows)
      return
    }
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
    if (Model.isYtMode(libraryQuery) || Model.isYtListMode(libraryQuery)) {
      // Whatever yt-dlp on the server answered for the last settled query; while
      // the next one is still being typed the old rows stay, re-ranked. A yt-dlp
      // run is seconds (a slow ARM box: six or more), so an owed reply says so
      // instead of leaving "nothing matched" on screen the whole wait.
      var ytq = Model.isYtListMode(libraryQuery) ? Model.ytListQuery(libraryQuery) : Model.ytQuery(libraryQuery)
      var rows = ytq.length > 0 && _dispatchedQuery !== libraryQuery
        ? Model.fuzzyFilter(_libraryRows, ytq)
        : _libraryRows
      if (rows.length === 0 && ytq.length > 0 && (_ytPending || _dispatchedQuery !== libraryQuery))
        rows = [_row("info", "", "searching YouTube on " + String(label || sshTarget) + " …")]
      results = rows
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

  // A YouTube search is a yt-dlp run on the server, seconds each, so it waits
  // for the typing to pause instead of firing per keystroke like the local
  // Subsonic search can afford to.
  Timer {
    id: ytDebounce
    interval: 500
    repeat: false
    onTriggered: root._dispatchYt()
  }

  // Set while a yt-dlp run owes the rows on screen.
  property bool _ytPending: false

  function _dispatchYt() {
    if (!targetValid) return
    var lists = Model.isYtListMode(libraryQuery)
    if (!lists && !Model.isYtMode(libraryQuery)) return
    var query = lists ? Model.ytListQuery(libraryQuery) : Model.ytQuery(libraryQuery)
    if (query.length === 0) {
      _dispatchedQuery = libraryQuery
      _libraryRows = []
      _recomputeResults()
      return
    }
    if (albumProcess.running) {
      // A yt-dlp run for a query nobody wants any more is seconds of waiting
      // for nothing: kill it, and its exit re-dispatches the current query.
      if (_ytPending && _dispatchedQuery !== libraryQuery) albumProcess.running = false
      return
    }
    _dispatchedQuery = libraryQuery
    _ytPending = true
    albumProcess.command = _helperBase().concat([lists ? "yt-playlists" : "yt", query])
    albumProcess.running = true
    _recomputeResults()
  }

  function enterYtList(item) {
    browseYtList = { id: String(item.id), name: String(item.name || "") }
    _libraryRows = []
    _recomputeResults()
    _dispatchLibrary()
  }

  function search(query) {
    var next = String(query || "")
    // Leaving provider mode (or changing the prefix) climbs out of a drill-down.
    if (!Model.isProviderMode(next)) browseProvider = null
    libraryQuery = next
    browseArtist = null
    browseAlbum = null
    browseYtList = null
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
    if (browseYtList) browseYtList = null
    else if (browseAlbum) browseAlbum = null
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
    if (!targetValid) return
    if (browseYtList) {
      // One playlist's tracks; a click, not typing, so no debounce needed.
      if (albumProcess.running) return
      _dispatchedQuery = libraryQuery
      albumProcess.command = _helperBase().concat(["yt-tracks", String(browseYtList.id)])
      albumProcess.running = true
      return
    }
    if ((Model.isYtMode(libraryQuery) || Model.isYtListMode(libraryQuery)) && !browseArtist && !browseAlbum) {
      ytDebounce.restart()
      return
    }
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
    if (item.kind === "info") return
    if (item.kind === "station") { playStation(item); return }
    if (item.kind === "provider") { enterProvider(item); return }
    if (item.kind === "provplaylist") { playProviderPlaylist(item); return }
    if (item.kind === "ytplaylist") { enterYtList(item); return }
    if (item.kind === "artist") { enterArtist(item); return }
    // The native browser's Enter on an album opens its tracks; playing the whole
    // thing is the track screen's own "from the top" row.
    if (item.kind === "album") { enterAlbum(item); return }
    if (item.kind === "playlist") { loadPlaylist(String(item.name)); return }
    if (albumPlayProcess.running || !item.id) return
    albumPlayProcess.command = item.kind === "radio"
      ? _helperBase().concat(["play-radio", String(item.id), String(item.name || "")])
      : item.kind === "yt"
        // A YouTube row is a page URL; the server's yt-dlp resolves the audio when
        // cliamp plays it, so this is the radio path with a title and an uploader.
        ? _helperBase().concat(["play-yt", String(item.id), String(item.name || ""), String(item.artist || "")])
      : item.kind === "ytplayall"
        ? _helperBase().concat(["play-yt-list", String(item.id), String(browseYtList ? browseYtList.name || "" : "")])
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
    if (!item || item.kind === "info") return
    if (item.kind === "station") { queueStation(item); return }
    if (item.kind === "provplaylist") { queueProviderPlaylist(item); return }
    if (item.kind === "radio") {
      if (request("queue", { "path": String(item.id) })) settleTimer.restart()
      return
    }
    if (item.kind === "yt") {
      // track.queue carries the title and uploader along; the bare queue verb
      // would name the row "watch", the last path segment of the page URL. Its
      // reply is a queue list, which the router already accepts as one.
      if (_stationQueuePending.length > 0) return
      var track = { path: String(item.id), title: String(item.name || ""),
                    artist: String(item.artist || ""), stream: true }
      if (item.duration > 0) track.duration_secs = Number(item.duration)
      if (request("track.queue", { "track": track })) settleTimer.restart()
      return
    }
    var verbByKind = { song: "url-song", albumsong: "url-song", album: "urls",
                       playall: "urls", artist: "urls-artist", artistplay: "urls-artist",
                       ytplaylist: "urls-yt", ytplayall: "urls-yt" }
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
          if (path.length === 0) continue
          if (rows[i].kind === "yt") {
            // Page URLs carry no tags cliamp could read; hand it the title too.
            var track = { path: path, title: String(rows[i].title || ""),
                          artist: String(rows[i].artist || ""), stream: true }
            if (Number(rows[i].duration) > 0) track.duration_secs = Number(rows[i].duration)
            root.request("track.queue", { "track": track })
          } else {
            root.request("queue", { "path": path })
          }
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
    onExited: {
      root._ytPending = false
      if (root._dispatchedQuery !== root.libraryQuery) root._dispatchLibrary()
      else root._recomputeResults()
    }
  }

  Process {
    id: albumPlayProcess
    command: []
    onExited: settleTimer.restart()
  }

  function readPlaylists() {
    if (playlistProcess.running || !targetValid) return
    // The remote head trims an honest server's reply before it crosses the
    // wire; cappedCommand enforces the same bound locally for a hostile one.
    playlistProcess.command = cappedCommand(sshCommand(remoteCliamp + " playlist list | head -c 262144"), 262144)
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
    if (request("load", { "playlist": String(name) })) settleTimer.restart()
  }

  // Shuffle and repeat have no documented socket verb, so they go through the CLI on
  // the server, which talks to the daemon over the same socket from its own side.
  function toggleShuffle() {
    if (actionProcess.running || !targetValid) return
    actionProcess.command = sshCommand(remoteCliamp + " shuffle")
    actionProcess.running = true
  }

  function cycleRepeat() {
    if (actionProcess.running || !targetValid) return
    actionProcess.command = sshCommand(remoteCliamp + " repeat")
    actionProcess.running = true
  }

  // The remote counterpart of "start cliamp in a terminal": bring the daemon up on
  // the server. setsid + nohup so it survives the ssh session that spawned it. Only
  // offered while nothing owns the remote socket.
  function openPlayer() {
    if (running || !targetValid) return
    // ~/.local/bin first: cliamp finds yt-dlp by PATH, and a user-installed one
    // there is how a server without root gets a current yt-dlp.
    Quickshell.execDetached(sshCommand(
      'PATH="$HOME/.local/bin:$PATH" setsid nohup ' + remoteCliamp + " --daemon >/dev/null 2>&1 &"))
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
