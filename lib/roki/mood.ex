defmodule Roki.Mood do
  @moduledoc """
  What you feel like tonight, rather than a genre: *be scared*, *laugh*, *fall in love*. Each
  mood is a handful of TMDB genres (and, where TV has no genre for it, a keyword) across films,
  shows and anime at once, so one answer can mix all three.

  `page/5` is a page of a mood — mixed, or one kind — in an order, cached and kept exactly as
  the Movies/Shows/Anime lists are (`Roki.Browse.cached_page/2`). `hero/1` is the first page of
  every mood, what the home page's picker shows while it turns.
  """

  alias Roki.Browse

  # slug, label, tagline, film genre ids, show genre ids, show keyword ids, accent hue.
  # A film's Thriller or Romance has no genre on TV: TMDB's keyword stands in there, as the
  # Horror filter does on Shows (see `Roki.Genres`).
  @moods [
    %{slug: "scared", label: "Be scared", tagline: "Lights off. Something is in the hallway.", icon: "👻", movie: [27], tv: [], tv_kw: [315_058], hue: 350},
    %{slug: "laugh", label: "Laugh", tagline: "No thinking required. Just the good kind of stupid.", icon: "😂", movie: [35], tv: [35], tv_kw: [], hue: 42},
    %{slug: "love", label: "Fall in love", tagline: "Slow looks, bad timing, a very good last scene.", icon: "💘", movie: [10749], tv: [], tv_kw: [9840], hue: 335},
    %{slug: "thrill", label: "Feel the thrill", tagline: "Hold your breath. Don't trust anyone.", icon: "🔪", movie: [53], tv: [80, 9648], tv_kw: [], hue: 200},
    %{slug: "action", label: "Blow things up", tagline: "Loud, fast, and nobody reloads.", icon: "💥", movie: [28], tv: [10759], tv_kw: [], hue: 22},
    %{slug: "escape", label: "Escape reality", tagline: "Other worlds, other rules, other skies.", icon: "🪐", movie: [14, 878], tv: [10765], tv_kw: [], hue: 268},
    %{slug: "cry", label: "Have a good cry", tagline: "Tissues within reach. You'll be fine.", icon: "🥲", movie: [18], tv: [18], tv_kw: [], hue: 215},
    %{slug: "mystery", label: "Solve a mystery", tagline: "Everyone's lying. Figure out who first.", icon: "🕵️", movie: [9648], tv: [9648], tv_kw: [], hue: 245},
    %{slug: "adventure", label: "Go on an adventure", tagline: "Pack light. Come back different.", icon: "🧭", movie: [12], tv: [10759], tv_kw: [], hue: 150},
    %{slug: "kid", label: "Feel like a kid", tagline: "Bright, kind, and over before bedtime.", icon: "🎈", movie: [16, 10751], tv: [16, 10762, 10751], tv_kw: [], hue: 48},
    %{slug: "past", label: "Travel back in time", tagline: "Real people, old wars, better clothes.", icon: "🏛️", movie: [36, 10752], tv: [10768], tv_kw: [], hue: 30},
    %{slug: "true", label: "Something true", tagline: "It happened. Someone filmed it.", icon: "🎥", movie: [99], tv: [99], tv_kw: [], hue: 185}
  ]

  @kinds [:all, :movies, :shows, :anime]
  @sorts [popular: "Popular", newest: "Newest", top: "Top rated"]

  def all, do: @moods
  def kinds, do: @kinds
  def sorts, do: @sorts

  @doc "The mood named by a slug, or nil (never an atom from input)."
  def get(slug), do: Enum.find(@moods, &(&1.slug == slug))

  @doc "A kind named in an address, else `:all`."
  def kind(value), do: Enum.find(@kinds, :all, &(Atom.to_string(&1) == value))

  @doc "A sort named in an address, else `:popular`."
  def sort(value), do: Enum.find(Keyword.keys(@sorts), :popular, &(Atom.to_string(&1) == value))

  @doc """
  `{:ok, items, more?}` for page `n` of a mood: every kind mixed and ordered together (`:all`),
  or films, shows (anime left out) or anime alone. A mixed page is a film page and a TV page
  merged, so it is up to forty titles.
  """
  def page(slug, kind \\ :all, sort \\ :popular, n \\ 1, uuid \\ nil)
      when kind in @kinds and is_integer(n) and n >= 1 do
    with %{} = mood <- get(slug) || {:error, :no_such_mood},
         sort = if(sort in Keyword.keys(@sorts), do: sort, else: :popular),
         {:ok, {items, more?}} <-
           Browse.cached_page({:mood, slug, kind, sort, n}, fn -> fetch(mood, kind, sort, n, uuid) end) do
      {:ok, items, more?}
    end
  end

  @doc "A mood's page as it is already held, no request: `{:ok, items, more?}` or `:miss`."
  def peek(slug, kind \\ :all, sort \\ :popular, n \\ 1), do: Browse.peek_page({:mood, slug, kind, sort, n})

  @doc """
  The picker's slides: `%{slug => items}`, the first mixed page of every mood with the titles
  that have a backdrop first (the slide is drawn on one). Moods that cannot be read are left out.
  """
  def hero(uuid) do
    @moods
    |> Task.async_stream(fn m -> {m.slug, page(m.slug, :all, :popular, 1, uuid)} end, max_concurrency: 4, timeout: 30_000, on_timeout: :kill_task)
    |> Enum.reduce(%{}, fn
      {:ok, {slug, {:ok, items, _}}}, acc -> Map.put(acc, slug, slide(items))
      _, acc -> acc
    end)
  end

  @doc "The same from what is held already, no request; moods not held yet are left out."
  def hero_peek do
    for m <- @moods, {:ok, items, _} <- [peek(m.slug)], into: %{}, do: {m.slug, slide(items)}
  end

  defp slide(items) do
    {with_backdrop, without} = Enum.split_with(items, & &1[:backdrop])
    Enum.take(with_backdrop ++ without, 10)
  end

  @tv_loose %{"scared" => [9648, 10765], "love" => [18, 35]}

  @doc """
  Does a title belong to a mood, by its TMDB genre ids (`Roki.Genres.known/1`)? A mood TV has
  only as a keyword (scared, love) is taken more loosely there: a show of the genres such shows
  usually carry instead (`@tv_loose`).
  """
  def match?(%{movie: movie}, "movie", ids) when is_list(ids), do: Enum.any?(ids, &(&1 in movie))

  def match?(%{tv: [], slug: slug}, "tv", ids) when is_list(ids),
    do: Enum.any?(ids, &(&1 in Map.get(@tv_loose, slug, [])))

  def match?(%{tv: tv}, "tv", ids) when is_list(ids), do: Enum.any?(ids, &(&1 in tv))
  def match?(_mood, _type, _ids), do: false

  @doc """
  Find one title in a mood: a search (`Roki.Search.search/4`), kept to what belongs to the mood
  by the genres read for each result. Reads up to three pages for eight finds. `{:ok, items}`
  or the search's error.
  """
  def search(client, uuid, query, %{} = mood, pages \\ 3) do
    Enum.reduce_while(1..pages, {:ok, []}, fn page, {:ok, acc} ->
      case Roki.Search.search(client, uuid, query, page) do
        {:ok, items, more?, _franchises, _seen} ->
          keys = for i <- items, do: {i.type, i.id}
          Roki.Genres.fill(keys, uuid, 60)
          known = Roki.Genres.known(keys)
          kept = Enum.filter(items, &match?(mood, &1.type, known[{&1.type, &1.id}]))
          acc = acc ++ kept
          if more? and length(acc) < 8, do: {:cont, {:ok, acc}}, else: {:halt, {:ok, acc}}

        error ->
          {:halt, error}
      end
    end)
  end

  # ── TMDB ───────────────────────────────────────────────────────────

  defp fetch(mood, :all, sort, n, uuid) do
    Roki.Laev.public(uuid, fn ->
      with {:ok, films, more_f?} <- discover(mood, "movie", sort, n, false),
           {:ok, tv, more_t?} <- discover(mood, "tv", sort, n, false) do
        items =
          (films ++ tv)
          |> Enum.uniq_by(&{&1.type, &1.id})
          |> order(sort)

        {:ok, items, more_f? or more_t?}
      end
    end)
  end

  defp fetch(mood, :movies, sort, n, uuid), do: Roki.Laev.public(uuid, fn -> discover(mood, "movie", sort, n, false) end)

  defp fetch(mood, :shows, sort, n, uuid) do
    Roki.Laev.public(uuid, fn ->
      with {:ok, items, more?} <- discover(mood, "tv", sort, n, false), do: {:ok, Browse.filter(:shows, items), more?}
    end)
  end

  defp fetch(mood, :anime, sort, n, uuid), do: Roki.Laev.public(uuid, fn -> discover(mood, "tv", sort, n, true) end)

  # The question put to TMDB for one kind: the mood's genres (any of them), the keyword where TV
  # has no genre, anime narrowed to Japanese animation; only what is out, and only what enough
  # people have rated that the top and the newest are not obscure.
  defp discover(mood, type, sort, n, anime?) do
    genres = if type == "movie", do: mood.movie, else: mood.tv
    date = if type == "movie", do: "primary_release_date", else: "first_air_date"
    today = Date.to_iso8601(Date.utc_today())

    genre_param =
      cond do
        anime? and genres == [] -> [with_genres: "16"]
        anime? -> [with_genres: "16," <> Enum.join(genres, "|")]
        genres == [] -> []
        true -> [with_genres: Enum.join(genres, "|")]
      end

    kw_param = if type == "tv" and mood.tv_kw != [], do: [with_keywords: Enum.join(mood.tv_kw, "|")], else: []
    lang_param = if anime?, do: [with_original_language: "ja"], else: []
    adult = if type == "movie", do: [include_adult: false], else: []

    params =
      [page: n, "#{date}.lte": today] ++ genre_param ++ kw_param ++ lang_param ++ adult ++ order_params(sort, date, type)

    Browse.discover(type, params)
  end

  defp order_params(:popular, _date, _type), do: [sort_by: "popularity.desc", "vote_count.gte": 20]
  defp order_params(:newest, date, _type), do: [sort_by: "#{date}.desc", "vote_count.gte": 20]
  defp order_params(:top, _date, "movie"), do: [sort_by: "vote_average.desc", "vote_count.gte": 1000]
  defp order_params(:top, _date, _type), do: [sort_by: "vote_average.desc", "vote_count.gte": 300]

  # Two lists made in the same order are merged back into one. Popularity is not comparable
  # across kinds (a long-running show scores many times any film), so popular is interleaved by
  # rank — film, show, film, show — rather than by the number; scores and years are comparable.
  defp order(items, :popular) do
    {films, tv} = Enum.split_with(items, &(&1.type == "movie"))
    interleave(films, tv)
  end

  defp order(items, :top), do: Enum.sort_by(items, &(&1.vote || 0), :desc)
  defp order(items, :newest), do: Enum.sort_by(items, &(&1.year || ""), :desc)

  defp interleave([], rest), do: rest
  defp interleave(rest, []), do: rest
  defp interleave([a | as], [b | bs]), do: [a, b | interleave(as, bs)]
end
