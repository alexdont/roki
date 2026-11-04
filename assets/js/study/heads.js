// The head of a file, kept on this device: the reads the player makes before it knows a file's
// tracks and length — for an MP4 whose track table sits at the far end of twenty gigabytes, several
// megabytes fetched from the host on every single reload. Kept here (the browser's Cache storage),
// a repeat load has them at once and the "reading the file's length and tracks" wait is gone.
//
// Keyed by what identifies the file (the release and its size) and the exact range asked for: the
// reader asks for the same ranges of the same file every time, and any range it does not find
// here it fetches as before. Capped (per file, and in all; the oldest files go first), and never an
// error: no storage, no memory.

const CACHE = "roki-file-heads"
const INDEX = "roki:file-heads"
const MB = 1024 * 1024

const url = (key, start, end) => `https://heads.roki.invalid/${encodeURIComponent(key)}/${start}-${end}`

export function makeHeads({caches: cachesApi, storage, perFile = 64 * MB, inAll = 320 * MB, perRead = 24 * MB} = {}) {
  const api = cachesApi || (typeof caches !== "undefined" ? caches : null)
  const store = storage || (typeof localStorage !== "undefined" ? localStorage : null)
  const index = {
    all() { try { return JSON.parse(store.getItem(INDEX) || "{}") } catch { return {} } },
    save(all) { try { store.setItem(INDEX, JSON.stringify(all)) } catch {} },
  }
  let opened = null
  const open = () => {
    if (!api) return Promise.resolve(null)
    if (!opened) opened = api.open(CACHE).catch(() => null)
    return opened
  }

  return {
    // The bytes kept for this range of this file, as the reader got them, or null.
    async get(key, start, end) {
      if (!key) return null
      try {
        const c = await open()
        if (!c) return null
        const r = await c.match(url(key, start, end))
        if (!r) return null
        const offset = Number(r.headers.get("x-offset"))
        if (!Number.isFinite(offset)) return null
        return {offset, bytes: new Uint8Array(await r.arrayBuffer())}
      } catch {
        return null
      }
    },

    // Keep what the reader got for this range. Over the file's share, nothing more is kept for it;
    // over the whole store's, the files not touched for longest go.
    async put(key, start, end, res) {
      if (!key || !res || !res.bytes || !Number.isFinite(res.offset)) return
      const n = res.bytes.byteLength
      if (n <= 0 || n > perRead) return
      try {
        const c = await open()
        if (!c) return
        const all = index.all()
        const mine = all[key] || {bytes: 0, at: 0}
        if (mine.bytes + n > perFile) return
        const total = Object.values(all).reduce((s, f) => s + (f.bytes || 0), 0)
        if (total + n > inAll) {
          const oldest = Object.entries(all).filter(([k]) => k !== key).sort((a, b) => (a[1].at || 0) - (b[1].at || 0))
          let freed = 0
          for (const [k, f] of oldest) {
            await this.forget(k, c)
            delete all[k]
            freed += f.bytes || 0
            if (total + n - freed <= inAll) break
          }
        }
        const bytes = res.bytes.byteOffset === 0 && res.bytes.byteLength === res.bytes.buffer.byteLength ? res.bytes : res.bytes.slice()
        await c.put(url(key, start, end), new Response(bytes, {headers: {"x-offset": String(res.offset), "content-type": "application/octet-stream"}}))
        all[key] = {bytes: mine.bytes + n, at: Date.now()}
        index.save(all)
      } catch {}
    },

    // A file was opened: it is the newest, whatever its reads.
    touch(key) {
      if (!key) return
      const all = index.all()
      if (all[key]) { all[key].at = Date.now(); index.save(all) }
    },

    async forget(key, c) {
      try {
        c = c || (await open())
        if (!c) return
        const prefix = `https://heads.roki.invalid/${encodeURIComponent(key)}/`
        for (const req of await c.keys()) if (req.url.startsWith(prefix)) await c.delete(req)
      } catch {}
    },

    // What is kept, for the console: files and bytes.
    stats() {
      const all = index.all()
      return {files: Object.keys(all).length, bytes: Object.values(all).reduce((s, f) => s + (f.bytes || 0), 0)}
    },
  }
}

export const heads = makeHeads()
