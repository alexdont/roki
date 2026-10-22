defmodule RokiWeb.ListComponents do
  @moduledoc "How a franchise list is drawn where it is offered — search results and the Lists page."
  use RokiWeb, :html

  attr :list, :map, required: true, doc: "a `Roki.Lists.summary/1` with `:watched`"

  def list_card(assigns) do
    ~H"""
    <.link
      navigate={~p"/lists/#{@list.slug}"}
      class="card bg-base-200 p-4 transition hover:bg-base-300"
    >
      <div class="font-semibold">🎬 {@list.name}</div>
      <div class="text-sm text-base-content/60">{describe(@list)}</div>
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
