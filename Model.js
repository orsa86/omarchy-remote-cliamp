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

function frameTooLarge(raw) {
  return String(raw || "").length > MAX_FRAME_BYTES
}

function clampText(value, max) {
  var s = String(value || "")
  return s.length > max ? s.slice(0, max) : s
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

  out.state = clampText(data.state || "stopped", MAX_TEXT_CHARS)
  out.volumeDb = numberOr(data.volume, 0)
  out.total = numberOr(data.total, 0)
  out.index = numberOr(data.index, -1)
  out.shuffle = data.shuffle === true
  out.repeat = clampText(data.repeat || "Off", MAX_TEXT_CHARS)
  out.visualizer = clampText(data.visualizer, MAX_TEXT_CHARS)
  out.eqFlat = bandsAreFlat(data.eq_bands)

  out.durationSec = numberOr(data.duration, 0)
  out.positionSec = numberOr(data.position, 0)

  var track = data.track
  if (track && typeof track === "object") {
    out.title = clampText(track.title, MAX_TEXT_CHARS)
    out.path = clampText(track.path, MAX_PATH_CHARS)
    out.artist = clampText(track.artist, MAX_TEXT_CHARS)
    out.album = clampText(track.album, MAX_TEXT_CHARS)
    out.isStream = track.stream === true
    if (out.durationSec <= 0) out.durationSec = numberOr(track.duration_secs, 0)
  }
  return out
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

// Sample input, the reply to {"cmd":"lyrics"}, measured on the box:
// {"ok":true,"lyrics":[{"start":30.23,"text":"One more time"}]}
// A track with no lyrics answers {"ok":false,"error":"no lyrics found"} instead.
function parseLyrics(raw) {
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
  if (!data || data.ok !== true || !data.lyrics || data.lyrics.length === undefined) return out
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
  var out = { ok: false, index: 0, tracks: [] }
  if (frameTooLarge(raw)) return out
  var data = null
  try {
    data = JSON.parse(String(raw || "").trim())
  } catch (e) {
    return out
  }
  if (!data || data.ok !== true || !data.tracks || data.tracks.length === undefined) return out
  out.ok = true
  out.index = numberOr(data.index, 0)
  for (var i = 0; i < data.tracks.length && out.tracks.length < MAX_LIST_ITEMS; i++) {
    var t = data.tracks[i]
    if (!t) continue
    out.tracks.push({
      title: clampText(t.title, MAX_TEXT_CHARS),
      artist: clampText(t.artist, MAX_TEXT_CHARS),
      album: clampText(t.album, MAX_TEXT_CHARS),
      durationSec: numberOr(t.duration_secs, 0),
      isStream: t.stream === true
    })
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
  if (String(raw || "").length > 4096) return out
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
  var kinds = { song: true, album: true, artist: true, radio: true, albumsong: true }
  for (var i = 0; i < data.length && out.length < MAX_LIST_ITEMS; i++) {
    var a = data[i]
    if (!a || !a.id) continue
    out.push({
      kind: kinds[a.kind] ? String(a.kind) : "album",
      // A radio row's id IS its stream URL, so ids get the path budget.
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
  var out = []
  if (frameTooLarge(raw)) return out
  var data = null
  try {
    data = JSON.parse(String(raw || "").trim())
  } catch (e) {
    return out
  }
  if (!data || data.ok !== true || !data.providers || data.providers.length === undefined) return out
  for (var i = 0; i < data.providers.length && out.length < MAX_LIST_ITEMS; i++) {
    var p = data.providers[i]
    if (!p) continue
    var name = clampText(p.name || p.id, MAX_TEXT_CHARS)
    if (name.length === 0) continue
    out.push({
      kind: "provider",
      id: clampText(p.id || name.toLowerCase(), MAX_TEXT_CHARS),
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
  var out = []
  if (frameTooLarge(raw)) return out
  var data = null
  try {
    data = JSON.parse(String(raw || "").trim())
  } catch (e) {
    return out
  }
  if (!data || data.ok !== true || !data.playlists || data.playlists.length === undefined) return out
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
