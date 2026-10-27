// Dolby (AC-3, E-AC-3) and DTS audio decoded in the browser: FFmpeg's decoders built to
// WebAssembly (/vendor/dolby.wasm, see the shim in the lab's build), offered to Mediabunny as a
// custom audio decoder, so a Conversion can decode a Dolby track here and re-encode it with
// WebCodecs like any other — the browsers themselves decode none of these.
//
// The decoder mixes down to stereo itself (a browser plays stereo anyway), and hands back
// interleaved 32-bit float, which becomes a Mediabunny AudioSample with the packet's timestamp.

let modulePromise = null

function loadModule() {
  if (!modulePromise) {
    modulePromise = import("/vendor/dolby.mjs").then((m) => m.default({locateFile: (f) => "/vendor/" + f}))
  }
  return modulePromise
}

const NAMES = {ac3: "ac3", eac3: "eac3", dts: "dca"}

export function makeDolbyDecoder(MB) {
  return class DolbyDecoder extends MB.CustomAudioDecoder {
    static supports(codec, _config) {
      return codec in NAMES
    }

    static async ready() {
      await loadModule()
      return true
    }

    async init() {
      this.m = await loadModule()
      const name = NAMES[this.codec]
      const extra = this.config.description ? new Uint8Array(this.config.description.buffer || this.config.description) : null
      const namePtr = this.m._malloc(name.length + 1)
      this.m.stringToUTF8(name, namePtr, name.length + 1)
      let extraPtr = 0
      if (extra && extra.byteLength) { extraPtr = this.m._malloc(extra.byteLength); this.m.HEAPU8.set(extra, extraPtr) }
      this.dec = this.m._dolby_open(namePtr, extraPtr, extra ? extra.byteLength : 0, 1)
      this.m._free(namePtr)
      if (extraPtr) this.m._free(extraPtr)
      if (!this.dec) throw new Error(`dolby: could not open a ${name} decoder`)
      this.constructor.last = this
      this.buf = 0
      this.bufLen = 0
      this.frames = 0
      this.sumSq = 0
      this.lastEnd = null
    }

    decode(packet) {
      const data = packet.data
      if (this.bufLen < data.byteLength) {
        if (this.buf) this.m._free(this.buf)
        this.bufLen = Math.max(data.byteLength * 2, 1 << 16)
        this.buf = this.m._malloc(this.bufLen)
      }
      this.m.HEAPU8.set(data, this.buf)
      const n = this.m._dolby_decode(this.dec, this.buf, data.byteLength)
      if (n < 0) { this.onError(new Error(`dolby: decode error ${n}`)); return }
      if (n === 0) return
      this.emit(n, packet.timestamp)
    }

    emit(n, timestamp) {
      const ch = this.m._dolby_channels(this.dec)
      const rate = this.m._dolby_rate(this.dec)
      const ptr = this.m._dolby_out(this.dec)
      // A copy: the WASM heap may move on the next growth.
      const samples = new Float32Array(this.m.HEAPF32.buffer, ptr, n * ch).slice()
      // The packet's time, or straight after the previous sample when the packet carries none
      // that fits (a flush).
      const ts = Number.isFinite(timestamp) ? timestamp : this.lastEnd ?? 0
      this.lastEnd = ts + n / rate
      this.frames += n
      for (let i = 0; i < samples.length; i += 97) this.sumSq += samples[i] * samples[i]
      this.onSample(new MB.AudioSample({data: samples, format: "f32", numberOfChannels: ch, sampleRate: rate, timestamp: ts}))
    }

    flush() {
      const n = this.m._dolby_flush(this.dec)
      if (n > 0) this.emit(n, NaN)
    }

    close() {
      if (this.dec) { this.m._dolby_close(this.dec); this.dec = 0 }
      if (this.buf) { this.m._free(this.buf); this.buf = 0 }
    }

    // For the lab's report: how much was decoded and whether it was silence.
    get stats() {
      const probes = Math.max(1, Math.floor((this.frames * 2) / 97))
      return {frames: this.frames, seconds: +(this.frames / 48000).toFixed(1), rms: +Math.sqrt(this.sumSq / probes).toFixed(4)}
    }
  }
}
