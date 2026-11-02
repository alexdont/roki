// A date field that reads day / month / year, with the calendar still there.
//
// The browser's own date field writes the date in the order of the browser's language, which is
// not ours to set. So the field you see is a plain one, `dd/mm/yyyy`, and the calendar button
// opens the browser's picker on a hidden date field beside it; the form is sent from that one, as
// an ISO date, which is what the page has always been given. Typing in the visible field sets the
// hidden one (once it is a whole, real date) and picking in the calendar writes the visible one.
export const EuDate = {
  mounted() { this.wire() },
  updated() { this.wire() },

  wire() {
    this.text = this.el.querySelector("[data-eu-text]")
    this.real = this.el.querySelector("[data-eu-real]")
    if (!this.text || !this.real || this.wired === this.text) return
    this.wired = this.text

    this.text.addEventListener("input", () => {
      // Slashes go in as the digits come, so typing 16062021 reads 16/06/2021.
      const digits = this.text.value.replace(/\D/g, "").slice(0, 8)
      const parts = [digits.slice(0, 2), digits.slice(2, 4), digits.slice(4)].filter(Boolean)
      if (this.text.value.length >= this.text.dataset.last?.length) this.text.value = parts.join("/")
      this.text.dataset.last = this.text.value

      // What is not (yet) a whole, real date sends nothing, so it is refused rather than saved as the
      // last good one; the field is marked until it is.
      const m = this.text.value.match(/^(\d{2})\/(\d{2})\/(\d{4})$/)
      const [, d, mo, y] = m || []
      const iso = `${y}-${mo}-${d}`
      const date = m && new Date(`${iso}T12:00:00`)
      const real = m && date.getFullYear() === +y && date.getMonth() + 1 === +mo && date.getDate() === +d
      this.text.classList.toggle("input-error", !real && this.text.value.length >= 10)
      if (!real) { this.real.value = ""; return }
      if (this.real.value !== iso) {
        this.real.value = iso
        this.real.dispatchEvent(new Event("input", {bubbles: true}))
      }
    })

    this.real.addEventListener("change", () => {
      const [y, mo, d] = this.real.value.split("-")
      if (y) this.text.value = `${d}/${mo}/${y}`
    })

    this.el.querySelector("[data-eu-open]")?.addEventListener("click", () => {
      try { this.real.showPicker() } catch (_e) { this.real.focus(); this.real.click() }
    })
  },
}
