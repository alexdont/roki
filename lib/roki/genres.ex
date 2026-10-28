defmodule Roki.Genres do
  @moduledoc """
  Genres, the way a person thinks of them across films and shows.

  TMDB keeps two genre lists that do not line up: films have Horror, Thriller and Romance, shows
  have Action & Adventure, Sci-Fi & Fantasy and War & Politics. A filter that reads "Action"
  has to mean 28 for a film and 10759 for a show, so each genre here names the ids it has per
  kind (`@genres`), and a genre a kind has no id for is simply not offered there (no "Horror"
  on Shows).

  What a title's genres are is read from TMDB once and kept (`roki_titles.genres`), for the
  pages that cannot ask TMDB to filter: the watched history and search.
  """

  alias Roki.Repo

  # slug, label, film ids, show ids
  @genres [
    {"action", "Action", [28], [10759]},
    {"adventure", "Adventure", [12], [10759]},
    {"animation", "Animation", [16], [16]},
    {"comedy", "Comedy", [35], [35]},
    {"crime", "Crime", [80], [80]},
    {"documentary", "Documentary", [99], [99]},
    {"drama", "Drama", [18], [18]},
    {"family", "Family", [10751], [10751]},
    {"fantasy", "Fantasy", [14], [10765]},
    {"history", "History", [36], []},
    {"horror", "Horror", [27], []},
    {"kids", "Kids", [], [10762]},
    {"music", "Music", [10402], []},
    {"mystery", "Mystery", [9648], [9648]},
    {"reality", "Reality", [], [10764]},
    {"romance", "Romance", [10749], []},
    {"scifi", "Sci-Fi", [878], [10765]},
    {"thriller", "Thriller", [53], []},
    {"war", "War", [10752], [10768]},
    {"western", "Western", [37], [37]}
  ]

  @doc "Every genre as `{slug, label}`."
  def all, do: for({slug, label, _, _} <- @genres, do: {slug, label})

  @doc "The genres a kind (`:movies`, `:shows`, `:anime`, or `\"movie\"` / `\"tv\"`) has, as `{slug, label}`."
  def options(kind) do
    type = type_of(kind)

    for {slug, label, movie, tv} <- @genres,
        if(type == "movie", do: movie, else: tv) != [],
        do: {slug, label}
  end

  # TMDB has no Horror genre for shows, but it keeps a "horror" keyword they are tagged with
  # (534 of them, American Horror Story and Supernatural among them). Discover can filter by it,
  # so browsing offers Horror on Shows and Anime; the pages that filter titles already read
  # (watched history, search) go by genre ids and do not.
  @keywords %{"horror" => 315_058}

  @doc """
  The genres browsing offers for a kind (`options/1`, and Horror for shows and anime through its
  keyword), as `{slug, label}`.
  """
  def browse_options(kind) do
    type = type_of(kind)

    for {slug, label, movie, tv} <- @genres,
        if(type == "movie", do: movie, else: tv) != [] or
          (type == "tv" and Map.has_key?(@keywords, slug)),
        do: {slug, label}
  end

  @doc "The TMDB keyword that stands in for a genre on shows (`with_keywords`), or nil."
  def keyword(slug, kind),
    do: if(type_of(kind) == "tv" and ids(slug, kind) == [], do: @keywords[slug])

  @doc "A genre named in an address, else nil (never made into an atom from input)."
  def parse(value), do: Enum.find_value(@genres, fn {slug, _, _, _} -> slug == value && slug end)

  @doc "The label of a genre."
  def label(slug), do: Enum.find_value(@genres, fn {s, label, _, _} -> s == slug && label end)

  @doc "The TMDB ids a genre has for a kind (empty when the kind has none)."
  def ids(slug, kind) do
    type = type_of(kind)

    Enum.find_value(@genres, [], fn
      {^slug, _, movie, tv} -> if type == "movie", do: movie, else: tv
      _ -> false
    end)
  end

  @doc "`with_genres` for TMDB's discover: this genre's ids for the kind, any of them (`|`)."
  def with_genres(slug, kind), do: slug |> ids(kind) |> Enum.join("|")

  @doc "Does a title of `type` with these genre ids belong to this genre? `nil` ids (unknown) never do."
  def match?(slug, type, ids) when is_list(ids), do: Enum.any?(ids, &(&1 in ids(slug, type)))
  def match?(_slug, _type, _ids), do: false

  defp type_of(kind) when kind in [:movies, "movie", :movie], do: "movie"
  defp type_of(_kind), do: "tv"

  # ── reading and keeping a title's genres ───────────────────────────

  @doc "`%{{type, id} => [genre ids]}` for the titles whose genres are already kept."
  def known(keys) when is_list(keys) do
    keys =
      keys |> Enum.filter(fn {t, i} -> t in ["movie", "tv"] and is_integer(i) end) |> Enum.uniq()

    if keys == [] do
      %{}
    else
      {types, ids} = Enum.unzip(keys)

      Repo.query!(
        "select type, id, genres from roki_titles where genres is not null and (type, id) in (select unnest($1::text[]), unnest($2::int[]))",
        [types, ids]
      ).rows
      |> Map.new(fn [t, i, g] -> {{t, i}, g} end)
    end
  end

  @doc "How many of these titles still have no genres kept."
  def missing_count(keys), do: length(Enum.uniq(keys)) - map_size(known(keys))

  @doc """
  Keep the genres of the titles that have none yet, asked of TMDB a few at a time with the key
  that pays for public lookups for this account (`Roki.Laev.public/2`: the site's, else the
  account's own — a title's genres are the same for everyone). At most `limit` are read in one
  call. Returns how many were kept. A title TMDB cannot answer for is left to try again later.
  """
  def fill(keys, uuid, limit \\ 400) when is_list(keys) do
    have = known(keys)

    todo =
      keys
      |> Enum.uniq()
      |> Enum.filter(fn {t, i} = k ->
        t in ["movie", "tv"] and is_integer(i) and not Map.has_key?(have, k)
      end)
      |> Enum.take(limit)

    case key_for(uuid) do
      nil ->
        0

      key ->
        todo
        |> Task.async_stream(&fetch_one(&1, key),
          max_concurrency: 6,
          timeout: 20_000,
          on_timeout: :kill_task,
          ordered: false
        )
        |> Enum.count(fn
          {:ok, {:ok, _}} -> true
          _ -> false
        end)
    end
  end

  @doc "`fill/2` behind the caller, once at a time (a second call while one runs does nothing)."
  def fill_later(keys, uuid) do
    if :global.set_lock({__MODULE__, self()}, [node()], 0) do
      Task.start(fn ->
        try do
          drain(keys, uuid)
        after
          :global.del_lock({__MODULE__, self()}, [node()])
        end
      end)
    end

    :ok
  end

  # A big library is read in rounds, so it neither hammers TMDB nor holds one task forever.
  defp drain(keys, uuid) do
    case fill(keys, uuid, 200) do
      0 -> :ok
      _ -> Process.sleep(500) && drain(keys, uuid)
    end
  end

  defp fetch_one({type, id} = key, api_key) do
    with {:ok, %{"genres" => genres}} when is_list(genres) <- get("/#{type}/#{id}", api_key) do
      ids = for g <- genres, is_integer(g["id"]), do: g["id"]
      keep(key, ids)
      {:ok, ids}
    else
      {:error, :not_found} ->
        # A title TMDB no longer has: kept as having none, so it is not asked for again.
        keep(key, [])
        {:ok, []}

      _ ->
        :error
    end
  end

  # Update the row if there is one (a title the lists already left), else make a bare one.
  defp keep({type, id}, ids) do
    Repo.query!(
      """
      insert into roki_titles (type, id, genres, seen_at) values ($1, $2, $3, now())
      on conflict (type, id) do update set genres = excluded.genres
      """,
      [type, id, ids]
    )
  end

  defp get(path, key) do
    {auth, params} =
      if String.starts_with?(key, "eyJ"),
        do: {[auth: {:bearer, key}], []},
        else: {[], [api_key: key]}

    case Req.get(
           Req.new(
             base_url: "https://api.themoviedb.org/3",
             retry: false,
             receive_timeout: 15_000
           ),
           [url: path, params: params] ++ auth
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: s}} -> {:error, {:tmdb, s}}
      {:error, e} -> {:error, e}
    end
  end

  defp key_for(uuid) do
    case Roki.Laev.public(uuid, fn -> Laev.Scope.get(:tmdb_key) end) do
      key when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end
end
