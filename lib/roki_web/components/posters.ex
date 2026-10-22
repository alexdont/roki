defmodule RokiWeb.PosterComponents do
  @moduledoc "The poster card shared by every page that lists titles."
  use Phoenix.Component

  attr :item, :map,
    required: true,
    doc: "a title: %{title, poster, type, year?, note?, season?, episode?, vote?}"

  def poster(assigns) do
    ~H"""
    <div class="group space-y-1">
      <div class="aspect-[2/3] overflow-hidden rounded-box bg-base-300 shadow">
        <img
          :if={@item.poster}
          src={@item.poster}
          alt={@item.title}
          loading="lazy"
          class="h-full w-full object-cover transition group-hover:scale-105"
        />
        <div
          :if={!@item.poster}
          class="flex h-full items-center justify-center p-2 text-center text-xs"
        >
          {@item.title}
        </div>
      </div>
      <div class="truncate text-sm font-medium" title={@item.title}>{@item.title}</div>
      <div class="text-xs text-base-content/60">{subtitle(@item)}</div>
    </div>
    """
  end

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
