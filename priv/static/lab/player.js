// The player lab: Mediabunny (MPL-2.0, /vendor/mediabunny.min.mjs) reads the release straight
// from its URL with byte ranges, demuxes it, copies the video packets as they are, carries the
// audio as it is when this browser's media engine takes that codec in MP4, or decodes and
// re-encodes it here (WebCodecs) when it can decode but not carry it — and writes fragmented
// MP4 into a MediaSource buffer that the <video> plays. No server work at all.
import * as MB from "/vendor/mediabunny.min.mjs"

const $ = (id) => document.getElementById(id)
const log = (...a) => { const el = $("log"); el.textContent += a.map((x) => typeof x === "string" ? x : JSON.stringify(x)).join(" ") + "\n"; el.scrollTop = el.scrollHeight }
const mime = (kind, codecs) => `${kind}/mp4; codecs="${codecs}"`
const supportsType = (t) => { const MS = window.ManagedMediaSource || window.MediaSource; return !!(MS && MS.isTypeSupported(t)) }

// ── what this device can do ───────────────────────────────────────────────
async function caps() {
  const rows = []
  const video = [["H.264", "avc1.640028"], ["HEVC", "hvc1.1.6.L120.B0"], ["HEVC 4K", "hvc1.2.4.L153.B0"], ["AV1", "av01.0.08M.08"], ["VP9", "vp09.00.31.08"]]
  const audio = [["AAC", "mp4a.40.2"], ["Opus", "opus"], ["FLAC", "flac"], ["E-AC-3", "ec-3"], ["AC-3", "ac-3"], ["MP3", "mp3"]]
  for (const [name, c] of video) {
    let wc = "–"
    try { wc = (await VideoDecoder.isConfigSupported({codec: c, codedWidth: 1920, codedHeight: 1080})).supported } catch (e) { wc = false }
    rows.push([name, supportsType(mime("video", c)), wc, null])
  }
  for (const [name, c] of audio) {
    let dec = false, enc = "–"
    try { dec = (await AudioDecoder.isConfigSupported({codec: c, sampleRate: 48000, numberOfChannels: 2})).supported } catch (e) { dec = false }
    if (c === "mp4a.40.2" || c === "opus") { try { enc = (await AudioEncoder.isConfigSupported({codec: c, sampleRate: 48000, numberOfChannels: 2, bitrate: 128000})).supported } catch (e) { enc = false } }
    rows.push([name, supportsType(mime("audio", c)), dec, enc])
  }
  const mark = (v) => v === "–" || v === null ? `<td class="muted">–</td>` : `<td class="${v ? "ok" : "no"}">${v ? "yes" : "no"}</td>`
  $("caps").querySelector("tbody").innerHTML =
    `<tr><th>codec</th><th>plays in MP4 (MSE)</th><th>decodes (WebCodecs)</th><th>encodes (WebCodecs)</th></tr>` +
    rows.map(([n, m, d, e]) => `<tr><td>${n}</td>${mark(m)}${mark(d)}${mark(e)}</tr>`).join("")
  const aacEnc = rows.find((r) => r[0] === "AAC")[3], opusEnc = rows.find((r) => r[0] === "Opus")[3]
  return {aacEnc, opusEnc}
}

// ── source ────────────────────────────────────────────────────────────────
function sourceUrl() {
  const preset = $("preset").value
  const typed = $("url").value.trim()
  const url = preset || typed
  if (!url) return null
  if (preset) return url
  return $("relay").checked ? `/lab/bytes?u=${encodeURIComponent(url)}` : url
}

let state = null

async function probe(given) {
  const url = given || sourceUrl()
  if (!url) return log("No source.")
  $("start").disabled = true
  log(`Probing ${url}`)
  const input = new MB.Input({source: new MB.UrlSource(url), formats: MB.ALL_FORMATS})
  const t0 = performance.now()
  const format = await input.getFormat()
  const duration = await input.computeDuration()
  const tracks = await input.getTracks()
  log(`Format ${format.name}, ${duration.toFixed(1)} s, ${tracks.length} tracks (${Math.round(performance.now() - t0)} ms)`)
  const rows = []
  const audios = []
  let video = null
  for (const t of tracks) {
    const codecString = await t.getCodecParameterString().catch(() => null)
    const canDecode = await t.canDecode().catch(() => false)
    if (t.type === "video") {
      const mse = codecString ? supportsType(mime("video", codecString)) : false
      if (!video && (mse || canDecode)) video = t
      rows.push(["video", `${t.codec || t.internalCodecId} ${t.displayWidth}×${t.displayHeight}`, codecString, mse, canDecode, mse ? "copy" : canDecode ? "copy (decodes)" : "cannot"])
    } else if (t.type === "audio") {
      const mse = codecString ? supportsType(mime("audio", codecString)) : false
      const inMp4 = ["aac", "opus", "flac", "mp3"].includes(t.codec)
      const plan = mse && inMp4 ? "copy" : canDecode ? (state.caps.aacEnc ? "decode → AAC" : state.caps.opusEnc ? "decode → Opus" : "cannot encode") : "needs server (no decoder here)"
      audios.push({track: t, plan, codecString})
      rows.push(["audio", `${t.codec || t.internalCodecId} ${t.numberOfChannels}ch ${t.sampleRate} Hz · ${t.languageCode}${t.name ? " · " + t.name : ""}`, codecString, mse, canDecode, plan])
    } else {
      rows.push([t.type, String(t.codec || t.internalCodecId), codecString, null, null, "ignored"])
    }
  }
  const cell = (v) => v === null ? `<td class="muted">–</td>` : `<td class="${v ? "ok" : "no"}">${v ? "yes" : "no"}</td>`
  $("tracks").querySelector("tbody").innerHTML =
    `<tr><th>kind</th><th>what</th><th>codec string</th><th>plays in MP4</th><th>decodes</th><th>plan</th></tr>` +
    rows.map(([k, w, c, m, d, p]) => `<tr><td>${k}</td><td>${w}</td><td class="muted">${c || "?"}</td>${cell(m)}${cell(d)}<td class="${/cannot|server/.test(p) ? "no" : /→/.test(p) ? "maybe" : "ok"}">${p}</td></tr>`).join("")
  const sel = $("audio")
  sel.innerHTML = audios.map((a, i) => `<option value="${i}">${a.track.languageCode}${a.track.name ? " · " + a.track.name : ""} · ${a.track.codec || "?"} — ${a.plan}</option>`).join("") || `<option value="">no audio</option>`
  const first = audios.findIndex((a) => !/cannot|server/.test(a.plan))
  if (first >= 0) sel.value = String(first)
  state = {...state, input, format: format.name, duration, video, audios, rows}
  $("start").disabled = !video
  if (!video) log("No video track this browser can take.")
  return state
}

// ── play ──────────────────────────────────────────────────────────────────
// Plays what was probed; with `seconds`, stops after that much playback and resolves to the
// numbers (for the automatic run), else runs to the end.
async function play(seconds) {
  const {input, video, audios} = state
  const audio = audios[Number($("audio").value)] || null
  const from = Math.max(0, Number($("from").value) || 0)
  const v = $("video")
  stop(false)
  if (!video) return {error: "no playable video track"}
  const logStart = $("log").textContent.length

  const videoCodec = await video.getCodecParameterString()
  let audioOpts = {discard: true}, audioCodec = null
  if (audio) {
    const force = new URLSearchParams(location.search).get("transcode") === "1"
    if (audio.plan === "copy" && !force) { audioOpts = {}; audioCodec = audio.codecString }
    else if (audio.plan === "copy" && force) { const codec = state.caps.aacEnc ? "aac" : "opus"; audioOpts = {codec, bitrate: 160000, forceTranscode: true}; audioCodec = codec === "aac" ? "mp4a.40.2" : "opus"; log(`(forced) decoding ${audio.track.codec} here and re-encoding to ${codec}`) }
    else if (audio.plan.startsWith("decode")) { const codec = state.caps.aacEnc ? "aac" : "opus"; audioOpts = {codec, bitrate: 160000, forceTranscode: true}; audioCodec = codec === "aac" ? "mp4a.40.2" : "opus" }
    else log(`Audio "${audio.track.languageCode}" cannot be played on this device (${audio.plan}) — playing without sound.`)
  }
  const type = mime("video", audioCodec ? `${videoCodec}, ${audioCodec}` : videoCodec)
  log(`MSE type ${type} → ${supportsType(type) ? "supported" : "NOT supported"}`)

  const MS = window.ManagedMediaSource || window.MediaSource
  const ms = new MS()
  v.src = URL.createObjectURL(ms)
  v.disableRemotePlayback = true
  await new Promise((res) => ms.addEventListener("sourceopen", res, {once: true}))
  const sb = ms.addSourceBuffer(type)
  sb.mode = "segments"

  // Fragments arrive in order; they are appended one at a time, as the buffer allows.
  const queue = []
  let bytes = 0, expectedPos = 0, finished = false
  const pump = () => {
    if (sb.updating || !queue.length) { if (finished && !queue.length && !sb.updating && ms.readyState === "open") { try { ms.endOfStream() } catch (e) {} } ; return }
    const chunk = queue.shift()
    try { sb.appendBuffer(chunk) } catch (e) { log("appendBuffer failed:", String(e)); }
  }
  sb.addEventListener("updateend", pump)
  sb.addEventListener("error", () => log("SourceBuffer error", v.error && v.error.message))

  const writable = new WritableStream({
    write(chunk) {
      if (chunk.position !== expectedPos) log(`out-of-order write at ${chunk.position} (expected ${expectedPos})`)
      expectedPos = chunk.position + chunk.data.byteLength
      bytes += chunk.data.byteLength
      queue.push(chunk.data)
      pump()
    },
  })

  const output = new MB.Output({
    format: new MB.Mp4OutputFormat({fastStart: "fragmented", minimumFragmentDuration: 2}),
    target: new MB.StreamTarget(writable, {chunked: true, chunkSize: 512 * 1024}),
  })

  const t0 = performance.now()
  const conversion = await MB.Conversion.init({
    input, output,
    video: (t) => (t === video ? {} : {discard: true}),
    audio: (t) => (audio && t === audio.track ? audioOpts : {discard: true}),
    trim: from > 0 ? {start: from} : undefined,
  })
  for (const d of conversion.discardedTracks) if (!(d.track === video) && !(audio && d.track === audio.track)) continue; else log("discarded:", d.track.type, d.reason)
  if (!conversion.isValid) { const why = conversion.discardedTracks.map((d) => `${d.track.type}: ${d.reason}`).join("; "); log("Conversion not valid:", why); return {error: "conversion not valid: " + why} }
  log(`Starting${from ? ` from ${from} s` : ""}: video copied, audio ${audio ? audio.plan : "none"}`)

  let processed = 0
  conversion.onProgress = (p, time) => { processed = time }
  const ticker = setInterval(() => {
    const el = (performance.now() - t0) / 1000
    $("s-time").textContent = v.currentTime.toFixed(1)
    $("s-buf").textContent = v.buffered.length ? v.buffered.end(v.buffered.length - 1).toFixed(1) : "0.0"
    $("s-done").textContent = processed.toFixed(1)
    $("s-speed").textContent = el > 0.5 ? (processed / el).toFixed(1) : "–"
    $("s-bytes").textContent = (bytes / 1048576).toFixed(1)
    const q = v.getVideoPlaybackQuality ? v.getVideoPlaybackQuality() : {totalVideoFrames: 0, droppedVideoFrames: 0}
    $("s-frames").textContent = `${q.totalVideoFrames} (${q.droppedVideoFrames})`
  }, 500)

  state.run = {conversion, ticker, ms}
  $("stop").disabled = false
  // Not awaited: play() only settles once there is something to play, which the conversion
  // below is about to provide.
  let playErr = null
  v.play().catch((e) => { playErr = String(e && e.message || e); log("play() refused:", playErr) })

  const numbers = (extra) => {
    const q = v.getVideoPlaybackQuality ? v.getVideoPlaybackQuality() : {totalVideoFrames: 0, droppedVideoFrames: 0}
    return {
      audio: audio ? `${audio.track.codec} ${audio.track.languageCode} — ${audio.plan}` : "none",
      type, played: +v.currentTime.toFixed(1), buffered: v.buffered.length ? +v.buffered.end(v.buffered.length - 1).toFixed(1) : 0,
      prepared: +processed.toFixed(1), speed: +(processed / ((performance.now() - t0) / 1000)).toFixed(1), mb: +(bytes / 1048576).toFixed(1),
      size: `${v.videoWidth}×${v.videoHeight}`, frames: q.totalVideoFrames, dropped: q.droppedVideoFrames,
      mediaError: v.error ? v.error.message || String(v.error.code) : null, playRefused: playErr,
      log: $("log").textContent.slice(logStart).split("\n").filter(Boolean).slice(-8), ...extra,
    }
  }

  const execution = conversion.execute().then(() => { finished = true; pump(); log(`Done: ${(bytes / 1048576).toFixed(1)} MB prepared in ${((performance.now() - t0) / 1000).toFixed(1)} s`); return null })
    .catch((e) => { const m = String(e && e.message || e); if (!/cancel/i.test(m)) log("Conversion failed:", m); return m })

  if (seconds) {
    // The budget is playback time, not preparation (a small file is prepared in a blink): let
    // it play that long, then take the numbers.
    let convErr = null
    execution.then((e) => { convErr = e })
    await new Promise((res) => setTimeout(res, seconds * 1000))
    const out = numbers({conversionError: convErr})
    stop(false)
    return out
  }
  return numbers({conversionError: await execution})
}

function stop(clearVideo = true) {
  if (state && state.run) {
    try { state.run.conversion.cancel() } catch (e) {}
    clearInterval(state.run.ticker)
    state.run = null
  }
  if (clearVideo) { const v = $("video"); v.removeAttribute("src"); v.load() }
  $("stop").disabled = true
}

// ── the automatic run: every sample, then the pasted link, then the report ───────────────
async function runAll() {
  const secs = Math.max(4, Number(new URLSearchParams(location.search).get("secs")) || 12)
  const cases = [
    {name: "H.264 + AAC (copy)", url: "/lab/sample/h264", audio: 0},
    {name: "H.264 + FLAC (copy or re-encode)", url: "/lab/sample/h264", audio: 1},
    {name: "H.264 + E-AC-3 5.1", url: "/lab/sample/eac3", audio: 0},
    {name: "VP9 + Opus", url: "/lab/sample/vp9", audio: 0},
    {name: "H.264 + AAC, start at 30 s", url: "/lab/sample/h264", audio: 0, from: 30},
  ]
  const typed = $("url").value.trim()
  if (typed) {
    cases.push({name: "Your link, direct (CORS?)", url: typed, audio: null, real: true})
    cases.push({name: "Your link, relayed", url: `/lab/bytes?u=${encodeURIComponent(typed)}`, audio: null, real: true})
  }
  $("runall").disabled = true
  const results = []
  log(`=== Automatic run: ${cases.length} cases, ${secs} s each ===`)
  for (const c of cases) {
    log(`--- ${c.name}`)
    const t0 = performance.now()
    try {
      const st = await probe(c.url)
      if (c.audio !== null && c.audio !== undefined) $("audio").value = String(c.audio)
      $("from").value = String(c.from || 0)
      const tracks = st.rows.map(([k, w, cs, m, dec, p]) => ({kind: k, what: w, codec: cs, mse: m, decodes: dec, plan: p}))
      const r = await play(secs)
      results.push({name: c.name, ok: !r.error && !r.mediaError && r.played > 1 && r.frames > 0, format: st.format, duration: +st.duration.toFixed(1), tracks, ...r, ms: Math.round(performance.now() - t0)})
    } catch (e) {
      const m = String(e && e.message || e)
      log("failed:", m)
      results.push({name: c.name, ok: false, error: m, ms: Math.round(performance.now() - t0)})
    }
  }
  stop()
  const report = {
    at: new Date().toISOString(), ua: navigator.userAgent, platform: navigator.platform, width: innerWidth, height: innerHeight,
    managedMediaSource: !!window.ManagedMediaSource, caps: state.capRows, results,
  }
  const ok = results.filter((r) => r.ok).length
  log(`=== ${ok}/${results.length} played. Sending the report…`)
  try {
    const res = await fetch("/lab/report", {method: "POST", headers: {"content-type": "application/json"}, body: JSON.stringify(report)})
    const body = await res.json().catch(() => ({}))
    log(res.ok ? `Report sent (#${body.id}). Nothing else to do — thanks.` : `Report not accepted: ${res.status}`)
  } catch (e) { log("Report could not be sent:", String(e)) }
  $("summary").innerHTML = `<tr><th>case</th><th>result</th><th>audio</th><th>played</th><th>prepared</th><th>× realtime</th><th>frames (dropped)</th><th>note</th></tr>` +
    results.map((r) => `<tr><td>${r.name}</td><td class="${r.ok ? "ok" : "no"}">${r.ok ? "played" : "failed"}</td><td class="muted">${r.audio || ""}</td><td>${r.played ?? ""}</td><td>${r.prepared ?? ""}</td><td>${r.speed ?? ""}</td><td>${r.frames ?? ""} (${r.dropped ?? ""})</td><td class="muted">${r.error || r.mediaError || r.conversionError || r.playRefused || ""}</td></tr>`).join("")
  $("runall").disabled = false
  return report
}

// ── wiring ────────────────────────────────────────────────────────────────
$("preset").addEventListener("change", () => { $("url").disabled = !!$("preset").value })
$("probe").addEventListener("click", () => probe().catch((e) => log("Probe failed:", String(e && e.message || e))))
$("start").addEventListener("click", () => play().catch((e) => log("Play failed:", String(e && e.message || e))))
$("stop").addEventListener("click", () => stop())
$("runall").addEventListener("click", () => runAll().catch((e) => log("Run failed:", String(e && e.message || e))))
window.lab = {probe, play, stop, runAll, get state() { return state }}
state = {caps: await caps(), capRows: [...$("caps").querySelectorAll("tr")].slice(1).map((tr) => [...tr.children].map((td) => td.textContent))}
$("url").disabled = true
const params = new URLSearchParams(location.search)
if (params.get("src")) { const i = [...$("preset").options].findIndex((o) => o.value === params.get("src")); if (i >= 0) $("preset").value = params.get("src") }
if (params.get("runall")) { await runAll() }
else if (params.get("autoplay")) { await probe(); if (params.get("audio")) $("audio").value = params.get("audio"); if (params.get("from")) $("from").value = params.get("from"); await play() }
