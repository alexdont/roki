defmodule RokiWeb.ListComponents do
  @moduledoc "How a franchise list is drawn where it is offered — search results and the Lists page."
  use RokiWeb, :html

  attr :list, :map, required: true, doc: "a `Roki.Lists.summary/1` with `:watched`"

  def list_card(assigns) do
    assigns =
      assign(assigns,
        hue: :erlang.phash2(assigns.list.slug, 360),
        percent:
          if(is_integer(assigns.list[:watched]) and assigns.list.count > 0,
            do: min(100, round(assigns.list.watched * 100 / assigns.list.count)),
            else: nil
          )
      )

    ~H"""
    <.link
      navigate={~p"/lists/#{@list.slug}"}
      class="group relative block overflow-hidden rounded-box bg-neutral-950 p-4 text-white shadow ring-1 ring-white/10 transition duration-300 hover:-translate-y-0.5 hover:ring-white/40 hover:shadow-xl"
      style={"--hue: #{@hue}"}
    >
      <div
        class="absolute inset-0"
        style="background: radial-gradient(120% 140% at 100% -20%, hsl(var(--hue) 85% 48% / 0.5), transparent 60%), linear-gradient(160deg, hsl(var(--hue) 45% 15%) 0%, hsl(var(--hue) 55% 6%) 100%)"
        aria-hidden="true"
      >
      </div>
      <div class="relative">
        <div class="font-semibold tracking-tight">{@list.name}</div>
        <div class="text-sm text-white/65">{describe(@list)}</div>
        <div :if={@percent} class="mt-2 h-[3px] w-full overflow-hidden rounded-full bg-white/15">
          <div
            class="h-full rounded-full bg-gradient-to-r from-cyan-300 to-primary"
            style={"width: #{@percent}%"}
          >
          </div>
        </div>
      </div>
    </.link>
    """
  end

  @doc "\"curated list · 207 titles · 34/207 watched\""
  def describe(list) do
    kind = if list.kind == :tmdb, do: "the series", else: "curated list"
    Enum.join([kind, "#{list.count} titles"] ++ List.wrap(progress(list)), " · ")
  end

  def progress(%{watched: nil}), do: nil
  def progress(%{watched: w, count: c}) when w >= c and c > 0, do: "all watched"
  def progress(%{watched: w, count: c}) when w > 0, do: "#{w}/#{c} watched"
  def progress(_), do: nil
end
