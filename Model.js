// Pure helpers for the Cliamp panel. No QML imports, so this file is testable with Deno.

var MAX_ERROR_CHARS = 140

// ---- trust-boundary limits ----
// Everything below parses data from the far side of a trust boundary — a remote
// cliamp, a Subsonic server, LedFx, Radio Browser. A compromised peer must not
// be able to balloon the long-lived shell process, so every reply is bounded
// before it is materialized into model rows: one frame, one row count, one
// string length. Callers drop oversized frames with frameTooLarge() BEFORE
// JSON.parse touches them.
var MAX_FRAME_BYTES = 1048576   // one socket line or helper reply
var MAX_LIST_ITEMS = 1000       // rows kept from any list reply
var MAX_TEXT_CHARS = 512        // any display string (title, artist, name, ...)
var MAX_PATH_CHARS = 8192       // URLs and paths
var MAX_BAND_COUNT = 32         // spectrum frame
var MAX_VIS_FRAME_BYTES = 4096  // one visualizer NDJSON frame

function frameTooLarge(raw) {
  return String(raw || "").length > MAX_FRAME_BYTES
}

function clampText(value, max) {
  var s = String(value || "")
  return s.length > max ? s.slice(0, max) : s
}

// Streaming line assembler with a hard retained-byte ceiling. SplitParser's own
// newline mode retains an unterminated line without any cap, so the streams from
// the far side of a trust boundary use splitMarker "" (raw chunks, nothing
// retained) and reassemble lines here instead. A partial line that outgrows
// maxBytes is thrown away and the stream skips forward to the next newline, so
// an unterminated flood holds at most maxBytes plus one in-flight chunk.
// A chunk boundary can split a multi-byte UTF-8 character; the garbled line then
// fails JSON.parse and is dropped — cliamp writes whole lines per write, so in
// practice chunks align with messages.
function createLineAssembler(maxBytes) {
  return {
    buffer: "",
    skipping: false,
    overflows: 0,
    feed: function (chunk) {
      var text = String(chunk || "")
      var lines = []
      while (text.length > 0) {
        var nl = text.indexOf("\n")
        if (this.skipping) {
          if (nl === -1) return lines
          this.skipping = false
          text = text.slice(nl + 1)
          continue
        }
        if (nl === -1) {
          if (this.buffer.length + text.length > maxBytes) {
            this.buffer = ""
            this.skipping = true
            this.overflows++
            return lines
          }
          this.buffer += text
          return lines
        }
        // Length check before the concat, so an oversized line is dropped
        // without ever being materialized as one string.
        if (this.buffer.length + nl > maxBytes) {
          this.buffer = ""
          this.overflows++
        } else {
          lines.push(this.buffer + text.slice(0, nl))
          this.buffer = ""
        }
        text = text.slice(nl + 1)
      }
      return lines
    }
  }
}

var SECONDS_PER_MINUTE = 60
var MINUTES_PER_HOUR = 60
// Rates within this many Hz are the same rate, covering integer rounding in the graph.
var RATE_MATCH_TOLERANCE_HZ = 1

function defaultStatus() {
  return {
    ok: false,
    state: "stopped",
    title: "",
    path: "",
    isStream: false,
    durationSec: 0,
    positionSec: 0,
    artist: "",
    album: "",
    volumeDb: 0,
    total: 0,
    index: -1,
    shuffle: false,
    repeat: "Off",
    visualizer: "",
    eqFlat: true,
    // cliamp 2.x only: its counters for "something changed" and "the live
    // playlist changed". -1 where the daemon reports none (1.x).
    revision: -1,
    playlistRevision: -1,
    lastError: ""
  }
}

// Sample input, from a running instance:
// {"ok":true,"state":"playing","track":{"title":"probe441","path":"/tmp/probe441.flac"},
//  "position":16.87,"duration":600,"volume":-6.04,"total":1,"shuffle":false,"repeat":"Off",...}
// A radio entry adds "stream":true inside track. When no socket exists cliamp exits 1
// and prints a plain sentence instead of JSON.
function parseStatus(raw) {
  var out = defaultStatus()
  if (frameTooLarge(raw)) {
    out.lastError = "reply too large"
    return out
  }
  var text = String(raw || "").trim()
  if (text.length === 0) {
    out.lastError = "cliamp returned nothing"
    return out
  }

  var data = null
  try {
    data = JSON.parse(text)
  } catch (e) {
    out.lastError = elideError(text)
    return out
  }
  if (!data || typeof data !== "object") {
    out.lastError = elideError(text)
    return out
  }

  out.ok = data.ok === true
  if (!out.ok) {
    out.lastError = elideError(String(data.error || text))
    return out
  }

  fillStatus(out, data)
  out.index = numberOr(data.index, -1)
  return out
}

// The player state fields, spelled the same in a 1.x status reply and in a 2.x
// snapshot. index is left to the caller: the two generations disagree on what
// a missing one means.
function fillStatus(out, src) {
  out.state = clampText(src.state || "stopped", MAX_TEXT_CHARS)
  out.volumeDb = numberOr(src.volume, 0)
  out.total = numberOr(src.total, 0)
  out.shuffle = src.shuffle === true
  out.repeat = clampText(src.repeat || "Off", MAX_TEXT_CHARS)
  out.visualizer = clampText(src.visualizer, MAX_TEXT_CHARS)
  out.eqFlat = bandsAreFlat(src.eq_bands)

  out.durationSec = numberOr(src.duration, 0)
  out.positionSec = numberOr(src.position, 0)

  var track = src.track
  if (track && typeof track === "object") {
    out.title = clampText(track.title, MAX_TEXT_CHARS)
    out.path = clampText(track.path, MAX_PATH_CHARS)
    out.artist = clampText(track.artist, MAX_TEXT_CHARS)
    out.album = clampText(track.album, MAX_TEXT_CHARS)
    out.isStream = track.stream === true
    if (out.durationSec <= 0) out.durationSec = numberOr(track.duration_secs, 0)
  }
}

// A ten band EQ with anything but zeros is DSP, so the samples are no longer the
// ones the file holds. The preset name is not consulted: cliamp reports "Custom"
// for an untouched EQ, so only the numbers are trustworthy.
function bandsAreFlat(bands) {
  if (!bands || bands.length === undefined) return true
  for (var i = 0; i < bands.length; i++) {
    if (numberOr(bands[i], 0) !== 0) return false
  }
  return true
}

function numberOr(value, fallback) {
  var n = Number(value)
  return isFinite(n) ? n : fallback
}

// Sample input: PipeWire node properties carrying node.rate as a period, "1/44100".
function rateFromNodeProps(props) {
  if (!props) return 0
  var raw = String(props["node.rate"] || "")
  var parts = raw.split("/")
  if (parts.length !== 2) return 0
  var rate = parseInt(parts[1], 10)
  return isFinite(rate) && rate > 0 ? rate : 0
}

// Sample input, one line of `pactl list short sinks`, tab separated:
// 55\talsa_output.pci-0000_00_1f.3.analog-stereo\tPipeWire\ts32le 2ch 44100Hz\tRUNNING
function sinkRateFromPactl(raw) {
  var line = String(raw || "")
  var fields = line.split("\t")
  if (fields.length < 4) return 0
  var pieces = fields[3].split(" ")
  for (var i = 0; i < pieces.length; i++) {
    var piece = pieces[i]
    if (piece.slice(-2) !== "Hz") continue
    var rate = parseInt(piece.slice(0, -2), 10)
    if (isFinite(rate) && rate > 0) return rate
  }
  return 0
}

// Sample input, one line per sink from `omarchy-audio-sink-availability`:
// alsa_output.pci-0000_00_1f.3.analog-stereo\t1
// Same contract the stock audio panel parses, so an unplugged output is filtered
// out of the device list here exactly as it is there.
function parseSinkAvailability(raw) {
  var next = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var parts = line.split("\t")
    if (parts.length >= 2) next[parts[0]] = parts[1] !== "0"
  }
  return next
}

// Sample input, the path cliamp reports for a Navidrome track:
// https://host/rest/stream?c=cliamp&f=json&format=raw&id=XXX&s=SALT&t=TOKEN&u=USER&v=1.0.0
// The same salted token already authorises cover art, so the panel can show artwork
// without ever being told a password. cliamp publishes no art of its own.
function coverArtUrlFromStreamPath(path, size) {
  var text = String(path || "")
  var cut = text.indexOf("?")
  if (cut < 0) return ""
  var base = text.slice(0, cut)
  if (base.indexOf("https://") !== 0) return ""
  var marker = "/rest/stream"
  if (base.slice(-marker.length) !== marker) return ""

  var keep = ["id", "u", "t", "s", "c", "v"]
  var parts = text.slice(cut + 1).split("&")
  var out = []
  for (var i = 0; i < parts.length; i++) {
    var eq = parts[i].indexOf("=")
    if (eq < 0) continue
    var key = parts[i].slice(0, eq)
    for (var j = 0; j < keep.length; j++) {
      if (key === keep[j]) { out.push(parts[i]); break }
    }
  }
  if (out.length === 0) return ""
  out.push("size=" + (size > 0 ? size : 300))
  return base.slice(0, base.length - marker.length) + "/rest/getCoverArt?" + out.join("&")
}

// cliamp asks Navidrome for format=raw, so its absence on a Subsonic stream means
// the server re-encoded the file before sending it.
function transcodedFromPath(path) {
  var text = String(path || "")
  if (text.indexOf("/rest/stream") < 0) return false
  return text.indexOf("format=raw") < 0
}

// Sample input, PipeWire props on a bluez sink:
// api.bluez5.codec = "sbc_xq", api.bluez5.profile = "a2dp-sink"
// Returns a display name only for a lossy A2DP link, and "" for anything wired.
function bluetoothCodecLabel(props) {
  if (!props) return ""
  var codec = String(props["api.bluez5.codec"] || "")
  if (codec.length === 0) return ""
  var names = {
    sbc: "SBC",
    sbc_xq: "SBC-XQ",
    aac: "AAC",
    aptx: "aptX",
    aptx_hd: "aptX HD",
    ldac: "LDAC",
    opus_05: "Opus"
  }
  return names[codec] || codec.toUpperCase()
}

// Sample input from `cliamp playlist list`, two leading spaces and a right hand count:
//     Recently Played  8 tracks
// A playlist saved from the Navidrome browser keeps the resolved stream URLs, which is
// what lets a headless daemon play a library it cannot otherwise browse.
function parsePlaylists(raw) {
  var out = []
  var lines = clampText(raw, MAX_FRAME_BYTES).split("\n")
  for (var i = 0; i < lines.length && out.length < MAX_LIST_ITEMS; i++) {
    var line = trim(lines[i])
    if (line.length === 0) continue

    var suffix = ""
    if (endsWith(line, " tracks")) suffix = " tracks"
    else if (endsWith(line, " track")) suffix = " track"
    else continue

    var head = line.slice(0, line.length - suffix.length)
    var cut = head.length
    while (cut > 0 && head.charAt(cut - 1) >= "0" && head.charAt(cut - 1) <= "9") cut--
    var count = parseInt(head.slice(cut), 10)
    var name = trim(head.slice(0, cut))
    if (name.length === 0 || !isFinite(count)) continue
    out.push({ name: clampText(name, MAX_TEXT_CHARS), count: count })
  }
  return out
}

// Sample input, what `omarchy bar set` stores without --json: the string "true", not a boolean.
function asBool(value, fallback) {
  if (value === true || value === false) return value
  if (value === "true") return true
  if (value === "false") return false
  return fallback
}

// The exact answer cliamp gives for a track it found no lyrics for, measured on the box.
var NO_LYRICS_ERROR = "no lyrics found"

// Sample input: {"ok":true,"state":"playing",..} {"ok":true,"lyrics":[..]} {"ok":true,"history":[..]} {"ok":true}
// Only a status carries state; parsing an ack as one blanks the track.
// One raw line in, one object out — or null for anything oversized, empty,
// unparsable or not an object. The size guard always runs before JSON.parse.
function parseObject(raw) {
  if (frameTooLarge(raw)) return null
  var text = String(raw || "").trim()
  if (text.length === 0) return null
  var data = null
  try {
    data = JSON.parse(text)
  } catch (e) {
    return null
  }
  return data && typeof data === "object" ? data : null
}

function messageKind(raw) {
  if (frameTooLarge(raw)) return "none"
  var text = String(raw || "").trim()
  if (text.length === 0) return "none"
  var data = null
  try {
    data = JSON.parse(text)
  } catch (e) {
    return "ack"
  }
  if (!data || typeof data !== "object") return "ack"
  if (data.providers !== undefined) return "providers"
  // provider.playlists is the only sender of a playlists field on this socket.
  if (data.playlists !== undefined) return "stations"
  // queue.list and every queue mutation answer with the track list; checked
  // before status because these replies carry index/total too. provider.tracks
  // replies look the same — the Service tells them apart by what it asked for.
  if (data.tracks !== undefined) return "queue"
  if (data.lyrics !== undefined) return "lyrics"
  // Matched whole: a command error that merely names a file cannot be swallowed as this.
  if (data.ok === false && String(data.error || "") === NO_LYRICS_ERROR) return "lyrics"
  if (data.history !== undefined) return "history"
  if (data.state !== undefined) return "status"
  return "ack"
}

// Sample input, a command reply that failed: {"ok":false,"error":"playlist not found"}
function ackError(raw) {
  if (frameTooLarge(raw)) return ""
  var data = null
  try {
    data = JSON.parse(String(raw || "").trim())
  } catch (e) {
    return ""
  }
  if (!data || typeof data !== "object" || data.ok !== false) return ""
  return elideError(String(data.error || ""))
}

// ---- cliamp 2.x: versioned envelopes, jobs, events ----
//
// cliamp 2.0 replaced the socket protocol outright. 1.x took bare
// {"cmd":"next"} lines and answered each one in place. 2.x takes only
// versioned envelopes, answers a state read directly and everything else with
// a job, and reports each finished job on an event stream. Measured on 2.4.1
// and read against docs/remote-control.md of that tag:
//
//   {"version":2,"id":"state","method":"state.get"}
//     -> {"version":2,"id":"state","ok":true,"snapshot":{"revision":7,"playlist_revision":3,
//         "state":"playing","track":{...},"position":1.37,"duration":90,"index":15,"total":16,...}}
//   {"version":2,"id":"next","method":"operation.submit","operation":"next","params":{}}
//     -> {"version":2,"id":"next","ok":true,"job":{"id":"4f57...","operation":"next","state":"queued"}}
//   {"version":2,"id":"events","method":"subscribe","topics":["runtime.state","runtime.job"]}
//     -> {"version":2,"id":"events","ok":true}, then one line per event:
//        {"event":"runtime.state","seq":93,"data":{...snapshot...}}
//        {"event":"runtime.job","seq":97,"data":{"type":"job.succeeded","job":{"id":"4f57...",
//          "operation":"queue.list","state":"succeeded","result":{...},"snapshot":{...}}}}
//   a failure: {"version":2,"ok":false,"error":{"code":"invalid_version","message":"..."}}
//
// The server writes these with Go's omitempty, so a zero is simply absent: no
// "volume" is 0 dB, no "index" is the first row, no "position" is 0 and no
// "tracks" is an empty list. Absence is never "unknown".

// The server's own ceiling for one page of queue.list or provider.tracks.
var V2_PAGE_SIZE = 200

var V2_STATE_REQUEST = '{"version":2,"id":"state","method":"state.get"}'
// runtime.state fires on every real change (never on position ticks), and
// runtime.job carries each job's final record — result and snapshot included.
var V2_SUBSCRIBE_REQUEST = '{"version":2,"id":"events","method":"subscribe","topics":["runtime.state","runtime.job"]}'

// The request id is echoed on the answer; the operation name is all the
// correlation a rejected request needs.
function v2Submit(operation, params) {
  return JSON.stringify({
    version: 2,
    id: String(operation),
    method: "operation.submit",
    operation: String(operation),
    params: params || {}
  })
}

// 1.x keeps the arguments beside the verb: {"cmd":"queue.move","index":2,"to":3}.
function v1Request(cmd, params) {
  var req = { cmd: String(cmd) }
  if (params) {
    for (var key in params) {
      if (key !== "cmd") req[key] = params[key]
    }
  }
  return JSON.stringify(req)
}

// Cheap test for "this line came from a 2.x daemon", used while a connection
// is in 1.x mode so its replies are not parsed twice. Go writes struct fields
// in declaration order: a response opens with version, an event with event.
function looksLikeV2(raw) {
  var head = String(raw || "").slice(0, 16)
  return head.indexOf('{"version":2') === 0 || head.indexOf('{"event":') === 0
}

function statusFromSnapshot(snap) {
  var out = defaultStatus()
  if (!snap || typeof snap !== "object") return out
  out.ok = true
  fillStatus(out, snap)
  // Absent means row 0 here, unless there are no rows at all.
  out.index = out.total > 0 ? Math.max(0, Math.floor(numberOr(snap.index, 0))) : -1
  out.revision = numberOr(snap.revision, 0)
  out.playlistRevision = numberOr(snap.playlist_revision, 0)
  return out
}

// {"code":"internal_error","message":"operation failed","detail":"no lyrics found"}
// The detail is the part a person can act on, so it wins when present.
function v2ErrorText(error) {
  if (!error || typeof error !== "object") return elideError(String(error || ""))
  return elideError(String(error.detail || error.message || error.code || ""))
}

// One line off a 2.x socket — a response or an event — as one of:
//   none      oversized, unparsable, or an event nobody here asked about
//   legacy    a JSON object without "version":2: a 1.x daemon answered
//   state     .status, from a state read or a runtime.state event
//   ack       a job was accepted and is not finished: .operation
//   job       a job's final record: .operation .ok .error .result .status
//   error     the request itself was refused: .id .code .message
//   ok        a bare acknowledgement (the subscription): .id
//   overflow  the event stream fell behind; the server closes it next
// .result is the server's own object, unbounded but for the frame cap: hand it
// to a *FromData / queuePageFromResult reader and keep none of it.
function parseV2Frame(raw) {
  var data = parseObject(raw)
  if (!data) return { kind: "none" }
  if (typeof data.event === "string") {
    if (data.event === "system.overflow") return { kind: "overflow" }
    var payload = data.data && typeof data.data === "object" ? data.data : null
    if (!payload) return { kind: "none" }
    if (data.event === "runtime.state") return { kind: "state", id: "", status: statusFromSnapshot(payload) }
    if (data.event === "runtime.job") return v2JobFrame(payload.job, "")
    return { kind: "none" }
  }
  if (data.version !== 2) return { kind: "legacy" }
  var id = clampText(data.id, MAX_TEXT_CHARS)
  if (data.ok !== true) {
    var code = data.error && typeof data.error === "object" ? clampText(data.error.code, MAX_TEXT_CHARS) : ""
    return { kind: "error", id: id, code: code, message: v2ErrorText(data.error) }
  }
  if (data.snapshot && typeof data.snapshot === "object") {
    return { kind: "state", id: id, status: statusFromSnapshot(data.snapshot) }
  }
  if (data.job !== undefined) return v2JobFrame(data.job, id)
  return { kind: "ok", id: id }
}

function v2JobFrame(job, id) {
  if (!job || typeof job !== "object") return { kind: "none" }
  var state = String(job.state || "")
  var out = { kind: "ack", id: id, operation: clampText(job.operation, MAX_TEXT_CHARS) }
  if (state !== "succeeded" && state !== "failed" && state !== "canceled") return out
  out.kind = "job"
  out.ok = state === "succeeded"
  out.error = out.ok ? "" : (v2ErrorText(job.error) || state)
  out.result = out.ok && job.result && typeof job.result === "object" ? job.result : null
  // A failed job changed nothing and carries no snapshot.
  out.status = job.snapshot && typeof job.snapshot === "object" ? statusFromSnapshot(job.snapshot) : null
  return out
}

// The operations whose result is the live queue: queue.list, and every
// mutation of it. provider.tracks and playnext.list also answer with "tracks",
// but those are other lists.
function isQueueOperation(operation) {
  var op = String(operation || "")
  return op === "queue" || op.indexOf("queue.") === 0 || op === "track.queue" || op === "track.play"
}

// 2.x answers queue.list — and every queue mutation — with one page of at
// most V2_PAGE_SIZE rows, the playing row's index and the size of the whole
// list: {"ok":true,"index":15,"total":316,"tracks":[{"title":"a","path":"/1"},
// {"title":"b","path":"/2","index":1}, ...]}. A row's own index is its place
// in the whole list, so the first row of a page says where the page starts.
function queuePageFromResult(result) {
  var out = { index: 0, total: 0, offset: 0, tracks: [] }
  if (!result || typeof result !== "object") return out
  var tracks = result.tracks && result.tracks.length !== undefined ? result.tracks : []
  out.index = Math.max(0, Math.floor(numberOr(result.index, 0)))
  if (tracks.length > 0 && tracks[0]) out.offset = Math.max(0, Math.floor(numberOr(tracks[0].index, 0)))
  out.tracks = queueRows(tracks)
  out.total = Math.max(Math.floor(numberOr(result.total, 0)), out.offset + out.tracks.length)
  return out
}

// Sample input, the reply to {"cmd":"lyrics"}, measured on the box:
// {"ok":true,"lyrics":[{"start":30.23,"text":"One more time"}]}
// A track with no lyrics answers {"ok":false,"error":"no lyrics found"} instead.
function parseLyrics(raw) {
  var data = parseObject(raw)
  return data && data.ok === true ? lyricsFromData(data) : []
}

// The rows of a lyrics answer, whichever envelope it travelled in.
function lyricsFromData(data) {
  var out = []
  if (!data || !data.lyrics || data.lyrics.length === undefined) return out
  for (var i = 0; i < data.lyrics.length && out.length < MAX_LIST_ITEMS; i++) {
    var line = data.lyrics[i]
    if (!line) continue
    var body = clampText(line.text, MAX_TEXT_CHARS)
    if (body.length === 0) continue
    out.push({ start: numberOr(line.start, 0), text: body })
  }
  return out
}

// Sample input, the reply to {"cmd":"queue.list"} (and to every queue mutation):
// {"ok":true,"total":29,"index":3,"tracks":[{"title":"...","artist":"...","album":"...",
//  "path":"https://...","duration_secs":214,"stream":false,"track_number":4}, ...]}
// index is omitted when 0, so missing means the first track.
function parseQueue(raw) {
  var data = parseObject(raw)
  if (!data || data.ok !== true || !data.tracks || data.tracks.length === undefined) {
    return { ok: false, index: 0, tracks: [] }
  }
  return { ok: true, index: numberOr(data.index, 0), tracks: queueRows(data.tracks) }
}

function queueRows(tracks) {
  var out = []
  if (!tracks || tracks.length === undefined) return out
  for (var i = 0; i < tracks.length && out.length < MAX_LIST_ITEMS; i++) {
    var t = tracks[i]
    if (!t) continue
    out.push({
      title: clampText(t.title, MAX_TEXT_CHARS),
      artist: clampText(t.artist, MAX_TEXT_CHARS),
      album: clampText(t.album, MAX_TEXT_CHARS),
      durationSec: numberOr(t.duration_secs, 0),
      isStream: t.stream === true
    })
  }
  return out
}

// The paths of a track list reply, in order — what the queue verb takes.
// count is how many rows the reply held, pathless ones included, because
// paging advances by rows.
function trackPaths(data) {
  var out = { paths: [], count: 0 }
  if (!data || !data.tracks || data.tracks.length === undefined) return out
  out.count = Math.min(data.tracks.length, MAX_LIST_ITEMS)
  for (var i = 0; i < out.count; i++) {
    var path = data.tracks[i] ? clampText(data.tracks[i].path, MAX_PATH_CHARS) : ""
    if (path.length > 0) out.paths.push(path)
  }
  return out
}

// Sample input, one integer of milliseconds from cliamp-output-latency: 167, or 0.
function latencyMs(raw) {
  var value = parseInt(String(raw || "").trim(), 10)
  return isFinite(value) && value > 0 ? value : 0
}

// The last line whose start has passed, scanned in order because the list is short.
function activeLyricIndex(lines, positionSec) {
  if (!lines || lines.length === undefined) return -1
  var at = numberOr(positionSec, 0)
  var found = -1
  for (var i = 0; i < lines.length; i++) {
    if (numberOr(lines[i].start, 0) > at) break
    found = i
  }
  return found
}

// cliamp only accepts these output rates, so a native rate outside the set cannot be
// played natively at all and must not be chased. 88.2 and 176.4 kHz are not in it.
var SUPPORTED_OUTPUT_RATES = [22050, 44100, 48000, 96000, 192000]

function isSupportedOutputRate(rate) {
  var value = numberOr(rate, 0)
  for (var i = 0; i < SUPPORTED_OUTPUT_RATES.length; i++) {
    if (SUPPORTED_OUTPUT_RATES[i] === value) return true
  }
  return false
}

// Sample input, one NDJSON frame from the bands command:
// {"ok":true,"visualizer":"Bars","bands":[0.93,0.81,...]}
function parseBands(raw) {
  var out = []
  // A spectrum frame is tens of bytes; anything big is not a spectrum frame.
  if (String(raw || "").length > MAX_VIS_FRAME_BYTES) return out
  var text = String(raw || "").trim()
  if (text.length === 0) return out
  var data = null
  try {
    data = JSON.parse(text)
  } catch (e) {
    return out
  }
  if (!data || data.ok !== true || !data.bands || data.bands.length === undefined) return out
  for (var i = 0; i < data.bands.length && out.length < MAX_BAND_COUNT; i++) {
    var v = numberOr(data.bands[i], 0)
    out.push(v < 0 ? 0 : (v > 1 ? 1 : v))
  }
  return out
}

// Fuzzy match, the way cliamp's own local search boxes match: the query characters
// only need to appear in order, not contiguously, and results are ranked. "skr" and
// "saku" both find "Sakura". Returns -1 for no match, higher is better.
function fuzzyScore(query, text) {
  var q = String(query || "").toLowerCase()
  var t = String(text || "").toLowerCase()
  if (q.length === 0) return 0
  var qi = 0
  var score = 0
  var streak = 0
  var last = -2
  for (var i = 0; i < t.length && qi < q.length; i++) {
    if (t.charAt(i) !== q.charAt(qi)) continue
    streak = last === i - 1 ? streak + 1 : 1
    // Runs of consecutive hits and word starts are what make a match feel right.
    score += 1 + streak * 2
    if (i === 0 || t.charAt(i - 1) === " ") score += 3
    last = i
    qi++
  }
  if (qi < q.length) return -1
  return score - Math.floor(t.length / 8)
}

// Rank rows by the best fuzzy score across their visible text.
function fuzzyFilter(rows, query) {
  var list = rows && rows.length !== undefined ? rows : []
  if (trim(query).length === 0) return list
  var scored = []
  for (var i = 0; i < list.length; i++) {
    var row = list[i]
    if (!row) continue
    var s = Math.max(
      fuzzyScore(query, row.name),
      fuzzyScore(query, String(row.artist || "") + " " + String(row.name || "")))
    if (s < 0) continue
    scored.push({ s: s, row: row })
  }
  scored.sort(function (a, b) { return b.s - a.s })
  var out = []
  for (var j = 0; j < scored.length; j++) out.push(scored[j].row)
  return out
}

// Sample input, one JSON array from `cliamp-library albums` or `search`, mixing kinds:
// [{"kind":"album","id":"7tO..","name":"Discovery","artist":"Daft Punk","songCount":14},
//  {"kind":"song","id":"a9F..","name":"One More Time","artist":"Daft Punk","album":"Discovery","duration":320}]
function parseResults(raw) {
  var out = []
  if (frameTooLarge(raw)) return out
  var text = String(raw || "").trim()
  if (text.length === 0) return out
  var data = null
  try {
    data = JSON.parse(text)
  } catch (e) {
    return out
  }
  if (!data || data.length === undefined) return out
  var kinds = { song: true, album: true, artist: true, radio: true, albumsong: true, yt: true, ytplaylist: true, info: true }
  for (var i = 0; i < data.length && out.length < MAX_LIST_ITEMS; i++) {
    var a = data[i]
    if (!a || !a.id) continue
    out.push({
      kind: kinds[a.kind] ? String(a.kind) : "album",
      // A radio or YouTube row's id IS its URL, so ids get the path budget.
      id: clampText(a.id, MAX_PATH_CHARS),
      name: clampText(a.name, MAX_TEXT_CHARS),
      artist: clampText(a.artist, MAX_TEXT_CHARS),
      album: clampText(a.album, MAX_TEXT_CHARS),
      albumId: clampText(a.albumId, MAX_PATH_CHARS),
      songCount: numberOr(a.songCount, 0),
      duration: numberOr(a.duration, 0)
    })
  }
  return out
}

// "r:" or "radio:" routes the query away from the Subsonic server, the closest
// this panel gets to cliamp's R key. A bare prefix lists the server's own
// configured stations; a prefix with a query searches the Radio Browser directory.
function isRadioMode(query) {
  var text = trim(query).toLowerCase()
  // ":r" tolerated as a typo of "r:" — fingers swap those often enough.
  return text.indexOf("r:") === 0 || text.indexOf("radio:") === 0
    || text.indexOf(":r") === 0 || text.indexOf(":radio") === 0
}

function radioQuery(query) {
  var text = trim(query)
  var lower = text.toLowerCase()
  if (lower.indexOf("radio:") === 0) return trim(text.slice(6))
  if (lower.indexOf(":radio") === 0) return trim(text.slice(6))
  if (lower.indexOf("r:") === 0) return trim(text.slice(2))
  if (lower.indexOf(":r") === 0) return trim(text.slice(2))
  return ""
}

// "yt:" sends the query to yt-dlp on the server — cliamp's own Ctrl+F fallback
// when no provider search applies. Bare "yt:" is just an empty query.
function isYtMode(query) {
  var text = trim(query).toLowerCase()
  return text.indexOf("yt:") === 0 || text.indexOf("youtube:") === 0
    || text.indexOf(":yt") === 0 || text.indexOf(":youtube") === 0
}

// "ytp:" asks for playlists instead of videos — YouTube's own "Type: Playlist"
// filter, which is where full-album uploads live. Checked before "yt:" since
// the shorter prefix does not match it anyway.
function isYtListMode(query) {
  var text = trim(query).toLowerCase()
  return text.indexOf("ytp:") === 0 || text.indexOf(":ytp") === 0
}

function ytListQuery(query) {
  var text = trim(query)
  var lower = text.toLowerCase()
  if (lower.indexOf("ytp:") === 0) return trim(text.slice(4))
  if (lower.indexOf(":ytp") === 0) return trim(text.slice(4))
  return ""
}

function ytQuery(query) {
  var text = trim(query)
  var lower = text.toLowerCase()
  if (lower.indexOf("youtube:") === 0) return trim(text.slice(8))
  if (lower.indexOf(":youtube") === 0) return trim(text.slice(8))
  if (lower.indexOf("yt:") === 0) return trim(text.slice(3))
  if (lower.indexOf(":yt") === 0) return trim(text.slice(3))
  return ""
}

// "p:" lists cliamp's own providers (Spotify, Jellyfin, Local, …) — whatever the
// server has configured — browsed through the generic provider.* socket verbs.
function isProviderMode(query) {
  var text = trim(query).toLowerCase()
  return text.indexOf("p:") === 0 || text.indexOf(":p") === 0
}

function providerQuery(query) {
  var text = trim(query)
  if (text.toLowerCase().indexOf("p:") === 0) return trim(text.slice(2))
  if (text.toLowerCase().indexOf(":p") === 0) return trim(text.slice(2))
  return ""
}

// Sample input, the reply to {"cmd":"provider.list"}:
// {"ok":true,"providers":[{"id":"radio","name":"Radio"},{"id":"local","name":"Local"}]}
function parseProviders(raw) {
  var data = parseObject(raw)
  return data && data.ok === true ? providersFromData(data) : []
}

// cliamp 1.x names a provider row's handle "id", 2.x "key"; both are read.
function providersFromData(data) {
  var out = []
  if (!data || !data.providers || data.providers.length === undefined) return out
  for (var i = 0; i < data.providers.length && out.length < MAX_LIST_ITEMS; i++) {
    var p = data.providers[i]
    if (!p) continue
    var key = clampText(p.key || p.id, MAX_TEXT_CHARS)
    var name = clampText(p.name || key, MAX_TEXT_CHARS)
    if (name.length === 0) continue
    out.push({
      kind: "provider",
      id: key.length > 0 ? key : name.toLowerCase(),
      name: name,
      artist: "", album: "", albumId: "", songCount: 0, duration: 0
    })
  }
  return out
}

// Sample input, the reply to {"cmd":"provider.playlists","provider":"radio"}:
// {"ok":true,"playlists":[{"id":"l:0","name":"cliamp radio","provider":"radio"},
//  {"id":"l:1","name":"Radio Paradise aac","provider":"radio"}, ...]}
// l: rows are radios.toml stations (l:0 the built-in list), f: rows favorites.
function parseStations(raw) {
  var data = parseObject(raw)
  return data && data.ok === true ? stationsFromData(data) : []
}

function stationsFromData(data) {
  var out = []
  if (!data || !data.playlists || data.playlists.length === undefined) return out
  for (var i = 0; i < data.playlists.length && out.length < MAX_LIST_ITEMS; i++) {
    var p = data.playlists[i]
    if (!p || !p.id) continue
    out.push({
      kind: "station",
      id: clampText(p.id, MAX_PATH_CHARS),
      name: clampText(p.name, MAX_TEXT_CHARS),
      artist: "", album: "", albumId: "", songCount: 0, duration: 0
    })
  }
  return out
}

// Which provider a playlists answer belongs to: every row names it. An empty
// list names nobody, and the caller falls back on who was waiting.
function playlistsProvider(data) {
  if (!data || !data.playlists || data.playlists.length === undefined) return ""
  for (var i = 0; i < data.playlists.length && i < MAX_LIST_ITEMS; i++) {
    if (data.playlists[i] && data.playlists[i].provider) return clampText(data.playlists[i].provider, MAX_TEXT_CHARS)
  }
  return ""
}

// Overwritten on every play, so it is plumbing rather than a playlist the user saved.
var SCRATCH_PLAYLIST = "cliampui"

// Saved playlists matched by name, as rows the same list can show. Fuzzy, ranked,
// the way cliamp's own `/` filter matches its local lists.
function matchPlaylists(playlists, query) {
  var rows = []
  var list = playlists && playlists.length !== undefined ? playlists : []
  for (var j = 0; j < list.length; j++) {
    var name = String(list[j] && list[j].name || "")
    if (name.length === 0) continue
    if (name === SCRATCH_PLAYLIST) continue
    rows.push({
      kind: "playlist",
      id: name,
      name: name,
      artist: "",
      album: "",
      songCount: numberOr(list[j].count, 0),
      duration: 0
    })
  }
  return fuzzyFilter(rows, query)
}

function trim(text) {
  return String(text || "").replace(/^\s+/, "").replace(/\s+$/, "")
}

function endsWith(text, suffix) {
  return text.length >= suffix.length && text.slice(text.length - suffix.length) === suffix
}

function formatRate(hz) {
  var rounded = Math.round(hz / 1000 * 10) / 10
  return String(rounded) + " kHz"
}

// The three conditions from the spec. "bit-perfect" is only ever said when all hold.
function verdict(v) {
  var input = v || {}
  var codec = String(input.codec || "")
  var streamRate = numberOr(input.streamRate, 0)
  var sinkRate = numberOr(input.sinkRate, 0)

  if (input.transcoded === true) {
    return { ok: false, text: (codec ? codec + " · " : "") + "transcoded by server" }
  }

  // A2DP re-encodes with SBC or AAC, both lossy, so a Bluetooth sink can never be
  // bit-perfect at any sample rate. Saying only "resampled" here would let someone
  // match rates and believe they had got there.
  var link = String(input.lossyLink || "")
  if (link.length > 0) {
    var lead = streamRate > 0 ? formatRate(streamRate) + " · " : ""
    return { ok: false, text: lead + link + " · lossy" }
  }
  if (streamRate <= 0 || sinkRate <= 0) {
    return { ok: false, text: "" }
  }

  // cliamp always outputs one fixed rate and resamples anything else internally,
  // before PipeWire can see it, so the file's own rate is the only thing that proves
  // the decode stage was clean. Unknown means the claim cannot be made.
  var sourceRate = numberOr(input.sourceRate, 0)
  if (sourceRate > 0 && Math.abs(sourceRate - streamRate) > RATE_MATCH_TOLERANCE_HZ) {
    return {
      ok: false,
      text: formatRate(sourceRate).replace(" kHz", "") + " → " + formatRate(streamRate)
        + " · cliamp resampled"
    }
  }

  var prefix = (codec ? codec + " " : "") + formatRate(streamRate)
  if (Math.abs(streamRate - sinkRate) > RATE_MATCH_TOLERANCE_HZ) {
    // Written as an arrow so the whole verdict stays on one line in the panel.
    var text = formatRate(streamRate).replace(" kHz", "") + " → " + formatRate(sinkRate) + " · resampled"
    // A rate was forced and the sink took a different one: the 88.2 to 96 case on the
    // internal DAC, or AirPods on SBC-XQ which hold the link at 48 kHz. Only then is
    // the output the thing to blame, which the requested rate is what distinguishes
    // from an ordinary unforced mismatch.
    var requested = numberOr(input.requestedRate, 0)
    if (requested > 0 && Math.abs(requested - sinkRate) > RATE_MATCH_TOLERANCE_HZ) {
      text = formatRate(streamRate).replace(" kHz", "") + " → " + formatRate(sinkRate)
        + " · output has no " + formatRate(requested).replace(" kHz", "")
    }
    return { ok: false, text: text }
  }
  if (input.eqFlat === false) {
    return { ok: false, text: prefix + " · EQ applied" }
  }
  if (input.unityGain === false || input.playerUnity === false) {
    // Named only when it is known which gain moved, because the panel can correct one.
    var stage = input.playerUnity === false ? "cliamp volume"
      : input.playerUnity === true ? "output volume" : "volume"
    return { ok: false, text: prefix + " · " + stage + " applied" }
  }
  // The claim needs the source rate, the gain, the EQ and the transcode flag all read.
  if (sourceRate <= 0 || input.unityGain !== true || input.eqFlat !== true || input.transcoded !== false) {
    return { ok: false, text: prefix + " · no resampling after cliamp" }
  }
  return { ok: true, text: prefix + " · bit-perfect" }
}

// Quickshell reports MPRIS position and length as doubles in seconds, not microseconds.
function formatTime(seconds) {
  var value = Number(seconds)
  if (!isFinite(value) || value < 0) value = 0
  var total = Math.floor(value)
  var secs = total % SECONDS_PER_MINUTE
  var minutes = Math.floor(total / SECONDS_PER_MINUTE) % MINUTES_PER_HOUR
  var hours = Math.floor(total / (SECONDS_PER_MINUTE * MINUTES_PER_HOUR))
  var ss = secs < 10 ? "0" + secs : String(secs)
  if (hours > 0) {
    var mm = minutes < 10 ? "0" + minutes : String(minutes)
    return hours + ":" + mm + ":" + ss
  }
  return minutes + ":" + ss
}

function elideError(raw) {
  var text = String(raw || "").replace(/\s+/g, " ").trim()
  if (text.length <= MAX_ERROR_CHARS) return text
  return text.slice(0, MAX_ERROR_CHARS)
}
