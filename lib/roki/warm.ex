defmodule Roki.Warm do
  @moduledoc """
  Fill the site's own copies for an account in one go, instead of as pages are looked at:
  the finished titles and the ratings (`Roki.Profile`), the whole title of each
  (`Roki.Titles`, through `Roki.Watch.title/3`), and their posters in the media library
  (`Roki.Images`) at the two sizes pages show — the list's and the title page's.

  Everything here is what a page would have done on its first visit, so nothing is fetched
  twice: a title already kept is a lookup, a picture already held is skipped. Run it for an
  account after it connects, or for all of them:

      Roki.Warm.all()
  """
  require Logger

  @doc "Every account that has connected laev."
  def accounts do
    case File.ls(Roki.Laev.base_dir()) do
      {:ok, dirs} -> for d <- dirs, match?({:ok, _}, Ecto.UUID.cast(d)), Roki.Laev.connected?(d), do: d
      _ -> []
    end
  end

  @doc "Warm every connected account, one after the other: `[{uuid, counts}]`."
  def all, do: for(uuid <- accounts(), do: {uuid, run(uuid)})

  @doc """
  Warm one account: `%{watched:, ratings:, titles:, pictures:}` — how many finished titles
  the table holds, how many ratings were copied, how many whole titles are kept, how many
  pictures the library holds for them.
  """
  def run(uuid) when is_binary(uuid) do
    Logger.info("warm #{uuid}: finished titles and ratings")
    Roki.Profile.forget_history(uuid)
    items = Roki.Profile.history(uuid)
    Roki.TTLCache.delete({:ratings_refresh, uuid})
    Roki.Profile.refresh_ratings(uuid)

    # Posters the title store lacks, read through laev forty at a time (it reads eight at once).
    items
    |> Enum.filter(&(&1.poster == nil))
    |> Enum.chunk_every(40)
    |> Enum.each(&Roki.Profile.posters(uuid, &1))

    # The whole title of each, so its page is a lookup: one TMDB read for a title not kept yet.
    keys = for i <- items, i.type != nil, uniq: true, do: {i.type, i.id}
    Logger.info("warm #{uuid}: #{length(keys)} titles")

    titles =
      Enum.count(keys, fn {type, id} ->
        match?({:ok, _}, Roki.Watch.title(type, id, uuid))
      end)

    # The pictures, at the list's size and the title page's, four at a time.
    posters =
      Roki.Profile.history(uuid)
      |> Enum.flat_map(fn i ->
        case i.poster do
          nil -> []
          url -> [url, String.replace(url, "/w342/", "/w500/")]
        end
      end)
      |> Enum.uniq()

    Logger.info("warm #{uuid}: #{length(posters)} pictures")

    pictures =
      posters
      |> Task.async_stream(&Roki.Images.hold/1, max_concurrency: 4, timeout: 60_000, on_timeout: :kill_task)
      |> Enum.count(&match?({:ok, :ok}, &1))

    counts = %{watched: length(items), ratings: map_size(Roki.Profile.ratings(uuid)), titles: titles, pictures: pictures}
    Logger.info("warm #{uuid}: done #{inspect(counts)}")
    counts
  end
end
