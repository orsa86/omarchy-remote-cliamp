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
