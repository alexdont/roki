// The title page's hero: the trailer plays muted behind the picture, with controls of its own.
//
// It starts a couple of seconds after the page is up (never with reduced motion; the play control
// starts it then), plays once and stops — it does not loop — and the picture comes back. A pause is
// the viewer's and stays one; the video also pauses by itself when the hero is scrolled out of view
// or the tab is hidden, and goes on from there only if the viewer had not paused it.
//
// The player is YouTube's embed (TMDB lists trailers, it does not host them), driven through its
// postMessage interface, so no extra script is loaded.
const YT = "https://www.youtube-nocookie.com"
const AUTOPLAY_MS = 2000

export const HeroTrailer = {
  mounted() {
    this.reduced = matchMedia("(prefers-reduced-motion: reduce)").matches
    this.wide = matchMedia("(min-width: 1024px)")
    this.visible = true
    // What the picture and the controls are told (as data attributes on the hero, for CSS), kept
    // here because a page patch can drop attributes it did not put there.
    this.flags = {}
    this.userPaused = false
    this.autoPaused = false
    this.frame = null
    this.stage = this.el.querySelector("[data-hero-video]")

    this.el.addEventListener("click", (e) => {
      const button = e.target.closest?.("[data-hero-ctl]")
      if (!button || !this.el.contains(button)) return
      e.preventDefault()
      this.control(button.dataset.heroCtl)
    })

    this.onMessage = (e) => {
      if (e.origin !== YT || !this.frame || e.source !== this.frame.contentWindow) return
      let data = e.data
      try { if (typeof data === "string") data = JSON.parse(data) } catch (_e) { return }
      if (data?.event === "onStateChange") this.playerState(data.info)
      else if (data?.event === "infoDelivery" && typeof data.info?.playerState === "number") this.playerState(data.info.playerState)
    }
    window.addEventListener("message", this.onMessage)

    this.io = new IntersectionObserver((entries) => {
      this.visible = entries.some((en) => en.isIntersecting)
      this.attend()
    }, {threshold: 0.25})
    this.io.observe(this.el)

    this.onHidden = () => this.attend()
    document.addEventListener("visibilitychange", this.onHidden)
    this.onFullscreen = () => { this.el.dataset.heroFullscreen = String(document.fullscreenElement === this.el) }
    document.addEventListener("fullscreenchange", this.onFullscreen)

    this.arm()
  },

  // The trailer's address arrives a moment after the page does.
  updated() {
    this.stage = this.el.querySelector("[data-hero-video]")
    this.paint()
    this.arm()
  },

  destroyed() {
    clearTimeout(this.timer)
    window.removeEventListener("message", this.onMessage)
    document.removeEventListener("visibilitychange", this.onHidden)
    document.removeEventListener("fullscreenchange", this.onFullscreen)
    this.io?.disconnect()
    if (document.fullscreenElement === this.el) document.exitFullscreen?.()
  },

  key() {
    return this.el.dataset.key || ""
  },

  arm() {
    clearTimeout(this.timer)
    if (this.frame || !this.key() || this.reduced || !this.wide.matches) return
    this.timer = setTimeout(() => { if (this.visible && !document.hidden) this.load(true) }, AUTOPLAY_MS)
  },

  load(autoplay) {
    if (this.frame || !this.key() || !this.stage) return
    const f = document.createElement("iframe")
    f.src =
      `${YT}/embed/${this.key()}?autoplay=${autoplay ? 1 : 0}&mute=1&controls=0&disablekb=1&modestbranding=1` +
      `&rel=0&playsinline=1&iv_load_policy=3&fs=0&enablejsapi=1&origin=${encodeURIComponent(location.origin)}`
    f.allow = "autoplay; encrypted-media; fullscreen"
    f.title = "Trailer"
    f.tabIndex = -1
    f.addEventListener("load", () => this.post("listening"))
    this.stage.appendChild(f)
    this.frame = f
    this.set({heroMuted: "true"})
  },

  // One command to the player.
  command(func, args = []) {
    this.frame?.contentWindow?.postMessage(JSON.stringify({event: "command", func, args}), YT)
  },

  post(kind) {
    if (kind === "listening") this.frame?.contentWindow?.postMessage(JSON.stringify({event: "listening", id: 1, channel: "widget"}), YT)
  },

  playerState(state) {
    if (state === 1) this.set({heroPlaying: "true", heroLive: "true", heroEnded: "false"})
    else if (state === 2) this.set({heroPlaying: "false"})
    // Over: the picture comes back, and play starts it again.
    else if (state === 0) this.set({heroPlaying: "false", heroEnded: "true"})
  },

  // The viewer's controls.
  control(which) {
    if (which === "play") {
      if (!this.frame) { this.load(true); return }
      const playing = this.flags.heroPlaying === "true"
      if (this.flags.heroEnded === "true") {
        this.userPaused = false
        this.command("seekTo", [0, true])
        this.command("playVideo")
      } else if (playing) {
        this.userPaused = true
        this.command("pauseVideo")
      } else {
        this.userPaused = false
        this.command("playVideo")
      }
    } else if (which === "mute") {
      if (!this.frame) { this.load(true); this.set({heroMuted: "false"}); return }
      const muted = this.flags.heroMuted !== "false"
      if (muted) { this.command("unMute"); this.command("setVolume", [70]) } else this.command("mute")
      this.set({heroMuted: String(!muted)})
    } else if (which === "full") {
      if (document.fullscreenElement === this.el) document.exitFullscreen()
      else this.el.requestFullscreen?.()
    }
  },

  // Out of sight, or the tab hidden: stop; back in sight: go on, unless the viewer paused it.
  attend() {
    const watching = this.visible && !document.hidden
    if (!this.frame) { if (watching) this.arm(); return }
    if (!watching && this.flags.heroPlaying === "true") {
      this.autoPaused = true
      this.command("pauseVideo")
    } else if (watching && this.autoPaused && !this.userPaused && this.flags.heroEnded !== "true") {
      this.autoPaused = false
      this.command("playVideo")
    }
  },

  set(marks) {
    Object.assign(this.flags, marks)
    this.paint()
  },

  paint() {
    for (const [name, value] of Object.entries(this.flags)) this.el.dataset[name] = value
  },
}
