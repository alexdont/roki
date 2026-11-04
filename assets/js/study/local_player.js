// The player that does the work on this device: the release is read straight from its URL
// with byte ranges (or through the server's byte relay, for a host that forbids cross-origin
// reads), taken apart here, its video copied as it is, its audio carried as it is when the
// media engine takes that codec in MP4, else decoded here — by the browser (FLAC, …) or by
// the Dolby/DTS decoder in WebAssembly — and re-encoded, and written as fragmented MP4 into a
// MediaSource buffer that the <video> plays. The server never touches the bytes.
//
// Mediabunny (MPL-2.0) and the decoder are loaded the first time they are needed, like hls.js.
//
// The timeline is the film's own: fragments are placed at their real time (timestampOffset),
// `duration` is the whole film, so the seek bar is the whole film. A seek into what is buffered
// is the browser's; one outside it ends the current read and begins another from there. The
// buffer is kept a minute ahead of the playhead — a write waits for room, which holds the read
// and so the download — and what is half a minute behind is let go.

import {SubtitleScanner, toVtt} from "./ebml_subs.js"
import {lengths} from "./lengths.js"
import {heads} from "./heads.js"

// Loaded from the site's own files at run time, not bundled: the address is a variable so the
// bundler leaves the import alone.
const load = (url) => import(url)

let libs = null
function loadLibs() {
  if (!libs) {
    libs = (async () => {
      const MB = await load("/vendor/mediabunny.min.mjs")
      let Dolby = null
      try {
        const {makeDolbyDecoder} = await load("/vendor/dolby-decoder.mjs")
        Dolby = makeDolbyDecoder(MB)
        await Dolby.ready()
        MB.registerDecoder(Dolby)
      } catch (e) {
        console.warn("local player: Dolby decoder unavailable", e)
      }
      return {MB, Dolby}
    })()
  }
  return libs
}

const supportsType = (t) => { const MS = window.ManagedMediaSource || window.MediaSource; return !!(MS && MS.isTypeSupported && MS.isTypeSupported(t)) }
const mime = (kind, codecs) => `${kind}/mp4; codecs="${codecs}"`

async function encoderFor(MB) {
  // AAC where the browser encodes it (Chrome, Safari), else Opus (Firefox).
  try { if (await MB.canEncodeAudio("aac")) return "aac" } catch (e) {}
  try { if (await MB.canEncodeAudio("opus")) return "opus" } catch (e) {}
  return null
}

const AHEAD = 60, BEHIND = 30

/**
 * Start playing `url` in `video`. Returns a controller: `seek(t)`, `audioTracks`, `setAudio(i)`,
 * `subtitleTracks` (each with `read()` giving its WebVTT so far), `stop()`.
 * `opts`: `fileKey` (what identifies the file: its length and the reads of its head are kept on this device), `resume` (seconds), `audioLang` (ISO 639-2 preferred), `onFail(why)`, `onReady(info)`,
 * `onLog(line)`, `onPhase(name)` ("first": the length and tracks are known, the video is being
 * read), `onRead(bytes)` (each read of the file, for the loading overlay).
 */
export async function startLocalPlayer(video, url, opts = {}) {
  const {MB, Dolby} = await loadLibs()
  const log = opts.onLog || (() => {})
  const fail = (why) => { log("local player failed: " + why); if (opts.onFail) opts.onFail(why) }

  const scanner = new SubtitleScanner()
  const source = new MB.UrlSource(url, {maxCacheSize: 96 * 1024 * 1024})
  // Every window the reader fetches is shown to the scanner (it only follows the structure and
  // keeps the subtitle blocks; nothing is read twice).
  // The parts of the file read so far, merged: a read returns its cached window again and again, and
  // only what was not seen before counts towards the loading overlay's bytes.
  let seen = []
  const fresh = (from, n) => {
    const to = from + n
    let added = n
    for (const [a, b] of seen) added -= Math.max(0, Math.min(b, to) - Math.max(a, from))
    const merged = []
    let cur = [from, to]
    for (const r of seen) {
      if (r[1] < cur[0] || r[0] > cur[1]) merged.push(r)
      else cur = [Math.min(r[0], cur[0]), Math.max(r[1], cur[1])]
    }
    merged.push(cur)
    seen = merged
    return Math.max(0, added)
  }
  const originalRead = source._read.bind(source)
  // Until the tracks are known, every read is the file's head: served from this device when it was
  // kept from a time before, kept when it had to be fetched. After that, the file itself.
  // The very first read always goes to the host: the reader learns the file's size from that
  // response, and asks for it right after (an MKV's index is at the end) — served from the device
  // instead, it has no size and gives up ("reading file size too early").
  let heading = true, primed = false, headReads = 0, headHits = 0
  const key = opts.fileKey || null
  heads.touch(key)
  source._read = (start, end, minPos, maxPos) => {
    const see = (res) => { if (res && res.bytes && opts.onRead && Number.isFinite(res.offset)) opts.onRead(fresh(res.offset, res.bytes.byteLength)); try { if (res && res.bytes && Number.isFinite(res.offset)) scanner.feed(res.offset, res.bytes) } catch (e) { console.warn("subtitle scanner", e) }; return res }
    if (!heading || !key || !primed) {
      const first = !primed && heading && key
      primed = true
      if (first) headReads++
      const r = originalRead(start, end, minPos, maxPos)
      const keep = (res) => { if (first && res && res.bytes && Number.isFinite(res.offset)) heads.put(key, start, end, res); return see(res) }
      return r && typeof r.then === "function" ? r.then(keep) : keep(r)
    }
    headReads++
    return heads.get(key, start, end).then((kept) => {
      // As the reader's own sources return a read: the bytes, where they begin, and a view on them.
      if (kept) { headHits++; return see({offset: kept.offset, bytes: kept.bytes, view: new DataView(kept.bytes.buffer, kept.bytes.byteOffset, kept.bytes.byteLength)}) }
      return Promise.resolve(originalRead(start, end, minPos, maxPos)).then((res) => {
        if (res && res.bytes && Number.isFinite(res.offset) && heading) heads.put(key, start, end, res)
        return see(res)
      })
    })
  }
  const input = new MB.Input({source, formats: MB.ALL_FORMATS})
  const t0 = performance.now()
  // The length: kept from the last time this file was opened here, else worked out (and kept).
  let duration = lengths.get(key)
  if (!duration) {
    duration = await input.computeDuration()
    lengths.set(key, duration)
  }
  const tracks = await input.getTracks()
  log(`tracks read in ${Math.round(performance.now() - t0)} ms: ${headReads} reads, ${headHits} from this device`)
  const videoTrack = await pickVideo(tracks)
  if (!videoTrack) { fail("no video track this browser can take"); return null }
  const videoCodec = await videoTrack.getCodecParameterString()
  const encoder = await encoderFor(MB)
  heading = false
  log(`head read in ${Math.round(performance.now() - t0)} ms: ${headReads} reads, ${headHits} from this device`)

  // Audio: every track with how it would be carried; the preferred language first.
  const audios = []
  for (const t of tracks) {
    if (t.type !== "audio") continue
    const codecString = await t.getCodecParameterString().catch(() => null)
    const canDecode = await t.canDecode().catch(() => false)
    const copyable = ["aac", "opus", "mp3"].includes(t.codec) && codecString && supportsType(mime("audio", codecString))
    const how = copyable ? "copy" : canDecode && encoder ? "transcode" : null
    audios.push({track: t, codecString, how, lang: t.languageCode, name: t.name || "", codec: t.codec || String(t.internalCodecId), channels: t.numberOfChannels})
  }
  const playable = audios.filter((a) => a.how)
  let audioIndex = -1
  if (playable.length) {
    const pref = opts.audioLang && playable.find((a) => a.lang === opts.audioLang || a.lang.slice(0, 2) === String(opts.audioLang).slice(0, 2))
    audioIndex = audios.indexOf(pref || playable[0])
  }

  // Subtitles carried in the release: the scanner's tracks (known once the file's header has
  // gone past it, which the reader does first), each a WebVTT that grows as the file is read.
  const subtitleTracks = () =>
    scanner.subtitleTracks.map((t) => ({
      lang: t.lang, name: t.name, codec: t.codec, cues: t.cues, forced: t.forced, sdh: t.sdh,
      label: `${t.lang}${t.name ? " · " + t.name : ""}${t.forced && !/forced/i.test(t.name) ? " (forced)" : ""}`, url: `local:sub:${t.number}`,
      read: () => toVtt(t),
    }))

  const MS = window.ManagedMediaSource || window.MediaSource
  // `seeking`: a read from a new place is under way (nothing of it is on screen yet); `target` is
  // where it begins and `pending` a later seek asked for meanwhile (the newest one wins).
  const state = {run: null, stopped: false, seeking: false, expect: null, starts: 0, target: null, pending: null}

  // One read of the file from `from`: a conversion into a fresh MediaSource.
  async function start(from) {
    state.starts++
    if (state.run) await state.run.stop()
    scanner.seek()
    const audio = audioIndex >= 0 ? audios[audioIndex] : null
    let audioOpts = {discard: true}, audioCodec = null
    if (audio && audio.how === "copy") { audioOpts = {}; audioCodec = audio.codecString }
    else if (audio && audio.how === "transcode") { audioOpts = {codec: encoder, bitrate: 160000, forceTranscode: true}; audioCodec = encoder === "aac" ? "mp4a.40.2" : "opus" }
    const type = mime("video", audioCodec ? `${videoCodec}, ${audioCodec}` : videoCodec)
    if (!supportsType(type)) { fail(`this browser does not play ${type}`); return }

    const ms = new MS()
    const objectUrl = URL.createObjectURL(ms)
    // WebKit's ManagedMediaSource attaches only to an element with remote playback off — set
    // before the source, not after.
    if ("disableRemotePlayback" in video) video.disableRemotePlayback = true
    video.src = objectUrl
    await new Promise((res) => ms.addEventListener("sourceopen", res, {once: true}))
    let sb
    try { sb = ms.addSourceBuffer(type) } catch (e) { fail(`addSourceBuffer: ${e.message}`); return }
    sb.mode = "segments"
    sb.timestampOffset = from
    try { ms.duration = duration } catch (e) {}

    const queue = []
    let finished = false, waiting = null, closed = false, bytes = 0
    const ahead = () => (video.buffered.length ? video.buffered.end(video.buffered.length - 1) - video.currentTime : 0)
    const idle = () => new Promise((res) => (sb.updating ? sb.addEventListener("updateend", () => res(), {once: true}) : res()))
    const release = () => { if (waiting) { const w = waiting; waiting = null; w() } }
    const evict = async () => {
      if (closed || !video.buffered.length || sb.updating) return
      const start = video.buffered.start(0), keepFrom = video.currentTime - BEHIND
      if (keepFrom - start > 10) { try { sb.remove(start, keepFrom) } catch (e) { return }; await idle() }
    }
    const pump = async () => {
      if (closed || sb.updating || !queue.length || video.error) {
        if (!closed && finished && !queue.length && !sb.updating && ms.readyState === "open") { try { ms.endOfStream() } catch (e) {} }
        return
      }
      try { sb.appendBuffer(queue[0]); queue.shift() } catch (e) {
        if (e.name === "QuotaExceededError") { await evict(); await new Promise((r) => setTimeout(r, 500)); pump(); return }
        log("appendBuffer failed: " + e.message); queue.shift()
      }
    }
    const onUpdate = () => { pump(); if (waiting && !queue.length && ahead() < AHEAD) release() }
    sb.addEventListener("updateend", onUpdate)
    const room = setInterval(() => { evict(); if (waiting && !queue.length && !sb.updating && ahead() < AHEAD) release() }, 500)

    const writable = new WritableStream({
      async write(chunk) {
        if (closed) return
        bytes += chunk.data.byteLength
        queue.push(chunk.data)
        pump()
        if (queue.length > 0 || ahead() >= AHEAD) await new Promise((res) => { waiting = res })
      },
    })
    const output = new MB.Output({
      format: new MB.Mp4OutputFormat({fastStart: "fragmented", minimumFragmentDuration: 2}),
      target: new MB.StreamTarget(writable, {chunked: true, chunkSize: 512 * 1024}),
    })
    const conversion = await MB.Conversion.init({
      input, output,
      video: (t) => (t === videoTrack ? {} : {discard: true}),
      audio: (t) => (audio && t === audio.track ? audioOpts : {discard: true}),
      trim: from > 0 ? {start: from} : undefined,
    })
    if (!conversion.isValid) { fail("conversion not valid: " + conversion.discardedTracks.map((d) => `${d.track.type}: ${d.reason}`).join("; ")); return }
    let processed = from
    conversion.onProgress = (_p, time) => { processed = from + time }

    const run = {
      from, type, bytes: () => bytes, processed: () => processed,
      async stop() {
        closed = true
        clearInterval(room)
        release()
        try { conversion.cancel() } catch (e) {}
        sb.removeEventListener("updateend", onUpdate)
        try { if (ms.readyState === "open") ms.endOfStream() } catch (e) {}
        URL.revokeObjectURL(objectUrl)
      },
    }
    state.run = run
    log(`local: ${type} from ${from.toFixed(0)} s, audio ${audio ? `${audio.codec} ${audio.lang} (${audio.how})` : "none"}`)
    conversion.execute().then(() => { finished = true; pump() }).catch((e) => { const m = String(e && e.message || e); if (!/cancel/i.test(m) && !closed) fail("read failed: " + m) })
    return run
  }

  // A seek outside what is buffered: read again from there. The seek a restart makes itself
  // (to where the new read begins, before anything of it is buffered) is not another one.
  function onSeeking() {
    if (state.seeking || !state.run) return
    const t = video.currentTime
    if (state.expect !== null && Math.abs(t - state.expect) < 1.5) return
    for (let i = 0; i < video.buffered.length; i++) {
      if (t >= video.buffered.start(i) - 0.5 && t <= video.buffered.end(i) + 0.5) return
    }
    restartAt(t)
  }
  function onProgress() {
    // Once the new read has reached where it began, seeks are the viewer's again.
    const e = state.expect
    if (e === null) return
    for (let i = 0; i < video.buffered.length; i++) if (e >= video.buffered.start(i) - 0.5 && e <= video.buffered.end(i)) { state.expect = null; return }
  }
  // The page is told (`onSeeking`) while this runs: until the new read has something to show the
  // video reads 0:00 and sits paused, so the bar and clock keep to `target` instead, and a seek
  // asked for meanwhile is not lost, nor does it start a second read on top of the first — when
  // this one lands, the newest asked-for place is read next.
  async function restartAt(t) {
    state.seeking = true
    if (opts.onSeeking) opts.onSeeking(true)
    const wasPaused = video.paused
    let from = Math.max(0, Math.floor(t))
    try {
      for (;;) {
        state.target = from
        state.expect = from
        await start(from)
        video.currentTime = from
        if (state.pending === null) break
        from = Math.max(0, Math.floor(state.pending))
        state.pending = null
      }
    } finally {
      state.target = null
      state.seeking = false
      if (opts.onSeeking) opts.onSeeking(false)
    }
    if (!wasPaused) video.play().catch(() => {})
  }
  video.addEventListener("seeking", onSeeking)
  video.addEventListener("progress", onProgress)
  video.addEventListener("timeupdate", onProgress)

  const resume = Math.max(0, Number(opts.resume) || 0)
  state.expect = resume
  if (opts.onPhase) opts.onPhase("first")
  await start(resume)
  if (resume > 0) video.currentTime = resume
  video.play().catch(() => {})

  const ctl = {
    duration,
    get audioTracks() { return audios.map((a, i) => ({i, name: a.name || a.codec, lang: a.lang, codec: a.codec, how: a.how, active: i === audioIndex, playable: !!a.how})) },
    async setAudio(i) {
      if (!audios[i] || !audios[i].how || i === audioIndex) return
      audioIndex = i
      await restartAt(video.currentTime)
    },
    get subtitleTracks() { return subtitleTracks() },
    onSubtitleTracks(fn) { scanner.onTracks = () => fn(subtitleTracks()); if (scanner.subtitleTracks.length) fn(subtitleTracks()) },
    seek(t) {
      const to = Math.max(0, t)
      if (state.seeking) state.pending = to
      else video.currentTime = to
    },
    get seeking() { return state.seeking },
    // Where the video is going while a read from a new place has not yet reached it.
    get target() { return state.pending !== null ? state.pending : state.target },
    stats() { const r = state.run; return r ? {from: r.from, bytes: r.bytes(), processed: r.processed(), type: r.type, starts: state.starts, subtitles: scanner.stats} : null },
    async stop() {
      state.stopped = true
      video.removeEventListener("seeking", onSeeking)
      video.removeEventListener("progress", onProgress)
      video.removeEventListener("timeupdate", onProgress)
      if (state.run) await state.run.stop()
      state.run = null
      try { input.dispose && input.dispose() } catch (e) {}
    },
  }
  ctl.__scanner = scanner // for the trace
  if (opts.onReady) opts.onReady(ctl)
  return ctl
}

async function pickVideo(tracks) {
  for (const t of tracks) {
    if (t.type !== "video") continue
    const cs = await t.getCodecParameterString().catch(() => null)
    if (cs && supportsType(mime("video", cs))) return t
    if (await t.canDecode().catch(() => false)) return t
  }
  return null
}
