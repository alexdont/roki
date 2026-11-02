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

  # slug, label, tagline, film genre ids, show genre ids, show keyword ids, accent hue, and the
  # typeface its name is set in. A mood has no picture of its own: it is its name, set in its own
  # typeface, in its own colour, and the number it has in the list (`number/1`) (Google Fonts, linked from the root layout; `@fonts` below lists
  # what to ask for there).
  # `movie_not`, `tv_not`, `tv_not_kw`: what a mood leaves out even when a title also has one of its
  # genres — a comedy that is also a horror film is a horror film, and not for a night of laughing.
  # A film's Thriller or Romance has no genre on TV: TMDB's keyword stands in there, as the
  # Horror filter does on Shows (see `Roki.Genres`).
  @moods [
    %{
      slug: "scared",
      font: "'Creepster', cursive",
      label: "Be scared",
      tagline: "Lights off. Something is in the hallway.",
      movie: [27],
      tv: [],
      tv_kw: [315_058],
      hue: 350,
      movie_not: [35, 10751],
      tv_not: [35]
    },
    %{
      slug: "laugh",
      font: "'Bangers', cursive",
      label: "Laugh",
      tagline: "No thinking required. Just the good kind of stupid.",
      movie: [35],
      tv: [35],
      tv_kw: [],
      hue: 42,
      movie_not: [27, 53, 10752],
      tv_not: [10768],
      tv_not_kw: [315_058]
    },
    %{
      slug: "love",
      font: "'Pacifico', cursive",
      label: "Fall in love",
      tagline: "Slow looks, bad timing, a very good last scene.",
      movie: [10749],
      tv: [],
      tv_kw: [9840],
      hue: 335,
      movie_not: [27, 53],
      tv_not_kw: [315_058]
    },
    %{
      slug: "thrill",
      font: "'Special Elite', monospace",
      label: "Feel the thrill",
      tagline: "Hold your breath. Don't trust anyone.",
      movie: [53],
      tv: [80, 9648],
      tv_kw: [],
      hue: 200,
      movie_not: [35, 10751, 16],
      tv_not: [35, 16, 10762]
    },
    %{
      slug: "action",
      font: "'Black Ops One', system-ui",
      label: "Blow things up",
      tagline: "Loud, fast, and nobody reloads.",
      movie: [28],
      tv: [10759],
      tv_kw: [],
      hue: 22,
      movie_not: [27],
      tv_not_kw: [315_058]
    },
    %{
      slug: "escape",
      font: "'Orbitron', sans-serif",
      label: "Escape reality",
      tagline: "Other worlds, other rules, other skies.",
      movie: [14, 878],
      tv: [10765],
      tv_kw: [],
      hue: 268,
      movie_not: [27],
      tv_not_kw: [315_058]
    },
    %{
      slug: "cry",
      font: "'Playfair Display', serif",
      label: "Have a good cry",
      tagline: "Tissues within reach. You'll be fine.",
      movie: [18],
      tv: [18],
      tv_kw: [],
      hue: 215,
      movie_not: [27, 28, 53],
      tv_not: [10759],
      tv_not_kw: [315_058]
    },
    %{
      slug: "mystery",
      font: "'IM Fell English', serif",
      label: "Solve a mystery",
      tagline: "Everyone's lying. Figure out who first.",
      movie: [9648],
      tv: [9648],
      tv_kw: [],
      hue: 245,
      movie_not: [27],
      tv_not_kw: [315_058]
    },
    %{
      slug: "adventure",
      font: "'Rye', serif",
      label: "Go on an adventure",
      tagline: "Pack light. Come back different.",
      movie: [12],
      tv: [10759],
      tv_kw: [],
      hue: 150,
      movie_not: [27, 53],
      tv_not_kw: [315_058]
    },
    %{
      slug: "kid",
      font: "'Fredoka', sans-serif",
      label: "Feel like a kid",
      tagline: "Bright, kind, and over before bedtime.",
      movie: [16, 10751],
      tv: [16, 10762, 10751],
      tv_kw: [],
      hue: 48,
      movie_not: [27, 53, 80, 10752],
      tv_not: [80],
      tv_not_kw: [315_058]
    },
    %{
      slug: "past",
      font: "'Cinzel', serif",
      label: "Travel back in time",
      tagline: "Real people, old wars, better clothes.",
      movie: [36, 10752],
      tv: [10768],
      tv_kw: [],
      hue: 30
    },
    %{
      slug: "true",
      font: "'Courier Prime', monospace",
      label: "Something true",
      tagline: "It happened. Someone filmed it.",
      movie: [99],
      tv: [99],
      tv_kw: [],
      hue: 185
    }
  ]

  @kinds [:all, :movies, :shows, :anime]
  @sorts [popular: "Popular", newest: "Newest", top: "Top rated"]

  @doc """
  The mood's place in the list, as the two digits it is shown with: `"03"`. Moods are numbered
  the way a programme numbers its films, which is what stands where a pictogram would.
  """
  def number(%{slug: slug}), do: number(slug)

  def number(slug) when is_binary(slug) do
    case Enum.find_index(@moods, &(&1.slug == slug)) do
      nil -> "00"
      i -> (i + 1) |> Integer.to_string() |> String.pad_leading(2, "0")
    end
  end

  @doc "How many moods there are."
  def count, do: length(@moods)

  @doc "The Google Fonts families the moods' names are set in, as the `family=` query asks for them."
  def fonts,
    do:
      ~w(Creepster Bangers Pacifico Special+Elite Black+Ops+One Orbitron:wght@700 Playfair+Display:ital,wght@1,700 IM+Fell+English Rye Fredoka:wght@700 Cinzel:wght@700 Courier+Prime:wght@700)

  def all, do: @moods
  def kinds, do: @kinds
  def sorts, do: @sorts

  @doc "The mood named by a slug, or nil (never an atom from input)."
  def get(slug), do: Enum.find(@moods, &(&1.slug == slug)) || Roki.Seasonal.get(slug)

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
           Browse.cached_page(key(slug, kind, sort, n), fn ->
             fetch(mood, kind, sort, n, uuid)
           end) do
      {:ok, items, more?}
    end
  end

  # Bumped when what a kept page contains changes (the keywords a season is asked for, say).
  @cache_version 5

  @doc false
  def key(slug, kind, sort, n), do: {:mood, @cache_version, slug, kind, sort, n}

  @doc "A mood's page as it is already held, no request: `{:ok, items, more?}` or `:miss`."
  def peek(slug, kind \\ :all, sort \\ :popular, n \\ 1),
    do: Browse.peek_page(key(slug, kind, sort, n))

  @doc """
  The picker's slides: `%{slug => items}`, the first mixed page of every mood with the titles
  that have a backdrop first (the slide is drawn on one). Moods that cannot be read are left out.
  """
  def hero(uuid) do
    @moods
    |> Task.async_stream(fn m -> {m.slug, page(m.slug, :all, :popular, 1, uuid)} end,
      max_concurrency: 4,
      timeout: 30_000,
      on_timeout: :kill_task
    )
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

  defp fetch(mood, :movies, sort, n, uuid),
    do: Roki.Laev.public(uuid, fn -> discover(mood, "movie", sort, n, false) end)

  defp fetch(mood, :shows, sort, n, uuid) do
    Roki.Laev.public(uuid, fn ->
      with {:ok, items, more?} <- discover(mood, "tv", sort, n, false),
           do: {:ok, Browse.filter(:shows, items), more?}
    end)
  end

  defp fetch(mood, :anime, sort, n, uuid),
    do: Roki.Laev.public(uuid, fn -> discover(mood, "tv", sort, n, true) end)

  # The question put to TMDB for one kind: the mood's genres (any of them), the keyword where TV
  # has no genre, anime narrowed to Japanese animation; only what is out, and only what enough
  # people have rated that the top and the newest are not obscure.
  #
  # "Popular" leans new: what people want tonight is mostly what came out in the last few years,
  # so it is the popular of those — with the all-time greats of the mood (a high score from very
  # many people, whatever their age) dealt in one in four, because a classic is a classic.
  @recent_years 8

  defp discover(mood, type, :popular, n, anime?) do
    today = Date.utc_today()
    cutoff = Date.to_iso8601(%{today | year: today.year - @recent_years})
    date = date_field(type)

    with {:ok, recent, more?} <-
           ask(mood, type, n, anime?,
             sort_by: "popularity.desc",
             "vote_count.gte": 50,
             "#{date}.gte": cutoff
           ),
         {:ok, classics, _} <-
           ask(mood, type, n, anime?,
             sort_by: "vote_average.desc",
             "vote_count.gte": classic_votes(type),
             "#{date}.lt": cutoff
           ) do
      {:ok, deal(recent, classics, 3) |> Enum.uniq_by(& &1.id), more?}
    end
  end

  defp discover(mood, type, sort, n, anime?),
    do: ask(mood, type, n, anime?, order_params(sort, date_field(type), type))

  defp ask(mood, type, n, anime?, order) do
    genres = if type == "movie", do: mood.movie, else: mood.tv
    today = Date.to_iso8601(Date.utc_today())

    genre_param =
      cond do
        anime? and genres == [] -> [with_genres: "16"]
        anime? -> [with_genres: "16," <> Enum.join(genres, "|")]
        genres == [] -> []
        true -> [with_genres: Enum.join(genres, "|")]
      end

    # Keywords: TV where it has no genre for the mood, and — for a season, which is made of
    # keywords alone — films too.
    keywords = if type == "movie", do: Map.get(mood, :movie_kw, []), else: mood.tv_kw
    kw_param = if keywords != [], do: [with_keywords: Enum.join(keywords, "|")], else: []

    # Left out: genres (not for anime, whose genre is Animation and nothing else), and keywords.
    not_genres =
      if anime?,
        do: [],
        else: Map.get(mood, if(type == "movie", do: :movie_not, else: :tv_not), [])

    not_keywords = if type == "movie", do: [], else: Map.get(mood, :tv_not_kw, [])

    without =
      if(not_genres != [], do: [without_genres: Enum.join(not_genres, "|")], else: []) ++
        if(not_keywords != [], do: [without_keywords: Enum.join(not_keywords, "|")], else: [])

    lang_param = if anime?, do: [with_original_language: "ja"], else: []
    adult = if type == "movie", do: [include_adult: false], else: []

    Browse.discover(
      type,
      [page: n, "#{date_field(type)}.lte": today] ++
        genre_param ++ kw_param ++ without ++ lang_param ++ adult ++ order
    )
  end

  defp date_field("movie"), do: "primary_release_date"
  defp date_field(_tv), do: "first_air_date"

  # Enough ratings that a great score means a great many people, not a fan club.
  defp classic_votes("movie"), do: 2500
  defp classic_votes(_tv), do: 600

  # `every` of the first list, then one of the second, until both are out.
  defp deal(main, [], _every), do: main
  defp deal([], extra, _every), do: extra

  defp deal(main, [x | extra], every),
    do: Enum.take(main, every) ++ [x | deal(Enum.drop(main, every), extra, every)]

  defp order_params(:popular, _date, _type),
    do: [sort_by: "popularity.desc", "vote_count.gte": 20]

  defp order_params(:newest, date, _type), do: [sort_by: "#{date}.desc", "vote_count.gte": 20]

  defp order_params(:top, _date, "movie"),
    do: [sort_by: "vote_average.desc", "vote_count.gte": 1000]

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
