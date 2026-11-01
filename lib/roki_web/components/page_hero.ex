defmodule RokiWeb.PageHero do
  @moduledoc """
  The top of a page that is a listing: a wide picture (or, where there is none, a colour) under the
  floating header, the page's name large on it, and the page's own controls beneath the name — the
  look Movies, Shows and Anime wear. Pages using it set `flush bleed overlay` on `Layouts.app` and
  put what follows in `content_class/0`, so the margins match.
  """
  use RokiWeb, :html

  @doc "The classes of the box under the hero, which brings its own margins (the layout is `flush`)."
  def content_class,
    do: "space-y-6 px-4 pb-12 pt-6 [overflow-x:clip] sm:px-6 lg:px-12 xl:px-16"

  attr :eyebrow, :string, default: nil, doc: "the small line over the name"
  attr :title, :string, required: true
  attr :image, :string, default: nil, doc: "the picture, a URL; none draws a colour instead"
  attr :hue, :integer, default: 24, doc: "the colour drawn when there is no picture, 0–359"
  slot :inner_block, doc: "under the name: the page's controls"

  def page_hero(assigns) do
    ~H"""
    <section class="relative z-20 flex min-h-[clamp(14rem,32svh,22rem)] flex-col justify-end text-white">
      <div
        class="absolute inset-0 -z-10 overflow-hidden bg-neutral-900"
        style={"--hue: #{@hue}"}
      >
        <img :if={@image} src={@image} alt="" class="h-full w-full object-cover opacity-80" />
        <div
          :if={!@image}
          class="absolute inset-0"
          style="background: radial-gradient(90% 130% at 85% -10%, hsl(var(--hue) 80% 50% / 0.7), transparent 65%), linear-gradient(160deg, hsl(var(--hue) 50% 22%) 0%, hsl(var(--hue) 55% 9%) 100%)"
        >
        </div>
        <div class={[
          "absolute inset-0 bg-gradient-to-r",
          @image && "from-black/80 via-black/40 to-black/10",
          !@image && "from-black/40 via-transparent to-transparent"
        ]}>
        </div>
        <div class={[
          "absolute inset-0 bg-gradient-to-t via-transparent",
          @image && "from-black/70 to-black/50",
          !@image && "from-black/40 to-black/30"
        ]}>
        </div>
      </div>

      <div class="flex flex-col gap-5 px-4 pb-6 pt-28 sm:px-6 lg:px-12 xl:px-16">
        <div>
          <p
            :if={@eyebrow}
            class="text-xs font-semibold uppercase tracking-[0.25em] text-white/70"
          >
            {@eyebrow}
          </p>
          <h1 class="text-5xl font-bold leading-[1.04] tracking-tight drop-shadow-lg sm:text-6xl xl:text-7xl">
            {@title}
          </h1>
        </div>
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end
end
