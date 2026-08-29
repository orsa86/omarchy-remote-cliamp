# Audiobookshelf + YouTube for Remote Cliamp — analysis and plan

Written 2026-08-29 against omarchy-cliampui v0.1.11 (upstream), remote-cliamp
v0.3.2 (this repo), cliamp v1.63.2 (installed, latest stable) and cliamp
`main` / v2.0.0-rc.2 (2026-08-26).

## 1. Upstream vs this fork

| | omarchy-cliampui (thisisgm) | omarchy-remote-cliamp (orsa) |
| --- | --- | --- |
| Size | ~3.1k lines, 9 QML + Model.js + `cliamp-library` | ~5.1k lines, 17 QML + Model.js + `remote-cliamp-library` |
| Player location | localhost only | N servers over `ssh -N -L` socket tunnel + ControlMaster, plus a no-ssh `local` |
| Reason to exist | bit-perfect verdict: sink rate readback, level meter, per-app output routing, rate following | control players in other rooms; one panel, live picker, heartbeat per server |
| IPC verbs used (v1 `{"cmd":…}`) | 7: toggle, next, prev, seek, status, lyrics, load | 24: + volume, queue.list/play/remove/move, provider.list/playlists/tracks/load, queue (path), play |
| Library | Subsonic search3 with borrowed token, songs + albums + saved playlists, scratch playlist `cliampui` | same token trick from remote status, plus artist → album → track drill-down, fuzzy playlist match, Radio Browser (`r:`), generic provider browse (`p:`) |
| Queue view | none | full: mark, jump, remove, reorder |
| Volume | PipeWire stream volume | dB gain over socket (remote) / PipeWire (local) |
| Extras | systemd user unit (sandboxed), `foot` launcher, MPRIS art | LedFx lights, help sheet, `omarchy-shell remote-cliamp …` IPC, hard byte/row caps on every peer reply |
| Lost in the fork | signal verdict, meter, routing, rate follow, measured lyric latency | — |

Both fork lines share the same shape: QML panel → NDJSON on the cliamp socket →
Python helper for what the socket cannot do (Subsonic HTTP, playlist delivery).
This fork already has the generic `provider.*` browse path (`enterProvider`,
`playProviderPlaylist`, `queueProviderPlaylist` in `Service.qml:490-560`) —
that is the hook both new features hang off.

## 2. What cliamp offers

### YouTube

- Providers `yt` (All), `youtube` (Video), `ytmusic` (Music). Registered in
  `main.go` only when credentials exist: `[ytmusic] client_id/client_secret`
  (1.63.2), or `[ytmusic] cookies_from = "firefox"` zero-OAuth (2.0 only,
  PR #314). The built-in fallback credential pool is **empty** in the release
  binary — that is why `provider.list` on this machine shows only
  radio/local/navidrome.
- Search: `provider.search {provider:"yt", query, limit ≤100}` → tracks with
  `path = https://music.youtube.com/watch?v=…`, `stream: true`. Playback
  resolves through **yt-dlp on the server** (`/usr/bin/yt-dlp` here,
  2026.08.19). Nothing on the panel side touches YouTube.
- Playlists / Liked Music: `provider.playlists` + `provider.tracks` — the
  existing `p:` browse already covers them once the provider is enabled.

### Audiobookshelf

- **Not in 1.63.2.** Lives on `main` (`external/audiobookshelf/provider.go`,
  723 lines, last touched 2026-08-26) → ships with **cliamp 2.0**.
- Config on the server: `[audiobookshelf] url, token | user+password, libraries`.
- Implements: `Playlists()` (books, then podcast shows), `Tracks()` (one track
  per audio file, chapter name as title when a file is one chapter),
  `SearchTracks()`, `Artists()` = authors, `AlbumList()` = titles
  (sort: title / recently added / author), `TrackPosition` + `ReportProgress`
  (sync on start, every 15 s, on end; "finished" within 5 s of the end),
  `ResumeTarget()` — **resume applies only on `provider.load`**, not on
  `track.play` from a search result.
- `speed` (0.25–2.0) already exists as an IPC op in both versions.

### The catch: IPC v2 only

v2.0.0-rc.2 changelog: *"feat(ipc): make remote control v2-only"*. `main`'s
`ipc/server.go` answers any unversioned frame with `invalid_version`. Every
`{"cmd":…}` this plugin sends stops working the day a server runs cliamp 2.0.
So ABS support = IPC v2 support, and v2 support is needed anyway to survive
the next cliamp release.

v2 shape (docs/remote-control.md):

```json
{"version":2,"id":"s1","method":"state.get"}
{"version":2,"id":"p1","method":"operation.submit","operation":"provider.search","params":{"provider":"yt","query":"metallica","limit":25}}
{"version":2,"id":"ev","method":"subscribe","topics":["runtime.state","runtime.playlist","runtime.job"]}
```

`operation.submit` returns a `job` (`queued|running|succeeded|failed|canceled`);
slow ops (provider access, yt-dlp resolution, lyrics) finish asynchronously and
the final record arrives on `runtime.job` or via `job.get`. Responses echo the
request `id`. Frames still ≤ 1 MiB; paging via `offset`/`limit`. Legacy CLI
(`cliamp status --json`, `cliamp load`, `cliamp visstream`) survives, so the
Python helper and the spectrum stream need no change.

## 3. Plan

> **Status 2026-08-29:** YouTube shipped a different way than Phase 3 below —
> no cliamp provider at all. `yt:` / `ytp:` enumerate through yt-dlp on the
> desktop (`ytsearchN:` / YouTube's playlist filter), play through the
> server's yt-dlp (`load` of a scratch playlist, `track.queue` for queueing).
> Works on 1.63.2, no credentials. Phases 0/1/2/4 (IPC v2, Audiobookshelf)
> still open.

Order matters: 1 is a prerequisite for 3 and for staying alive; 2 is shared by
3 and 4.

### Phase 0 — verify on a throwaway box (½ day)

1. Install rc.2 on a test host (`cliamp upgrade` has a prerelease channel;
   or `go build` from the tag). Keep 1.63.2 on production servers.
2. `cliamp remote capabilities`; confirm a raw `{"cmd":"status"}` fails with
   `invalid_version`.
3. Add `[audiobookshelf]` and `[ytmusic] cookies_from` to that host's
   config, `cliamp remote call provider.list`, then `provider.search` for both,
   `provider.load` on a book, watch the ABS web UI move the progress bar.
4. Record the exact JSON of: state.get snapshot, provider.search tracks,
   provider.playlists for ABS (section headers?), a failed job. These become
   fixtures in `tests/model_test.js`.

### Phase 1 — IPC v2 in the panel (2–3 days) — largest chunk

Files: `Service.qml`, `Model.js`, `tests/model_test.js`.

- **Version probe per server.** On tunnel-up send v2 `state.get`; on
  `invalid_version`/`unknown command` fall back to v1. Store `ipcVersion` in
  the server record so the picker can show it. Dual-stack until 2.0 is GA and
  the README says ">= 2.0", then delete v1.
- **Request ids instead of pending flags.** Today replies are routed by
  guessing which question is outstanding (`_stationQueuePending`,
  `_provListsPending`, `_queueSeen` …). v2 echoes `id`; build one
  `send(method, params, onReply)` with a bounded id → callback map and a
  per-request timeout. This removes the 5 s `stationsTimeout` class of bugs.
- **Jobs.** `operation.submit` → keep `job.id`; resolve the callback from the
  `runtime.job` event (or `job.get` after a timeout). Surface job state in the
  UI: a search row shows "resolving…" while yt-dlp works.
- **Snapshot parser.** `Model.parseSnapshot()` mapping `snapshot.state`,
  `position`, `duration`, `seekable`, `track.*`, `revision` onto the same
  `status` object `parseStatus()` produces, so NowPlaying/Transport stay
  untouched.
- **Events replace polling.** Second socket connection per active server
  subscribed to `runtime.state`, `runtime.playlist`; drop the 2 s poll for v2
  servers (keep the 10 s heartbeat). Handle `system.overflow` → reconnect +
  `state.get`. This is optional for feature parity but free once ids exist.
- **Op map v1 → v2**: `status→state.get`, `queue(path)→track.queue`,
  `queue.play/remove/move` unchanged names (send `if_revision` from the last
  snapshot to get `conflict` instead of acting on a stale list), `load`,
  `provider.*` unchanged names, `volume/seek/speed` unchanged.
- Tests: envelope builder, id router, snapshot parser, job-state machine, cap
  enforcement on v2 frames.

### Phase 2 — provider-scoped search (1 day)

Files: `Service.qml`, `Model.js`, `Library.qml`, `Help.qml`.

- `provider.list` already returns `searchable`, `catalog`, `browse_artists`,
  `browse_albums`. Keep them on each provider row.
- Search scope prefix like the existing `r:` / `p:`: `yt:`, `ab:`, and a
  generic `<key>:` for any searchable provider. `Tab` in the field cycles
  scope. Default scope stays Subsonic (fast, no server round trip).
- Rows from `provider.search` reuse the existing track-row shape (title,
  artist, album, duration). `Enter` → `track.play`, `a`/`q` → `track.queue`.
  These carry `provider_meta`, which is what lets ABS report progress — the
  v1 `queue {path}` path would strip it.
- Paging: `limit 25`, "more…" row sends `offset`.

### Phase 3 — YouTube (½ day on top of Phase 2)

- Scope `yt:`; show the "resolving" job state; treat `path` as non-seekable
  until the snapshot says `seekable: true`.
- README: server-side config (`[ytmusic] cookies_from` on 2.0,
  `client_id/secret` on 1.63.2), `yt-dlp` must be on the server, and the note
  that audio still never crosses the wire.
- Works on 1.63.2 as well once creds exist — ship this before Phase 1 if you
  want YouTube now: the v1 `provider.search` call is identical, and
  `queue {path}` plays a `watch?v=` URL.

### Phase 4 — Audiobookshelf (1–2 days)

Files: new `AudiobookList.qml`, `Transport.qml`, `Service.qml`, `Help.qml`,
`manifest.json` (no new settings — credentials stay on the server).

- **BOOKS section**, key `B`: `provider.playlists provider=audiobookshelf`
  rendered as two groups (books / podcasts, the order the provider returns).
  `Enter` = `provider.load` + `play` → cliamp resumes at the server-side
  position. `q` = `provider.tracks` → enqueue. Right side of each row: last
  progress if the playlist info carries it; otherwise nothing (don't fake it).
- **Search** `ab:` from Phase 2 — but for a book hit, `Enter` should
  `provider.load` the *book* (id from `provider_meta`) then `queue.play` the
  matching file index, so resume still applies; plain `track.play` skips
  ResumeTarget.
- **Transport for spoken word**, only while the playing track's
  `provider_meta` is ABS: `h`/`l` seek ±30 s instead of ±5, `<`/`>` =
  `speed.adjust` ±0.1 shown as `1.25×` next to the time, `0` resets.
  Chapters = the queue rows (one file per chapter in most rips) — the QUEUE
  section already gives jump/next chapter.
- Nothing to do for progress: the server syncs. Document that resume works
  from BOOKS, not from a queued track.
- Optional later: authors/titles drill-down via `provider.artists` /
  `provider.albums sort=recent`, same drill-down code as Navidrome artists.

### Phase 5 — docs, screenshots, release (½ day)

README sections (YouTube, Audiobooks, keys, "cliamp version" table: 1.63 →
v1 + YouTube; 2.0 → v2 + ABS), manifest bump to 0.4.0, new shots in `docs/`.

## 4. Risks

- 2.0 is rc: op names or snapshot fields may still move. Keep fixtures from
  Phase 0 and rerun the model tests against each rc.
- yt-dlp breaks periodically; failures arrive as `failed` jobs with a
  `detail` string — show it, don't retry in a loop.
- YouTube cookies on a headless server: `cookies_from` reads a browser
  profile on that box; a server without a browser needs `client_id/secret`
  or a cookies file. Document both.
- Second socket for events doubles tunnel channels; the ControlMaster handles
  it, but the local `sshTarget` path must open a second unix connection too.
- Dropping the 2 s poll changes the "server unreachable" signal; keep the
  heartbeat as the liveness source of truth.

## 5. Sources

- cliamp source v1.63.2 (`main.go:141-176`, `ui/model/ipc_extended.go:264`,
  `daemon.go`), `main` (`external/audiobookshelf/provider.go`, `ipc/server.go`)
- https://github.com/bjarneo/cliamp/blob/main/docs/remote-control.md
- https://github.com/bjarneo/cliamp/blob/main/docs/upgrading-ipc-v2.md
- https://github.com/bjarneo/cliamp/blob/main/docs/audiobookshelf.md
- https://github.com/bjarneo/cliamp/blob/main/docs/youtube-music.md
- https://github.com/bjarneo/cliamp/releases/tag/v2.0.0-rc.2
- https://github.com/thisisgm/omarchy-cliampui
