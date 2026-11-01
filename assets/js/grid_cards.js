// A grid of posters (Movies, Shows, Anime, the shelf): rest the pointer on one and the card that
// opens in the home page's rows opens over it — the same picture, trailer, Play and save, from
// the same `/card` lookup. The card code is `ShelfRow`'s; this only gives it a grid to live in
// (no scrolling to bring a card into view, and a card at the edge opens towards the middle).
import {cardMethods} from "./shelf_row"

export const GridCards = {
  mounted() {
    this.grid = true
    this.scroller = this.el
    this.cards()
  },

  updated() {
    this.keepOpen()
  },

  destroyed() {
    this.close()
  },

  ...cardMethods,
}
