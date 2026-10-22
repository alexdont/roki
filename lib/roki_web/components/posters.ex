defmodule RokiWeb.PosterComponents do
  @moduledoc "The poster card shared by every page that lists titles."
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: RokiWeb.Endpoint,
    router: RokiWeb.Router,
    statics: RokiWeb.static_paths()

  attr :item, :map,
    required: true,
    doc: "a title: %{title, poster, type, year?, note?, season?, episode?, vote?, seen?}"

  attr :seen, :boolean, default: nil, doc: "watched? Falls back to the item's own :seen"

  attr :cached_titles, :any,
    default: nil,
    doc: "MapSet of {type, id} with cached sources: those posters say so"

  def poster(assigns) do
    assigns =
      assign(
        assigns,
        :watched?,
        assigns.seen || (assigns.seen == nil && assigns.item[:seen] == true)
      )

    assigns =
      assign(assigns,
        href: href(assigns.item),
        cached?:
          match?(%MapSet{}, assigns.cached_titles) and
            MapSet.member?(assigns.cached_titles, {assigns.item[:type], assigns.item[:id]})
      )

    ~H"""
    <.card href={@href} class={["group block space-y-1", @watched? && "opacity-50"]}>
      <div class="relative aspect-[2/3] overflow-hidden rounded-box bg-base-300 shadow">
        <img
          :if={@item.poster}
          src={@item.poster}
          alt={@item.title}
          loading="lazy"
          class={[
            "h-full w-full object-cover transition group-hover:scale-105",
            @watched? && "grayscale"
          ]}
        />
        <span
          :if={@item[:badge]}
          class="badge badge-primary badge-sm absolute right-1.5 top-1.5 shadow"
        >
          {@item[:badge]}
        </span>
        <span
          :if={@cached?}
          class="badge badge-success badge-sm absolute bottom-1.5 left-1.5 gap-1 shadow"
          title="Sources are cached: plays right away"
        >
          ⚡ cached
        </span>
        <span
          :if={@watched?}
          class="absolute left-1.5 top-1.5 flex h-6 w-6 items-center justify-center rounded-full bg-success text-success-content shadow"
          title="Watched"
        >
          <svg viewBox="0 0 20 20" fill="currentColor" class="h-4 w-4" aria-hidden="true">
            <path
              fill-rule="evenodd"
              d="M16.7 5.3a1 1 0 0 1 0 1.4l-7.5 7.5a1 1 0 0 1-1.4 0L3.3 9.7a1 1 0 1 1 1.4-1.4l3.8 3.8 6.8-6.8a1 1 0 0 1 1.4 0Z"
              clip-rule="evenodd"
            />
          </svg>
        </span>
        <div
          :if={!@item.poster}
          class="flex h-full items-center justify-center p-2 text-center text-xs"
        >
          {@item.title}
        </div>
      </div>
      <div class="truncate text-sm font-medium" title={@item.title}>{@item.title}</div>
      <div class="text-xs text-base-content/60">
        {if @watched?, do: "Watched · ", else: ""}{subtitle(@item)}
      </div>
    </.card>
    """
  end

  attr :href, :any, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true

  defp card(%{href: nil} = assigns), do: ~H"<div class={@class}>{render_slot(@inner_block)}</div>"

  defp card(assigns),
    do: ~H"<.link navigate={@href} class={@class}>{render_slot(@inner_block)}</.link>"

  @doc "Where a poster leads: the title page (a franchise season entry opens on its season)."
  def href(%{id: id, type: type} = item)
      when is_integer(id) and type in ["movie", "tv", "anime"] do
    type = if type == "movie", do: "movie", else: "tv"

    case item do
      %{season: s} when is_integer(s) -> ~p"/title/#{type}/#{id}?#{[s: s]}"
      _ -> ~p"/title/#{type}/#{id}"
    end
  end

  def href(_), do: nil

  @doc "The grey line under a poster — where you are in it, else when it came out."
  def subtitle(%{note: n}) when is_binary(n) and n != "",
    do: n |> String.trim() |> String.trim_leading("·") |> String.trim()

  def subtitle(%{season: s, episode: e}) when is_integer(s) and is_integer(e),
    do: "S#{s} · E#{e}"

  def subtitle(%{episode: e}) when is_integer(e), do: "Episode #{e}"

  def subtitle(%{year: y, vote: v}) when is_binary(y) and y != "" and is_number(v) and v > 0,
    do: "#{y} · ★#{Float.round(v * 1.0, 1)}"

  def subtitle(%{year: y}) when is_binary(y) and y != "", do: y
  def subtitle(%{type: "movie"}), do: "Film"
  def subtitle(%{type: "tv"}), do: "Series"
  def subtitle(_), do: ""
end
