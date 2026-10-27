defmodule Roki.Browse do
  @moduledoc """
  The pages behind Movies, Shows and Anime: one kind of title, in an order you choose, a page
  at a time.

  *Popular* is exactly what the Featured page shows (`Roki.Featured`: trending films and shows,
  anime airing now). The other orders — newest, oldest, top rated — are TMDB's discover lists,
  limited to what is already out and to titles enough people have rated that the oldest and the
  newest are not obscure. Anime has one more: Anime Corner's weekly ranking of the season
  (`Roki.AnimeCorner`). Every page is remembered for an hour; who pays for the lookup is
  `Roki.Laev.public/2`'s call, as everywhere else.
  """

  alias Roki.{Featured, TTLCache}

  @kinds [:movies, :shows, :anime]
  @sorts [
    popular: "Popular",
    newest: "Newest",
    oldest: "Oldest",
    top: "Top rated",
    corner: "Anime Corner ranking"
  ]
  @ttl_s 60 * 60
  @base "https://api.themoviedb.org/3"

  def kinds, do: @kinds
  def sorts, do: @sorts

  @doc """
  The orders a kind offers: the Anime Corner ranking is anime's alone, and with a season chosen
  the choice is between the season's own order and that ranking of the season.
  """
  def sorts(:anime, nil), do: @sorts
  def sorts(:anime, _season), do: [popular: "Most popular", corner: "Anime Corner ranking"]
  def sorts(_kind, _season), do: Keyword.delete(@sorts, :corner)

  @doc "The sort named by a string (from a URL), never made into an atom from the input."
  def sort(value),
    do: Enum.find_value(@sorts, :popular, fn {k, _} -> Atom.to_string(k) == value && k end)

  @doc """
  `{:ok, items, more?}` for page `n`, or `{:error, reason}`. `season` (anime only) is
  `{year, :summer}`: everything of that quarter — what premiered in it, and what had episodes
  in it —, most popular first. It replaces the order, except the Anime Corner ranking, which
  then is that season's (of `week`, or the latest posted); without a season, this season's.
  """
  def page(kind, sort, n, uuid, season \\ nil, week \\ nil, genre \\ nil)
      when kind in @kinds and is_integer(n) and n >= 1 do
    sort = if sort in Keyword.keys(sorts(kind, nil)), do: sort, else: :popular
    season = if kind == :anime, do: season
    week = if sort == :corner, do: week

    # A genre narrows what TMDB is asked for. Anime Corner's ranking is a fixed list with no genres.
    genre =
      if sort != :corner and genre in Enum.map(Roki.Genres.browse_options(kind), &elem(&1, 0)),
        do: genre

    with {:ok, {items, more?}} <-
           TTLCache.fetch({:browse, kind, sort, season, week, genre, n}, @ttl_s, fn ->
             with {:ok, items, more?} <- fetch(kind, sort, n, uuid, season, week, genre) do
               Roki.Titles.remember_later(items)
               {:ok, {items, more?}}
             end
           end) do
      {:ok, items, more?}
    end
  end

  @doc "The season named by `?season=summer&year=2026`, or nil."
  def season(season, year) do
    with name when is_binary(season) <- season,
         atom when not is_nil(atom) <- Enum.find(Laev.Season.all(), &(Atom.to_string(&1) == name)),
         {y, ""} when y >= 1960 and y <= 2100 <- Integer.parse(to_string(year)) do
      {y, atom}
    else
      _ -> nil
    end
  end

  @doc "The years the season picker offers: next year back to 1960 (anime television starts in 1963)."
  def years(today \\ Date.utc_today()), do: (today.year + 1)..1960//-1

  # The ranking is one page; the titles are TMDB's, matched by Roki.AnimeCorner.
  defp fetch(:anime, :corner, 1, uuid, season, week, _genre) do
    with {:ok, %{items: items}} <-
           Roki.AnimeCorner.items(uuid, season || Laev.Season.current(), week),
         do: {:ok, big(items), false}
  end

  defp fetch(:anime, :corner, _n, _uuid, _season, _week, _genre), do: {:ok, [], false}

  # A season is what premiered in it (laev's list) and what had episodes in it: the new seasons
  # of older shows, which a premiere window leaves out (Reincarnated as a Sword's second season
  # started in 2022's), and the long-runners. Both lists are by popularity, a page of each.
  defp fetch(:anime, _sort, n, uuid, {_year, _season} = season, _week, genre) do
    Roki.Laev.public(uuid, fn ->
      with {:ok, premiered, more1?} <- premiered(season, n, genre),
           {:ok, airing, more2?} <- airing(season, n, genre) do
        items =
          (airing ++ premiered)
          |> Enum.uniq_by(& &1.id)
          |> Enum.sort_by(&(&1.popularity || 0), :desc)

        {:ok, big(items), more1? or more2?}
      end
    end)
  end

  defp fetch(kind, sort, n, uuid, _season, _week, genre), do: fetch(kind, sort, n, uuid, genre)

  # What premiered in the season: laev's own list, or — with a genre, which laev's cannot take —
  # the same question put to TMDB directly.
  defp premiered(season, n, nil), do: Laev.Tmdb.discover_anime_season(season, n)

  defp premiered(season, n, genre) do
    {from, to} = Laev.Season.window(season)

    with {:ok, body} <-
           get(
             "/discover/tv",
             [
               with_genres: anime_genres(genre),
               with_original_language: "ja",
               sort_by: "popularity.desc",
               "first_air_date.gte": from,
               "first_air_date.lte": to,
               page: n
             ] ++ keyword_params(genre, :anime)
           ) do
      {:ok, Enum.map(body["results"] || [], &normalize(&1, "tv")), n < (body["total_pages"] || 1)}
    end
  end

  # Anime is Animation, and the genre on top of it.
  defp anime_genres(nil), do: 16

  defp anime_genres(genre) do
    case Roki.Genres.with_genres(genre, :anime) do
      "" -> 16
      ids -> "16," <> ids
    end
  end

  # A genre shows has only as a keyword (Horror): the extra discover parameter for it.
  defp keyword_params(nil, _kind), do: []

  defp keyword_params(genre, kind) do
    case Roki.Genres.keyword(genre, kind) do
      nil -> []
      id -> [with_keywords: id]
    end
  end

  defp airing(season, n, genre) do
    {from, to} = Laev.Season.window(season)

    with {:ok, body} <-
           get(
             "/discover/tv",
             [
               with_genres: anime_genres(genre),
               with_original_language: "ja",
               sort_by: "popularity.desc",
               "air_date.gte": from,
               "air_date.lte": to,
               page: n
             ] ++ keyword_params(genre, :anime)
           ) do
      {:ok, Enum.map(body["results"] || [], &normalize(&1, "tv")), n < (body["total_pages"] || 1)}
    end
  end

  # Popular is the Featured page's own list, so the two never disagree.
  defp fetch(kind, :popular, n, uuid, nil) do
    with {:ok, items, more?} <- Featured.page(kind, n, uuid), do: {:ok, big(items), more?}
  end

  # Trending cannot be filtered by genre, so a genre's "Popular" is TMDB's most popular of it.
  defp fetch(kind, sort, n, uuid, genre) do
    Roki.Laev.public(uuid, fn ->
      with {:ok, body} <- get(path(kind), params(kind, sort, n, Date.utc_today(), genre)) do
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
  def params(kind, sort, n, today \\ Date.utc_today(), genre \\ nil) do
    date = if kind == :movies, do: :primary_release_date, else: :first_air_date
    today = Date.to_iso8601(today)

    base =
      [page: n, "#{date}.lte": today] ++
        if(kind == :movies, do: [include_adult: false], else: []) ++
        if(kind == :anime,
          do: [with_genres: anime_genres(genre), with_original_language: "ja"],
          else: []
        ) ++
        if(kind != :anime and genre != nil and Roki.Genres.ids(genre, kind) != [],
          do: [with_genres: Roki.Genres.with_genres(genre, kind)],
          else: []
        ) ++ keyword_params(genre, kind)

    base ++ order(kind, sort, date)
  end

  # How many ratings a title needs before its order counts: enough that the oldest and the
  # top rated are what people know, few enough that the newest are not all missing.
  # The default order is popularity: what "Popular" means once a genre takes it off the trending list.
  defp order(_kind, :popular, _date), do: [sort_by: "popularity.desc", "vote_count.gte": 20]

  defp order(kind, :newest, date),
    do: [sort_by: "#{date}.desc", "vote_count.gte": min_votes(kind, :newest)]

  defp order(kind, :oldest, date),
    do: [sort_by: "#{date}.asc", "vote_count.gte": min_votes(kind, :oldest)]

  defp order(kind, :top, _date),
    do: [sort_by: "vote_average.desc", "vote_count.gte": min_votes(kind, :top)]

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
  defp big(items),
    do:
      Enum.map(
        items,
        &Map.update(&1, :poster, nil, fn p -> p && String.replace(p, "/w342/", "/w500/") end)
      )

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
