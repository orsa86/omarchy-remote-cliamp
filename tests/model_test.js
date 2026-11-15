// Tests for Model.js, run by tests/run — which concatenates Model.js in front of
// this file, because Model.js deliberately has no exports (it is a QML .js
// library). Plain asserts, no framework.

var failures = 0
var checks = 0

function assert(cond, label) {
  checks++
  if (cond) return
  failures++
  console.log("FAIL: " + label)
}

// ---- createLineAssembler ----

// Normal lines pass through, including ones split across chunk boundaries.
;(function () {
  var a = createLineAssembler(64)
  assert(JSON.stringify(a.feed("one\ntwo\n")) === '["one","two"]', "two whole lines")
  assert(JSON.stringify(a.feed("par")) === "[]", "partial line held")
  assert(JSON.stringify(a.feed("tial\nnext\n")) === '["partial","next"]', "line reassembled across chunks")
  assert(a.overflows === 0, "no overflow on normal traffic")
})()

// An unterminated flood never retains more than the ceiling and yields nothing.
;(function () {
  var a = createLineAssembler(1024)
  var chunk = new Array(257).join("x") // 256 bytes, no newline
  for (var i = 0; i < 1000; i++) {
    var lines = a.feed(chunk)
    assert(lines.length === 0, "flood yields no lines (iteration " + i + ")")
    assert(a.buffer.length <= 1024, "retained bytes within ceiling (iteration " + i + ")")
    if (lines.length !== 0 || a.buffer.length > 1024) break
  }
  assert(a.overflows === 1, "flood counted as one overflow")
  assert(a.skipping === true, "assembler in skip mode during flood")
})()

// After an oversized line, the stream resyncs at the next newline.
;(function () {
  var a = createLineAssembler(8)
  assert(JSON.stringify(a.feed("waytoolongline")) === "[]", "oversized partial dropped")
  assert(JSON.stringify(a.feed("stillgarbage\nok\n")) === '["ok"]', "resync at next newline")
  assert(a.overflows === 1, "overflow counted once")
  // An oversized line completed within one feed is also dropped and counted.
  assert(JSON.stringify(a.feed("anotherhugeline\ngood\n")) === '["good"]', "oversized complete line dropped")
  assert(a.overflows === 2, "second overflow counted")
})()

// Empty chunks and empty lines behave.
;(function () {
  var a = createLineAssembler(16)
  assert(JSON.stringify(a.feed("")) === "[]", "empty chunk")
  assert(JSON.stringify(a.feed("\n\n")) === '["",""]', "empty lines preserved")
})()

// ---- frame caps ----

;(function () {
  var big = new Array(MAX_FRAME_BYTES + 2).join("x")
  assert(frameTooLarge(big) === true, "frameTooLarge over cap")
  assert(frameTooLarge("small") === false, "frameTooLarge under cap")
})()

;(function () {
  var pad = new Array(MAX_VIS_FRAME_BYTES + 2).join("0")
  assert(parseBands('{"ok":true,"bands":[' + pad + "]}").length === 0, "parseBands drops oversized frame")
  var frame = parseBands('{"ok":true,"visualizer":"Bars","bands":[0.5,2,-1]}')
  assert(JSON.stringify(frame) === "[0.5,1,0]", "parseBands clamps band values")
  var many = parseBands('{"ok":true,"bands":[' + new Array(101).join("1,") + "1]}")
  assert(many.length === MAX_BAND_COUNT, "parseBands caps band count")
})()

;(function () {
  assert(clampText("abcdef", 3) === "abc", "clampText truncates")
  assert(clampText(null, 3) === "", "clampText null")
})()

// ---- cliamp 2.x protocol ----
// The frames below are the daemon's own, captured from cliamp 2.4.1.

;(function () {
  assert(V2_STATE_REQUEST === '{"version":2,"id":"state","method":"state.get"}', "v2 state request")
  var sub = JSON.parse(V2_SUBSCRIBE_REQUEST)
  assert(sub.version === 2 && sub.method === "subscribe" && sub.id === "events", "v2 subscribe envelope")
  assert(sub.topics.length === 2 && sub.topics[0] === "runtime.state" && sub.topics[1] === "runtime.job", "v2 subscribe topics")

  var move = JSON.parse(v2Submit("queue.move", { index: 2, to: 3 }))
  assert(move.version === 2 && move.method === "operation.submit", "v2Submit envelope")
  assert(move.operation === "queue.move" && move.id === "queue.move", "v2Submit names the operation and echoes it as id")
  assert(move.params.index === 2 && move.params.to === 3, "v2Submit keeps params nested")
  assert(JSON.parse(v2Submit("next")).params !== undefined, "v2Submit always sends params")

  assert(v1Request("status") === '{"cmd":"status"}', "v1Request bare verb")
  assert(v1Request("queue.move", { index: 2, to: 3 }) === '{"cmd":"queue.move","index":2,"to":3}', "v1Request flattens params")
  assert(JSON.parse(v1Request("queue", { cmd: "x", path: "/a" })).cmd === "queue", "v1Request params cannot replace the verb")
})()

;(function () {
  assert(looksLikeV2('{"version":2,"id":"state","ok":true}'), "looksLikeV2 response")
  assert(looksLikeV2('{"event":"runtime.state","seq":1}'), "looksLikeV2 event")
  assert(!looksLikeV2('{"ok":true,"state":"playing"}'), "looksLikeV2 rejects a 1.x status")
  assert(!looksLikeV2('{"ok":false,"error":"unknown command: "}'), "looksLikeV2 rejects a 1.x error")
  assert(!looksLikeV2(""), "looksLikeV2 empty")
})()

;(function () {
  // What a 1.x daemon answers to the 2.x probe, per its dispatch default.
  assert(parseV2Frame('{"ok":false,"error":"unknown command: "}').kind === "legacy", "1.x answer to the probe -> legacy")
  assert(parseV2Frame('{"ok":true,"state":"playing","volume":-6}').kind === "legacy", "1.x status -> legacy")
  // What a 2.x daemon answers to a 1.x request.
  var bad = parseV2Frame('{"version":2,"ok":false,"error":{"code":"invalid_version","message":"unsupported protocol version"}}')
  assert(bad.kind === "error" && bad.code === "invalid_version", "2.x refusal -> error with code")
  assert(bad.message === "unsupported protocol version", "2.x refusal message")
  assert(parseV2Frame("").kind === "none", "empty line -> none")
  assert(parseV2Frame("not json").kind === "none", "garbage -> none")
  assert(parseV2Frame("[1,2]").kind === "legacy", "a non-envelope JSON value -> legacy")
  assert(parseV2Frame('{"version":2,"id":"events","ok":true}').kind === "ok", "subscription ack -> ok")
  assert(parseV2Frame('{"version":2,"id":"events","ok":true}').id === "events", "ack keeps the request id")
  var big = '{"version":2,"ok":true,"pad":"' + new Array(MAX_FRAME_BYTES + 2).join("x") + '"}'
  assert(parseV2Frame(big).kind === "none", "oversized frame -> none")
})()

;(function () {
  // Playing row 15 of 16, volume at -6 dB.
  var playing = parseV2Frame('{"version":2,"id":"state","ok":true,"snapshot":{"revision":7,"playlist_revision":3,"state":"playing","track":{"title":"silence","path":"/run/user/1000/cliamp-probe/silence.wav","index":15},"position":1.374875283,"duration":90,"seekable":true,"volume":-6,"index":15,"total":16,"shuffle":false,"repeat":"Off","mono":false,"speed":1,"eq_preset":"Custom","eq_bands":[0,0,0,0,0,0,0,0,0,0],"visualizer":"Bars"}}')
  assert(playing.kind === "state" && playing.id === "state", "state reply -> state")
  var s = playing.status
  assert(s.ok === true && s.state === "playing" && s.title === "silence", "snapshot state and title")
  assert(s.positionSec === 1.374875283 && s.durationSec === 90, "snapshot position and duration")
  assert(s.index === 15 && s.total === 16, "snapshot index and total")
  assert(s.volumeDb === -6, "snapshot volume")
  assert(s.revision === 7 && s.playlistRevision === 3, "snapshot revisions")
  assert(s.eqFlat === true && s.repeat === "Off" && s.shuffle === false, "snapshot modes")

  // The same daemon stopped on row 0 at 0 dB: every zero is simply absent.
  var idle = parseV2Frame('{"version":2,"ok":true,"snapshot":{"revision":2,"playlist_revision":1,"state":"stopped","track":{"title":"Lofi","path":"https://radio.cliamp.stream/lofi/stream","stream":true,"realtime":true},"seekable":false,"total":15,"shuffle":false,"repeat":"Off"}}').status
  assert(idle.volumeDb === 0, "absent volume is 0 dB")
  assert(idle.index === 0, "absent index is the first row")
  assert(idle.positionSec === 0 && idle.durationSec === 0, "absent position and duration are 0")
  assert(idle.isStream === true && idle.state === "stopped", "snapshot stream flag")

  var empty = parseV2Frame('{"version":2,"ok":true,"snapshot":{"revision":1,"state":"stopped"}}').status
  assert(empty.ok === true && empty.index === -1 && empty.total === 0, "empty playlist has no playing row")
  assert(empty.playlistRevision === 0, "absent playlist revision is 0")

  var pushed = parseV2Frame('{"event":"runtime.state","seq":93,"time":1794761883,"data":{"revision":17,"playlist_revision":7,"state":"paused","track":{"title":"NCS Chill","path":"https://radio.cliamp.stream/ncs-chill/stream","index":14,"stream":true},"index":14,"total":15,"volume":-12}}')
  assert(pushed.kind === "state" && pushed.status.state === "paused", "runtime.state event -> state")
  assert(pushed.status.volumeDb === -12 && pushed.status.revision === 17, "runtime.state event fields")
  assert(parseV2Frame('{"event":"runtime.state","seq":1}').kind === "none", "event without data -> none")
  assert(parseV2Frame('{"event":"plugin.x.y","seq":1,"data":{}}').kind === "none", "unknown event -> none")
  assert(parseV2Frame('{"event":"system.overflow","seq":9,"data":{"resync_required":true}}').kind === "overflow", "overflow event")
})()

;(function () {
  var ack = parseV2Frame('{"version":2,"id":"queue.list","ok":true,"job":{"id":"4f57790c010cf438fadc55a5009b01fd","operation":"queue.list","state":"queued","created_at":"2026-11-15T16:55:59.973419367Z"}}')
  assert(ack.kind === "ack" && ack.operation === "queue.list" && ack.id === "queue.list", "queued job -> ack")
  assert(parseV2Frame('{"version":2,"ok":true,"job":{"id":"a","operation":"lyrics","state":"running"}}').kind === "ack", "running job -> ack")

  var done = parseV2Frame('{"event":"runtime.job","seq":97,"time":1794761883,"data":{"type":"job.succeeded","job":{"id":"a936e5243b825f037b337a8189487d70","operation":"queue.move","state":"succeeded","result":{"ok":true,"index":14,"total":15,"tracks":[{"title":"Lofi","path":"https://radio.cliamp.stream/lofi/stream","stream":true},{"title":"Meditative","path":"https://radio.cliamp.stream/meditative/stream","index":1,"stream":true}]},"snapshot":{"revision":18,"playlist_revision":8,"state":"stopped","index":14,"total":15}}}}')
  assert(done.kind === "job" && done.ok === true && done.operation === "queue.move", "job.succeeded event -> job")
  assert(done.error === "", "succeeded job has no error")
  assert(done.status && done.status.playlistRevision === 8 && done.status.index === 14, "job carries its snapshot")
  var page = queuePageFromResult(done.result)
  assert(page.index === 14 && page.total === 15 && page.offset === 0, "queue page header")
  assert(page.tracks.length === 2 && page.tracks[1].title === "Meditative" && page.tracks[0].isStream === true, "queue page rows")

  // job.get answers with the same record, were it ever polled.
  var polled = parseV2Frame('{"version":2,"id":"job","ok":true,"job":{"id":"ef4d","operation":"volume","state":"succeeded","result":{"ok":true,"volume":-6},"snapshot":{"revision":3,"playlist_revision":1,"state":"stopped","volume":-6,"total":15}}}')
  assert(polled.kind === "job" && polled.status.volumeDb === -6, "polled job record -> job")

  var miss = parseV2Frame('{"event":"runtime.job","seq":103,"time":1794761885,"data":{"type":"job.failed","job":{"id":"d96c","operation":"lyrics","state":"failed","error":{"code":"internal_error","message":"operation failed","detail":"no lyrics found"}}}}')
  assert(miss.kind === "job" && miss.ok === false && miss.operation === "lyrics", "job.failed event -> failed job")
  assert(miss.error === "no lyrics found", "a failure reports its detail")
  assert(miss.result === null && miss.status === null, "a failed job has neither result nor snapshot")
  var refused = parseV2Frame('{"version":2,"ok":true,"job":{"id":"f182","operation":"queue.play","state":"failed","error":{"code":"invalid_params","message":"invalid parameters"}}}')
  assert(refused.error === "invalid parameters", "a failure without detail reports its message")
  assert(parseV2Frame('{"event":"runtime.job","seq":1,"data":{"type":"job.canceled","job":{"id":"c","operation":"lyrics","state":"canceled"}}}').error === "canceled", "a canceled job names its state")

  assert(parseV2Frame('{"version":2,"ok":true,"job":null}').kind === "none", "null job does not throw")
  assert(parseV2Frame('{"event":"runtime.job","seq":1,"data":{"type":"job.succeeded"}}').kind === "none", "job event without a job")
  assert(parseV2Frame('{"version":2,"ok":true,"job":{"id":"x","operation":"queue.list","state":"succeeded","result":"nope"}}').result === null, "a non-object result is dropped")
})()

;(function () {
  assert(isQueueOperation("queue") && isQueueOperation("queue.list") && isQueueOperation("queue.remove"), "queue operations")
  assert(isQueueOperation("track.queue") && isQueueOperation("track.play"), "track operations answer with the queue")
  assert(!isQueueOperation("provider.tracks") && !isQueueOperation("playnext.list") && !isQueueOperation("lyrics"), "other track lists are not the queue")

  // A continuation page: its first row says where it starts.
  var later = queuePageFromResult({ ok: true, index: 3, total: 316, tracks: [{ title: "c", path: "/201", index: 200 }, { title: "d", path: "/202", index: 201 }] })
  assert(later.offset === 200 && later.total === 316 && later.index === 3 && later.tracks.length === 2, "queue continuation page")
  // An empty queue: tracks, index and total are all absent.
  var none = queuePageFromResult({ ok: true })
  assert(none.offset === 0 && none.total === 0 && none.tracks.length === 0 && none.index === 0, "empty queue page")
  // A page past the end of the list: no rows, but a total.
  var past = queuePageFromResult({ ok: true, index: 2, total: 40 })
  assert(past.tracks.length === 0 && past.total === 40, "page past the end")
  assert(queuePageFromResult(null).total === 0 && queuePageFromResult("x").tracks.length === 0, "queue page from junk")
  assert(queuePageFromResult({ total: 1, tracks: [{ title: "a" }, { title: "b" }] }).total === 2, "total never undercounts the rows in hand")
})()

;(function () {
  var got = trackPaths({ ok: true, playlist: "l:0", total: 3, tracks: [{ title: "a", path: "https://a/stream" }, { title: "nopath" }, null, { path: "/b" }] })
  assert(got.count === 4 && got.paths.length === 2, "trackPaths counts rows, keeps paths")
  assert(got.paths[0] === "https://a/stream" && got.paths[1] === "/b", "trackPaths order")
  assert(trackPaths(null).count === 0 && trackPaths({}).paths.length === 0, "trackPaths from junk")

  // 2.x names the provider handle "key"; 1.x named it "id".
  var provs = providersFromData({ ok: true, providers: [{ key: "cliamp", name: "cliamp radio", searchable: false }, { key: "radio", name: "Radio" }, { id: "local", name: "Local" }] })
  assert(provs.length === 3 && provs[0].id === "cliamp" && provs[1].id === "radio", "providersFromData reads key")
  assert(provs[2].id === "local", "providersFromData still reads id")
  assert(parseProviders('{"ok":true,"providers":[{"id":"radio","name":"Radio"}]}')[0].id === "radio", "parseProviders 1.x reply")
  assert(providersFromData({ ok: true }).length === 0, "absent providers is an empty list")

  var lists = { ok: true, total: 2, playlists: [{ id: "loc:ask", name: "Use my location", provider: "radio" }, { id: "l:0", name: "cliamp radio", provider: "radio" }] }
  assert(playlistsProvider(lists) === "radio", "playlistsProvider reads the rows")
  assert(playlistsProvider({ ok: true }) === "" && playlistsProvider(null) === "", "an empty playlists answer names nobody")
  assert(stationsFromData(lists).length === 2 && stationsFromData(lists)[1].id === "l:0", "stationsFromData rows")

  assert(lyricsFromData({ ok: true, lyrics: [{ start: 15.66, text: "one" }, { start: 19.56, text: "" }] }).length === 1, "lyricsFromData drops blank lines")
  assert(lyricsFromData(null).length === 0 && lyricsFromData({ ok: true }).length === 0, "lyricsFromData from nothing")
})()

console.log(checks + " checks, " + failures + " failures")
if (failures > 0) throw new Error(failures + " test failures")
console.log("OK")

// ---- YouTube mode ("yt:") ----

;(function () {
  assert(isYtMode("yt: metallica") === true, "yt: prefix detected")
  assert(isYtMode("YouTube: x") === true, "youtube: prefix, any case")
  assert(isYtMode(":yt x") === true, ":yt typo tolerated")
  assert(isYtMode("yt") === false, "bare yt without colon is a library query")
  assert(isYtMode("r: yt") === false, "radio query mentioning yt stays radio")
  assert(ytQuery("yt:  nothing else matters ") === "nothing else matters", "yt query trimmed")
  assert(ytQuery("youtube:enter sandman") === "enter sandman", "youtube: query stripped")
  assert(ytQuery("yt:") === "", "bare prefix is an empty query")
  assert(isRadioMode("yt: radio") === false, "yt mode is not radio mode")
})()

// A yt row from the helper keeps its kind and its page URL as the id.
;(function () {
  var rows = parseResults(JSON.stringify([
    { kind: "yt", id: "https://www.youtube.com/watch?v=abc123", name: "Song", artist: "Uploader", duration: 245 },
    { kind: "yt", id: "", name: "no url" }
  ]))
  assert(rows.length === 1, "row without an id dropped")
  assert(rows[0].kind === "yt", "yt kind preserved")
  assert(rows[0].id === "https://www.youtube.com/watch?v=abc123", "page URL kept as id")
  assert(rows[0].duration === 245, "duration carried")
})()

// ---- YouTube playlist mode ("ytp:") ----

;(function () {
  assert(isYtListMode("ytp: black album") === true, "ytp: prefix detected")
  assert(isYtListMode(":ytp x") === true, ":ytp typo tolerated")
  assert(isYtListMode("yt: black album") === false, "yt: is not playlist mode")
  assert(isYtMode("ytp: black album") === false, "ytp: is not video mode")
  assert(ytListQuery("ytp:  black album ") === "black album", "ytp query trimmed")
  assert(ytListQuery("ytp:") === "", "bare ytp: is empty")
  var rows = parseResults(JSON.stringify([
    { kind: "ytplaylist", id: "https://www.youtube.com/playlist?list=PLx", name: "Black Album", artist: "someone", songCount: 12 }
  ]))
  assert(rows.length === 1 && rows[0].kind === "ytplaylist", "ytplaylist kind preserved")
  assert(rows[0].songCount === 12, "playlist count carried")
})()

// An info row from the helper (e.g. "yt-dlp missing…") survives parseResults as an inert row.
;(function () {
  var rows = parseResults(JSON.stringify([{ kind: "info", id: "!", name: "yt-dlp missing on this machine and on host" }]))
  assert(rows.length === 1 && rows[0].kind === "info", "info kind preserved")
})()
