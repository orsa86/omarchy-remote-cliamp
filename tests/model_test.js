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

// ---- v2 protocol classification ----

;(function () {
  // A synced status snapshot at top level, as replied by runtime.status.
  var frame = '{"version":2,"ok":true,"snapshot":{"state":"playing","track":{"title":"T","artist":"A","path":"p","stream":true},"position":1.5,"total":12}}'
  assert(messageKind(frame) === "status", "messageKind snapshot envelope -> status")
  var s = parseStatus(frame)
  assert(s.ok === true && s.title === "T" && s.artist === "A" && s.state === "playing", "parseStatus v2 snapshot fields")
  assert(s.positionSec === 1.5 && s.total === 12, "parseStatus v2 position/total")
  assert(s.isStream === true, "parseStatus v2 track stream flag")
})()

;(function () {
  var ack = '{"version":2,"ok":true,"job":{"id":"j1","operation":"toggle","state":"queued"}}'
  assert(messageKind(ack) === "job", "messageKind queued -> job")
  var pa = parseJobAck(ack)
  assert(pa && pa.id === "j1" && pa.operation === "toggle", "parseJobAck fields")
  var running = '{"version":2,"ok":true,"job":{"id":"j1","operation":"lyrics","state":"running"}}'
  assert(messageKind(running) === "jobpoll", "messageKind running -> jobpoll")
  var done = '{"version":2,"ok":true,"job":{"id":"j1","operation":"queue.list","state":"succeeded","result":{"ok":true,"total":1,"tracks":[]},"snapshot":{"state":"paused"}}}'
  assert(messageKind(done) === "jobresult", "messageKind succeeded -> jobresult")
  var pr = parseJobResult(done)
  assert(pr && pr.state === "succeeded" && pr.result && pr.result.total === 1, "parseJobResult result")
  assert(pr.snapshot && pr.snapshot.state === "paused", "parseJobResult snapshot")
})()

;(function () {
  // v2 names the provider key field "key" instead of "id".
  var p1 = parseProviders('{"ok":true,"providers":[{"key":"yt","name":"YouTube (All)"},{"id":"radio","name":"Radio"}]}')
  assert(p1.length === 2, "parseProviders v2 row count")
  assert(p1[0].id === "yt", "parseProviders v2 reads key")
  assert(p1[1].id === "radio", "parseProviders v1 id still read")
})()

// A v2 queue row carries no index field; the Service derives it from the
// snapshot path. parseQueue must still hold the tracks in order.
;(function () {
  var q = parseQueue('{"ok":true,"total":2,"tracks":[{"title":"a","path":"/1"},{"title":"b","path":"/2"}]}')
  assert(q.ok && q.index === 0 && q.tracks.length === 2, "parseQueue v2 shape")
  assert(q.tracks[1].title === "b", "parseQueue v2 keeps order")
  assert(q.tracks[0].isStream === false, "parseQueue v2 default flags")
})()

console.log(checks + " checks, " + failures + " failures")
if (failures > 0) throw new Error(failures + " test failures")
console.log("OK")
