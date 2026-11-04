// The length of a file, kept on this device by what identifies the file (the release and its size —
// the link to it changes, the file does not). Working it out reads into the file (its end, for most
// containers), which on a reload was the same wait again for an answer that cannot have changed.
const LENGTHS = "roki:lengths"
export const lengths = {
  all() { try { return JSON.parse(localStorage.getItem(LENGTHS) || "{}") } catch { return {} } },
  get(key) {
    if (!key) return null
    const d = this.all()[key]
    return Number.isFinite(d && d.s) && d.s > 0 ? d.s : null
  },
  set(key, seconds) {
    if (!key || !Number.isFinite(seconds) || seconds <= 0) return
    try {
      const all = this.all()
      delete all[key]
      all[key] = {s: seconds, t: Date.now()}
      // The newest few hundred; each is a few dozen bytes.
      const keys = Object.keys(all)
      for (const k of keys.slice(0, Math.max(0, keys.length - 300))) delete all[k]
      localStorage.setItem(LENGTHS, JSON.stringify(all))
    } catch {}
  },
}


