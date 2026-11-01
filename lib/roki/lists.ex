defmodule Roki.Lists do
  @moduledoc """
  Franchise lists — laev's curated ones and TMDB's own collections.

  Laev ships eleven hand-curated lists (Marvel, Star Wars, Animation …) for the
  franchises TMDB groups badly, and falls back to a TMDB *collection* for every
  other series (John Wick, Pirates of the Caribbean). Both have the same shape —
  a name, and entries in release order — so everything here treats them alike.
  A list is addressed by `slug`: the name, parameterised, for a curated one and
  `collection-<tmdb id>` for a collection.

  A list opens in two steps so the page never waits on TMDB: the entries come
  from the curated file at once (title, year, order), and the posters come from
  laev's card cache a moment later.
  """

  alias Laev.Franchises
  alias Roki.{RateLimit, TTLCache}

  @collection_ttl 24 * 60 * 60

  @doc "Every curated list, biggest first."
  def curated, do: Enum.sort_by(Franchises.all(), &{-length(&1.entries), &1.name})

  def slug(name) when is_binary(name) do
    name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
  end

  @doc "What a list row needs, without carrying the entries around."
  def summary(f) do
    %{
      slug: slug_of(f),
      name: f.name,
      kind: if(Map.get(f, :source) == :tmdb, do: :tmdb, else: :curated),
      count: length(f.entries),
      broad?: Franchises.broad?(f),
      keys: Enum.map(f.entries, &{&1.type, &1.tmdb_id}),
      films: Enum.count(f.entries, &(&1.type == "movie"))
    }
  end

  def summaries, do: Enum.map(curated(), &summary/1)

  @doc """
  The curated lists that a search names, best match first, at most five. A list is named by the
  query when it is the same words (`"star wars"`), when the query goes on from them
  (`"star wars the last jedi"`), when the query (four letters or more) is the start of them (`"marv"`), or — from four
  letters — the start of one of their words (`"ball"` for Dragon Ball). Accents, case and
  punctuation do not matter; under three letters nothing is named.
  """
  def matching(query) when is_binary(query) do
    q = fold(query)

    if String.length(q) < 3 do
      []
    else
      curated()
      |> Enum.flat_map(fn f ->
        case match_rank(fold(f.name), q) do
          nil -> []
          rank -> [{rank, f}]
        end
      end)
      |> Enum.sort_by(fn {rank, f} -> {rank, -length(f.entries), f.name} end)
      |> Enum.take(5)
      |> Enum.map(&elem(&1, 1))
    end
  end

  def matching(_), do: []

  defp match_rank(name, q) do
    cond do
      name == q -> 0
      String.length(name) >= 3 and String.contains?(" " <> q <> " ", " " <> name <> " ") -> 1
      String.length(q) >= 4 and String.starts_with?(name, q) -> 2
      String.length(q) >= 4 and String.contains?(" " <> name, " " <> q) -> 3
      true -> nil
    end
  end

  defp fold(text) do
    text
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, " ")
    |> String.trim()
  end

  @doc """
  A few posters for each list, for the cards of the Featured page: `%{slug => [url]}`. Only
  titles the site has already kept a picture of are used (one query, no TMDB), so a list whose
  titles nobody has opened simply has none, and its card is drawn without.
  """
  def previews(summaries, per \\ 3) do
    firsts = Map.new(summaries, &{&1.slug, Enum.take(&1.keys, 14)})
    cards = Roki.Titles.cards(firsts |> Map.values() |> List.flatten())

    Map.new(firsts, fn {slug, keys} ->
      posters =
        keys
        |> Enum.map(&cards[&1])
        |> Enum.filter(&(&1 && &1.poster))
        |> Enum.take(per)
        |> Enum.map(& &1.poster)

      {slug, posters}
    end)
  end

  defp slug_of(%{source: :tmdb, id: id}), do: "collection-#{id}"
  defp slug_of(f), do: slug(f.name)

  @doc """
  Adds `:watched` — how many of the list's entries this user has seen, by laev's
  own rule — or `nil` when they have not connected laev.
  """
  def with_progress(uuid, summaries) do
    if uuid && Roki.Laev.connected?(uuid) do
      Roki.Laev.run(uuid, fn ->
        seen =
          summaries
          |> Enum.flat_map(& &1.keys)
          |> Enum.uniq()
          |> Enum.map(fn {type, id} -> %{type: type, id: id} end)
          |> Roki.Laev.seen_keys()

        Enum.map(summaries, fn s ->
          Map.put(s, :watched, Enum.count(s.keys, &MapSet.member?(seen, &1)))
        end)
      end)
    else
      Enum.map(summaries, &Map.put(&1, :watched, nil))
    end
  end

  @doc "`{:ok, franchise}` for a slug, or `:error`."
  def find(slug, uuid \\ nil)

  def find("collection-" <> id, uuid) do
    with {n, ""} <- Integer.parse(id), {:ok, f} <- tmdb_collection(n, uuid) do
      {:ok, f}
    else
      _ -> :error
    end
  end

  def find(slug, _uuid) do
    case Enum.find(Franchises.all(), &(slug(&1.name) == slug)) do
      nil -> :error
      f -> {:ok, f}
    end
  end

  @doc """
  One of TMDB's collections as a franchise (kept beside the titles for a fortnight — a new film
  joins now and then — and in memory a day), `{:error, _}` when it is not a series.
  """
  def tmdb_collection(id, uuid \\ nil) when is_integer(id) do
    TTLCache.fetch({:collection, 2, id}, @collection_ttl, fn ->
      Roki.Kept.fetch("collection", Integer.to_string(id), 14 * 24 * 3600, fn ->
        Roki.Laev.public(uuid, fn ->
          case Laev.Tmdb.collection(id) do
            {:ok, %{"parts" => parts, "name" => name}} when length(parts) > 1 ->
              {:ok, collection_franchise(id, name, parts)}

            {:ok, _} ->
              {:error, :not_found}

            {:error, _} = error ->
              error
          end
        end)
      end)
    end)
  end

  # In the shape of a curated franchise, so the page can't tell the difference.
  defp collection_franchise(id, name, parts) do
    %{
      name: String.replace(name, ~r/ Collection$/, ""),
      source: :tmdb,
      id: id,
      broad: false,
      tiers: [],
      entries:
        parts
        |> Enum.map(
          &%{
            type: "movie",
            tmdb_id: &1["id"],
            season: nil,
            title: &1["title"],
            date: &1["release_date"] || "",
            tiers: [],
            rename: nil
          }
        )
        |> Enum.sort_by(&if(&1.date in [nil, ""], do: "9999", else: &1.date))
    }
  end

  # ── a list's titles ────────────────────────────────────────────────

  def entries(franchise, tier), do: Franchises.entries(franchise, tier)

  @doc """
  The poster of each entry that is a season of a show, by `{tmdb_id, season}`: what
  `Roki.SeasonPosters` keeps, read now for the first few shows and behind the page for the rest.
  """
  def season_posters(entries, uuid) do
    entries
    |> Enum.map(&base_item/1)
    |> Roki.SeasonPosters.apply(uuid)
    |> Enum.filter(& &1.poster)
    |> Map.new(&{{&1.id, &1.season}, &1.poster})
  end

  @doc "A title straight from the curated file — everything but the poster."
  def base_item(entry) do
    %{
      id: entry.tmdb_id,
      type: entry.type,
      season: entry.season,
      title: season_title(entry[:rename] || entry.title, entry.season),
      year: Laev.Tmdb.year(entry.date),
      poster: nil,
      vote: nil
    }
  end

  @doc "The same title with what TMDB says about it, when we have it."
  def item(entry, cards) do
    case Map.fetch(cards, {entry.type, entry.tmdb_id}) do
      {:ok, details} ->
        %{
          base_item(entry)
          | title:
              season_title(
                entry[:rename] || details["title"] || details["name"] || entry.title,
                entry.season
              ),
            year:
              Laev.Tmdb.year(details["release_date"] || details["first_air_date"]) ||
                Laev.Tmdb.year(entry.date),
            poster: Laev.Tmdb.poster_url(details["poster_path"], "w342"),
            vote: details["vote_average"]
        }

      :error ->
        base_item(entry)
    end
  end

  defp season_title(name, nil), do: name
  defp season_title(name, season), do: "#{name} · Season #{season}"

  @doc """
  TMDB's cards for a list's titles, through laev's own card cache — a list of
  two hundred is two hundred requests the first time and none after, so the first
  open is rate limited and only one visitor at a time does it.
  """
  def cards(client, uuid, slug, entries) do
    keys = entries |> Enum.map(&{&1.type, &1.tmdb_id}) |> Enum.uniq()

    Roki.Laev.public(uuid, fn ->
      :global.trans({{__MODULE__, :cards, slug}, self()}, fn ->
        missing = keys -- Map.keys(Laev.Cards.get_many(keys))

        with :ok <- budget(client, missing) do
          {:ok, Laev.Shelf.load_cards(keys, fn _line -> :ok end)}
        end
      end)
    end)
  end

  defp budget(_client, []), do: :ok

  defp budget(client, _missing) do
    with :ok <- RateLimit.check(:list_cards, client, 6, 60_000) do
      RateLimit.check(:list_cards_global, :all, 60, 60_000)
    end
  end
end
