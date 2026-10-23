// PhoenixKit's account menu has no slot for extra rows, so the rows are rendered next to it in a
// <template> and moved into its list: after Settings for a signed-in user, at the end otherwise.
// A LiveView patch drops what the server did not render, so a re-render puts them back.
export const MenuExtras = {
  mounted() {
    this.place = this.place.bind(this)
    this.observer = new MutationObserver(this.place)
    this.observer.observe(this.el, {childList: true, subtree: true})
    this.place()
  },
  updated() {
    this.place()
  },
  destroyed() {
    this.observer && this.observer.disconnect()
  },
  place() {
    const list = this.el.querySelector("ul.dropdown-content")
    const tpl = this.el.querySelector("template[data-role=menu-extras]")
    if (!list || !tpl || list.querySelector("[data-menu-extras]")) return
    const rows = [...tpl.content.cloneNode(true).children]
    const settings = list.querySelector('a[href*="settings"]')
    let anchor = settings && settings.closest("li")
    this.observer.disconnect()
    for (const row of rows) {
      if (anchor) anchor.after(row)
      else list.append(row)
      anchor = row
    }
    this.observer.observe(this.el, {childList: true, subtree: true})
  },
}
