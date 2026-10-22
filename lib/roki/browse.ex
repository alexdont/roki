defmodule Roki.Browse do
  @moduledoc """
  The pages behind Movies, Shows and Anime: one kind of title, in an order you choose, a page
  at a time.

  *Popular* is exactly what the Featured page shows (`Roki.Featured`: trending films and shows,
  anime airing now). The other orders — newest, oldest, top rated — are TMDB's discover lists,
  limited to what is already out and to titles enough people have rated that the oldest and the
  newest are not obscure. Every page is remembered for an hour; who pays for the lookup is
  `Roki.Laev.public/2`'s call, as everywhere else.
  """

  alias Roki.{Featured, TTLCache}

  @kinds [:movies, :shows, :anime]
  @sorts [popular: "Popular", newest: "Newest", oldest: "Oldest", top: "Top rated"]
  @ttl_s 60 * 60
  @base "https://api.themoviedb.org/3"

  def kinds, do: @kinds
  def sorts, do: @sorts

  @doc "The sort named by a string (from a URL), never made into an atom from the input."
  def sort(value), do: Enum.find_value(@sorts, :popular, fn {k, _} -> Atom.to_string(k) == value && k end)

  @doc "`{:ok, items, more?}` for page `n`, or `{:error, reason}`."
  def page(kind, sort, n, uuid) when kind in @kinds and is_integer(n) and n >= 1 do
    sort = if sort in Keyword.keys(@sorts), do: sort, else: :popular

    with {:ok, {items, more?}} <-
           TTLCache.fetch({:browse, kind, sort, n}, @ttl_s, fn ->
             with {:ok, items, more?} <- fetch(kind, sort, n, uuid), do: {:ok, {items, more?}}
           end) do
      {:ok, items, more?}
    end
  end

  # Popular is the Featured page's own list, so the two never disagree.
  defp fetch(kind, :popular, n, uuid) do
    with {:ok, items, more?} <- Featured.page(kind, n, uuid), do: {:ok, big(items), more?}
  end

  defp fetch(kind, sort, n, uuid) do
    Roki.Laev.public(uuid, fn ->
      with {:ok, body} <- get(path(kind), params(kind, sort, n)) do
        type = if kind == :movies, do: "movie", else: "tv"
        items = Enum.map(body["results"] || [], &normalize(&1, type))
        {:ok, filter(kind, items), n < (body["total_pages"] || 1)}
      end
    end)
  end

  @doc false
  def path(:movies), do: "/discover/movie"
  def path(_kind), do: "/discover/tv"

  @doc false
  def params(kind, sort, n, today \\ Date.utc_today()) do
    date = if kind == :movies, do: :primary_release_date, else: :first_air_date
    today = Date.to_iso8601(today)

    base =
      [page: n, "#{date}.lte": today] ++
        if(kind == :movies, do: [include_adult: false], else: []) ++
        if(kind == :anime, do: [with_genres: 16, with_original_language: "ja"], else: [])

    base ++ order(kind, sort, date)
  end

  # How many ratings a title needs before its order counts: enough that the oldest and the
  # top rated are what people know, few enough that the newest are not all missing.
  defp order(kind, :newest, date), do: [sort_by: "#{date}.desc", "vote_count.gte": min_votes(kind, :newest)]
  defp order(kind, :oldest, date), do: [sort_by: "#{date}.asc", "vote_count.gte": min_votes(kind, :oldest)]
  defp order(kind, :top, _date), do: [sort_by: "vote_average.desc", "vote_count.gte": min_votes(kind, :top)]

  defp min_votes(:movies, :newest), do: 20
  defp min_votes(:movies, :oldest), do: 300
  defp min_votes(:movies, :top), do: 2000
  defp min_votes(_kind, :newest), do: 10
  defp min_votes(:shows, :oldest), do: 200
  defp min_votes(:shows, :top), do: 1000
  defp min_votes(:anime, :oldest), do: 100
  defp min_votes(:anime, :top), do: 300

  # Shows leaves out what MyAnimeList lists, as on the Featured page.
  defp filter(:shows, items) do
    case Laev.AnimeMap.ensure() do
      {:ok, _} -> Featured.without_anime(items, &Laev.AnimeMap.anime?("tv", &1))
      _ -> items
    end
  end

  defp filter(_kind, items), do: items

  defp normalize(r, type) do
    date = r["release_date"] || r["first_air_date"]

    %{
      id: r["id"],
      type: type,
      title: r["title"] || r["name"],
      year: Laev.Tmdb.year(date),
      overview: r["overview"],
      poster: r["poster_path"] && "https://image.tmdb.org/t/p/w500#{r["poster_path"]}",
      vote: r["vote_average"],
      popularity: r["popularity"]
    }
  end

  # The same lists come back with bigger pictures, for the larger grid.
  defp big(items), do: Enum.map(items, &Map.update(&1, :poster, nil, fn p -> p && String.replace(p, "/w342/", "/w500/") end))

  # TMDB discover, with the key of whoever's scope this runs in (as `Laev.Tmdb` does).
  defp get(path, params) do
    case Laev.Scope.get(:tmdb_key) do
      key when is_binary(key) and key != "" ->
        {auth, params} =
          if String.starts_with?(key, "eyJ"),
            do: {[auth: {:bearer, key}], params},
            else: {[], Keyword.put(params, :api_key, key)}

        case Req.get(Req.new(base_url: @base, retry: false), [url: path, params: params] ++ auth) do
          {:ok, %{status: s, body: body}} when s in 200..299 -> {:ok, body}
          {:ok, %{status: s}} -> {:error, {:tmdb, s}}
          {:error, e} -> {:error, e}
        end

      _ ->
        {:error, :no_tmdb_key}
    end
  end
end
