import QtQuick

// A thin client for a LedFx instance (https://ledfx.app): list virtuals and
// scenes, toggle a virtual, activate a scene. Plain HTTP(S) against the URL
// from settings — LedFx is a network service by design, so no ssh anywhere.
QtObject {
  id: root

  property string url: ""
  // [{id, name, active}] and [{id, name}], refreshed on demand.
  property var virtuals: []
  property var scenes: []
  property bool reachable: false

  // LedFx is a network peer like any other: its replies are bounded before they
  // are parsed, and the row/name caps below bound what is kept. A timeout alone
  // would not bound memory.
  readonly property int maxResponseChars: 1048576
  readonly property int maxRows: 200
  readonly property int maxNameChars: 256

  function _clamp(value) {
    var s = String(value || "")
    return s.length > maxNameChars ? s.slice(0, maxNameChars) : s
  }

  function _req(method, path, body, done) {
    if (url.length === 0) return
    var xhr = new XMLHttpRequest()
    xhr.timeout = 4000
    xhr.onreadystatechange = function () {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      var ok = xhr.status >= 200 && xhr.status < 300
      root.reachable = ok || root.reachable && xhr.status !== 0
      if (!ok) { if (xhr.status === 0) root.reachable = false; return }
      if (String(xhr.responseText || "").length > root.maxResponseChars) return
      var data = null
      try { data = JSON.parse(xhr.responseText) } catch (e) { data = null }
      if (done) done(data)
    }
    xhr.open(method, url.replace(/\/+$/, "") + path)
    if (body !== null) {
      xhr.setRequestHeader("Content-Type", "application/json")
      xhr.send(JSON.stringify(body))
    } else {
      xhr.send()
    }
  }

  function refresh() {
    _req("GET", "/api/virtuals", null, function (data) {
      var out = []
      var vs = data && data.virtuals ? data.virtuals : {}
      for (var vid in vs) {
        if (out.length >= root.maxRows) break
        var v = vs[vid] || {}
        // Dummy devices back mask/layer tricks; only real pixels are offered.
        if (v.is_device === false || String(vid).indexOf("-mask") >= 0
            || String(vid).indexOf("-foreground") >= 0
            || String(vid).indexOf("-background") >= 0) continue
        out.push({
          id: root._clamp(vid),
          name: root._clamp((v.config || {}).name || vid),
          active: v.active === true
        })
      }
      out.sort(function (a, b) { return a.name.localeCompare(b.name) })
      root.virtuals = out
      root.reachable = true
    })
    _req("GET", "/api/scenes", null, function (data) {
      var out = []
      var sc = data && data.scenes ? data.scenes : {}
      for (var sid in sc) {
        if (out.length >= root.maxRows) break
        out.push({ id: root._clamp(sid), name: root._clamp((sc[sid] || {}).name || sid) })
      }
      out.sort(function (a, b) { return a.name.localeCompare(b.name) })
      root.scenes = out
    })
  }

  function setVirtual(id, active) {
    _req("PUT", "/api/virtuals/" + encodeURIComponent(id), { active: active },
      function () { root.refresh() })
  }

  function toggleVirtual(id) {
    for (var i = 0; i < virtuals.length; i++) {
      if (virtuals[i].id === id) { setVirtual(id, !virtuals[i].active); return }
    }
  }

  function activateScene(id) {
    _req("PUT", "/api/scenes", { id: id, action: "activate" },
      function () { root.refresh() })
  }
}
