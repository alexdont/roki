defmodule Roki.Similar do
  @moduledoc """
  "More like this": what TMDB recommends for a film or a show, from laev
  (`Laev.Tmdb.recommendations/3`, topped up from its similar list). Public data, so it is read
  with whichever key `Roki.Laev.public/2` picks and kept for everyone half a day.
  """

  alias Roki.TTLCache

  @ttl_s 12 * 3600

  @doc "`{:ok, [card]}` (possibly empty) or `{:error, reason}`."
  def for_title(uuid, type, id) when type in ["movie", "tv"] and is_integer(id) do
    TTLCache.fetch({:similar, type, id}, @ttl_s, fn ->
      Roki.Laev.public(uuid, fn -> Laev.Tmdb.recommendations(type, id, 12) end)
    end)
  end

  def for_title(_uuid, _type, _id), do: {:ok, []}
end
