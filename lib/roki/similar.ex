defmodule Roki.Similar do
  @moduledoc """
  "More like this": what TMDB recommends for a film or a show, from laev
  (`Laev.Tmdb.recommendations/3`, topped up from its similar list). Public data, so it is read
  with whichever key `Roki.Laev.public/2` picks, kept beside the titles (`Roki.Kept`) for a
  month — recommendations drift slowly — and in memory for half a day.
  """

  alias Roki.TTLCache

  @ttl_s 12 * 3600
  @kept_s 30 * 24 * 3600

  @doc "`{:ok, [card]}` (possibly empty) or `{:error, reason}`."
  def for_title(uuid, type, id) when type in ["movie", "tv"] and id |> is_integer() do
    TTLCache.fetch({:similar, 2, type, id}, @ttl_s, fn ->
      Roki.Kept.fetch("similar", "#{type}:#{id}", @kept_s, fn ->
        with {:ok, cards} = ok <-
               Roki.Laev.public(uuid, fn -> Laev.Tmdb.recommendations(type, id, 12) end) do
          Roki.Titles.remember_later(cards)
          ok
        end
      end)
    end)
  end

  def for_title(_uuid, _type, _id), do: {:ok, []}
end
