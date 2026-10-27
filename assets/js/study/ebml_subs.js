// The subtitles inside a Matroska release, read out of the bytes the player already fetches.
//
// The demuxing library only knows WebVTT subtitle tracks, and a release's own subtitles are
// SRT or ASS, so it drops them. Reading them separately would mean downloading the file twice.
// Instead every byte window the player reads goes past this scanner, which follows the
// Matroska structure far enough to pick the subtitle blocks out: the Tracks element at the
// start (which tracks are subtitles, their codec, language, name), then in every Cluster its
// Timestamp and each SimpleBlock or BlockGroup belonging to a subtitle track. Video and audio
// blocks are skipped by their size. Windows arrive in file order while the player reads
// forward; after a seek the first window begins at a Cluster, where the scanner picks up again.

const ID = {
  EBML: 0x1a45dfa3, Segment: 0x18538067, Info: 0x1549a966, TimestampScale: 0x2ad7b1,
  Tracks: 0x1654ae6b, TrackEntry: 0xae, TrackNumber: 0xd7, TrackType: 0x83, CodecID: 0x86,
  Language: 0x22b59c, LanguageBCP47: 0x22b59d, Name: 0x536e, CodecPrivate: 0x63a2, FlagDefault: 0x88,
  Cluster: 0x1f43b675, Timestamp: 0xe7, SimpleBlock: 0xa3, BlockGroup: 0xa0, Block: 0xa1, BlockDuration: 0x9b,
  SeekHead: 0x114d9b74, Cues: 0x1c53bb6b, Void: 0xec, Tags: 0x1254c367, Attachments: 0x1941a469, Chapters: 0x1043a770,
}

// The elements whose children we walk; everything else is skipped whole.
const MASTER = new Set([ID.Segment, ID.Info, ID.Tracks, ID.TrackEntry, ID.Cluster, ID.BlockGroup])
const TOP = new Set([ID.Segment])

// An EBML variable-size integer at `pos`: `[value, length]`, or null when it is not all there.
// `id` keeps the marker bits (element ids are compared with them).
function vint(bytes, pos, id) {
  if (pos >= bytes.length) return null
  const first = bytes[pos]
  if (first === 0) return null
  let len = 1
  while (len <= 8 && !(first & (0x80 >> (len - 1)))) len++
  if (pos + len > bytes.length) return null
  let value = id ? first : first & (0xff >> len)
  for (let i = 1; i < len; i++) value = value * 256 + bytes[pos + i]
  // All ones: size unknown.
  if (!id && value === 2 ** (7 * len) - 1) value = -1
  return [value, len]
}

const utf8 = new TextDecoder()

function uint(bytes, pos, len) {
  let v = 0
  for (let i = 0; i < len; i++) v = v * 256 + bytes[pos + i]
  return v
}

export class SubtitleScanner {
  constructor() {
    this.tracks = new Map() // number -> {number, codec, lang, name, cues: [], header}
    this.timestampScale = 1_000_000
    this.next = 0 // the file offset the scanner is at
    this.carry = null // bytes from `carryAt` not yet consumed (an element cut by a window edge)
    this.carryAt = 0
    this.clusterTime = 0
    this.inTracks = false
    this.onTracks = null
    this.onCue = null
    this.seenTracks = false
    this.stats = {windows: 0, dropped: 0, gaps: 0, clusters: 0, blocks: 0, subBlocks: 0}

  }

  get subtitleTracks() {
    return [...this.tracks.values()]
  }

  // A window of the file: `offset` is where `bytes` begin. Windows overlap and repeat (the
  // reader's cache): what is before where we are is dropped, what continues from there is
  // taken; a window that begins further on (the player seeked) is taken only at a Cluster edge.
  feed(offset, bytes) {
    const end = offset + bytes.length
    this.stats.windows++
    if (end <= this.next) { this.stats.dropped++; return }
    if (offset <= this.next) {
      const fresh = offset === this.next ? bytes : bytes.subarray(this.next - offset)
      const at = this.next
      let data = fresh
      if (this.carry && this.carryAt + this.carry.length === at) {
        data = new Uint8Array(this.carry.length + fresh.length)
        data.set(this.carry, 0)
        data.set(fresh, this.carry.length)
        this.carry = null
        return this.walk(this.carryAt, data)
      }
      this.carry = null
      return this.walk(at, data)
    }
    // Further on than where we are. The reader looks ahead at headers and at the index at the
    // end of the file while it works through the clusters in order: such a window is simply
    // not for us (what we are in the middle of is kept). Only a window that begins at a Cluster
    // is a place to resume from — the reader seeked, and so do we.
    this.stats.gaps++
    if (!this.startsWithCluster(bytes)) return
    this.carry = null
    this.pendingBlock = null
    this.entry = null
    this.walk(offset, bytes)
  }

  startsWithCluster(bytes) {
    const h = vint(bytes, 0, true)
    return !!h && h[0] === ID.Cluster
  }

  // Walk the elements in `data` (beginning at file offset `base`). Masters are entered, blocks
  // read, everything else skipped. An element cut by the end of the window is kept for the next.
  walk(base, data) {
    let pos = 0
    const n = data.length
    while (pos < n) {
      const idv = vint(data, pos, true)
      if (!idv) return this.keep(base, data, pos)
      const sz = vint(data, pos + idv[1], false)
      if (!sz) return this.keep(base, data, pos)
      const id = idv[0], size = sz[0], headLen = idv[1] + sz[1]
      const bodyAt = pos + headLen

      if (id === ID.EBML) { pos = bodyAt + size; continue }
      if (MASTER.has(id)) {
        if (id === ID.Cluster) { this.clusterTime = 0; this.stats.clusters++; if (!this.seenTracks && this.tracks.size) this.announce() }
        if (id === ID.Tracks) this.inTracks = true
        if (id === ID.TrackEntry) { this.entry = {number: 0, type: 0, codec: "", lang: "", bcp: "", name: "", header: ""} }
        // Enter the master: its children follow directly (unknown size too).
        pos = bodyAt
        // Where these end, as file offsets (windows begin anywhere in the file).
        if (id === ID.TrackEntry) this.entryEnd = size >= 0 ? base + bodyAt + size : -1
        if (id === ID.Tracks) this.tracksEnd = size >= 0 ? base + bodyAt + size : -1
        continue
      }
      if (size < 0) { pos = bodyAt; continue }
      if (bodyAt + size > n) {
        // Only blocks and small fields need their whole body; a big foreign element (Cues,
        // attachments, a video block) is skipped without waiting for its bytes.
        if (this.wanted(id) && size < 4 * 1024 * 1024) return this.keep(base, data, pos)
        this.skipTo = base + bodyAt + size
        this.next = this.skipTo
        this.carry = null
        return
      }
      this.element(id, data, bodyAt, size, base)
      pos = bodyAt + size
      this.closeEntries(base + pos)
    }
    // Past the window's end when the last element was skipped beyond it (a header read in a
    // small first window): the next window is taken up from there.
    this.next = base + Math.max(pos, n)
    this.carry = null
  }

  wanted(id) {
    return id === ID.SimpleBlock || id === ID.Block || id === ID.BlockDuration || id === ID.Timestamp || id === ID.TimestampScale ||
      id === ID.TrackNumber || id === ID.TrackType || id === ID.CodecID || id === ID.Language || id === ID.LanguageBCP47 || id === ID.Name || id === ID.CodecPrivate
  }

  keep(base, data, pos) {
    this.carry = data.slice(pos)
    this.carryAt = base + pos
    this.next = base + data.length
  }

  closeEntries(at) {
    if (this.entry && this.entryEnd >= 0 && at >= this.entryEnd) this.finishEntry()
    if (this.inTracks && this.tracksEnd >= 0 && at >= this.tracksEnd) { this.inTracks = false; this.announce() }
  }

  finishEntry() {
    const e = this.entry
    this.entry = null
    if (!e || e.type !== 0x11) return
    if (!/^S_TEXT\/(UTF8|ASS|SSA|WEBVTT)$|^S_(ASS|SSA)$/.test(e.codec)) return
    if (!this.tracks.has(e.number)) {
      this.tracks.set(e.number, {number: e.number, codec: e.codec, lang: e.bcp || e.lang || "eng", name: e.name, header: e.header, cues: [], last: -1})
    }
  }

  announce() {
    this.seenTracks = true
    if (this.onTracks) this.onTracks(this.subtitleTracks)
  }

  element(id, data, at, size, base) {
    const e = this.entry
    switch (id) {
      case ID.TimestampScale: this.timestampScale = uint(data, at, size) || 1_000_000; break
      case ID.TrackNumber: if (e) e.number = uint(data, at, size); break
      case ID.TrackType: if (e) e.type = uint(data, at, size); break
      case ID.CodecID: if (e) e.codec = utf8.decode(data.subarray(at, at + size)).replace(/\0+$/, ""); break
      case ID.Language: if (e) e.lang = utf8.decode(data.subarray(at, at + size)).replace(/\0+$/, ""); break
      case ID.LanguageBCP47: if (e) e.bcp = utf8.decode(data.subarray(at, at + size)).replace(/\0+$/, ""); break
      case ID.Name: if (e) e.name = utf8.decode(data.subarray(at, at + size)).replace(/\0+$/, ""); break
      case ID.CodecPrivate: if (e) e.header = utf8.decode(data.subarray(at, at + size)); break
      case ID.Timestamp: this.clusterTime = uint(data, at, size); break
      case ID.SimpleBlock: this.stats.blocks++; this.block(data, at, size, null); break
      case ID.Block: this.stats.blocks++; this.pendingBlock = this.block(data, at, size, undefined); break
      case ID.BlockDuration:
        if (this.pendingBlock) { this.pendingBlock.end = this.pendingBlock.start + (uint(data, at, size) * this.timestampScale) / 1e9; this.emit(this.pendingBlock); this.pendingBlock = null }
        break
      default: break
    }
    if (id !== ID.Block && id !== ID.BlockDuration && this.pendingBlock && id !== ID.BlockGroup) {
      // A BlockGroup without a duration: the block ends when the next one begins (set then).
      this.emit(this.pendingBlock); this.pendingBlock = null
    }
  }

  // A block's payload: track number, a signed 16-bit time relative to the cluster, flags, then the
  // text. Only subtitle tracks' blocks are read; others are skipped by the caller's size.
  block(data, at, size, duration) {
    const tn = vint(data, at, false)
    if (!tn) return null
    const track = this.tracks.get(tn[0])
    if (!track) return null
    this.stats.subBlocks++
    const rel = (data[at + tn[1]] << 8) | data[at + tn[1] + 1]
    const relSigned = rel >= 0x8000 ? rel - 0x10000 : rel
    const start = ((this.clusterTime + relSigned) * this.timestampScale) / 1e9
    const text = utf8.decode(data.subarray(at + tn[1] + 3, at + size))
    const cue = {track, start, end: start + 3, text}
    if (duration === undefined) return cue // a Block inside a BlockGroup: its duration follows
    this.emit(cue)
    return cue
  }

  emit(cue) {
    const t = cue.track
    const text = plainText(t.codec, cue.text)
    if (!text) return
    if (cue.start <= t.last) return // read again after a seek: already there
    t.cues.push({start: cue.start, end: Math.max(cue.end, cue.start + 0.5), text})
    t.last = cue.start
    if (this.onCue) this.onCue(t, cue)
  }
}

// What a block says, as plain lines: SRT text as it is (its own tags dropped); an ASS block is
// "ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text" — the text, with the style
// tags dropped and line breaks restored.
export function plainText(codec, raw) {
  let text = raw
  if (/ASS|SSA/.test(codec)) {
    const parts = raw.split(",")
    text = parts.length > 8 ? parts.slice(8).join(",") : raw
    text = text.replace(/\{[^}]*\}/g, "").replace(/\\N|\\n/g, "\n").replace(/\\h/g, " ")
  }
  return text.replace(/<\/?[^>]+>/g, "").replace(/\r/g, "").trim()
}

const vttTime = (s) => {
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = (s % 60).toFixed(3).padStart(6, "0")
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}:${sec}`
}

export function toVtt(track) {
  const cues = [...track.cues].sort((a, b) => a.start - b.start)
  return "WEBVTT\n\n" + cues.map((c, i) => `${i + 1}\n${vttTime(c.start)} --> ${vttTime(c.end)}\n${c.text}\n`).join("\n")
}
