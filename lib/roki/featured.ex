defmodule Roki.Featured do
  @moduledoc """
  What is popular right now — the same three shelves laev's Featured screen
  has: trending movies, trending shows, and anime airing now — a TMDB page at
  a time, so a shelf can grow with a "Load more" button the way laev's does.

  One answer for the whole site per (shelf, page), kept for 12 hours: a busy
  home page is a handful of TMDB requests per half day rather than a handful
  per visitor. It needs a TMDB key, which laev reads from the application
  environment for anything that runs outside a user's scope (`config :laev,
  tmdb_key:`, set from `TMDB_API_KEY` in `config/runtime.exs`). When the site has
  none, a signed-in user's own carried key is used instead (`Roki.Laev.public/2`);
  with neither, this returns `{:error, :no_tmdb_key}` and the page says so.
  """

  @ttl_s 12 * 60 * 60
  @kinds [:movies, :shows, :anime]

  # Bumped when what a cached page *contains* changes, so old answers are ignored
  # rather than served for up to 12 hours.
  @version 6

  # Every shelf is this many titles a page, so Shows is as tall as Movies even though
  # the anime taken out of TMDB's trending list leaves a TMDB page 15-17 short.
  @page_size 20

  # The most TMDB pages one Shows page will read to find its twenty (a list that is
  # mostly anime would otherwise walk on forever).
  @max_raw_pages 8

  # Titles MyAnimeList lists but that read as shows here: Cyberpunk: Edgerunners is
  # an animation from a Western game, not what anyone means by anime. TMDB ids.
  @keep_as_shows [105_248]

  def kinds, do: @kinds

  @doc "`{:ok, items, more?}` for page `n` of a shelf, or `{:error, reason}`."
  def page(kind, n \\ 1, uuid \\ nil) when kind in @kinds and is_integer(n) and n >= 1 do
    memo({kind, n}, fn -> fetch(kind, n, uuid) end)
  end

  @doc false
  # For tests: put a page in the cache so a page can be drawn without TMDB.
  def seed(kind, n, items, more? \\ false),
    do: :persistent_term.put({__MODULE__, @version, {kind, n}}, {now(), {:ok, items, more?}})

  def configured?, do: Application.get_env(:laev, :tmdb_key) not in [nil, ""]

  # Remembered for @ttl_s under `key`, one computation at a time: a cold cache under a
  # burst of visitors would otherwise be a burst of identical TMDB requests.
  defp memo(key, fun) do
    case cached(key) do
      {:fresh, result} -> result
      {:stale, old} -> refresh(key, old, fun)
    end
  end

  defp cached(key) do
    case :persistent_term.get({__MODULE__, @version, key}, nil) do
      {at, result} -> if now() - at < @ttl_s, do: {:fresh, result}, else: {:stale, result}
      nil -> {:stale, nil}
    end
  end

  defp refresh(key, old, fun) do
    :global.trans({{__MODULE__, @version, key}, self()}, fn ->
      case cached(key) do
        {:fresh, result} ->
          result

        _ ->
          case fun.() do
            {:ok, _items, _more?} = ok ->
              :persistent_term.put({__MODULE__, @version, key}, {now(), ok})
              ok

            {:error, _} = error ->
              # Better a stale page than an empty one.
              old || error
          end
      end
    end)
  end

  # Whose key pays is `Roki.Laev.public/2`'s call: the site's when it has one, else
  # the signed-in user's own carried key. The answer is public data either way, so
  # it lands in the shared cache and the next visitor gets it free.
  defp fetch(kind, n, uuid) do
    result = Roki.Laev.public(uuid, fn -> call(kind, n) end)
    with {:ok, items, _more?} <- result, do: Roki.Titles.remember_later(items)
    result
  end

  defp call(:movies, n), do: Laev.Tmdb.trending("movie", n)
  # Anime airing now, current first: TMDB's list is by popularity, which puts the evergreens
  # (Doraemon, Detective Conan, Bleach) first every week. A few pages of it are read together and
  # put in order by `Roki.AnimeRank`, then cut into pages of twenty.
  @anime_depth 4

  defp call(:anime, n) do
    with {:ok, pool, _} <- memo(:anime_pool, &anime_pool/0) do
      {:ok, Enum.slice(pool, (n - 1) * @page_size, @page_size), length(pool) > n * @page_size}
    end
  end
  # TMDB's "trending TV" includes anime (One Piece, Bleach …), which has its own shelf.
  # Anime is what MyAnimeList has an entry for — laev's own definition, the one it
  # splits your stats by — so those come out of Shows. Live-action One Piece is a
  # different TMDB id and stays.
  defp call(:shows, n) do
    with {:ok, _count} <- Laev.AnimeMap.ensure() do
      shows_slice(n, &raw_tv/1, &Laev.AnimeMap.anime?("tv", &1))
    end
  end

  # TMDB's own trending-TV pages, cached on their own so page 2 of Shows reuses the
  # TMDB pages page 1 already read.
  defp raw_tv(p), do: memo({:tv_raw, p}, fn -> Laev.Tmdb.trending("tv", p) end)

  defp anime_pool do
    result =
      Enum.reduce_while(1..@anime_depth, {:ok, []}, fn p, {:ok, acc} ->
        case Laev.Tmdb.discover_anime(p) do
          {:ok, items, more?} -> {if(more?, do: :cont, else: :halt), {:ok, acc ++ items}}
          error -> {:halt, if(acc == [], do: error, else: {:ok, acc})}
        end
      end)

    with {:ok, items} <- result do
      year = Date.utc_today().year

      ranked =
        items
        |> Enum.uniq_by(& &1.id)
        |> Roki.AnimeRank.refine(year, &Roki.AnimeRank.latest_season_year/1)
        |> Roki.AnimeRank.rank(year)

      {:ok, ranked, false}
    end
  end

  @doc """
  Page `n` of Shows: the anime-free stream of trending TV, cut into pages of exactly
  `@page_size`. Takes the raw pages from `fetch_raw` (`{:ok, items, more?}`) as far as
  it needs to, so a TMDB page that lost its anime is topped up from the next.
  """
  def shows_slice(n, fetch_raw, anime?) do
    to = n * @page_size

    with {:ok, shows, more?} <- collect(1, [], to, fetch_raw, anime?) do
      {:ok, Enum.slice(shows, (n - 1) * @page_size, @page_size), more? or length(shows) > to}
    end
  end

  defp collect(p, acc, want, fetch_raw, anime?) do
    with {:ok, raw, more?} <- fetch_raw.(p) do
      # TMDB's trending pages are fetched at different moments while the ranking shifts,
      # so a title can sit on two of them; it is one title in the stream.
      acc = Enum.uniq_by(acc ++ without_anime(raw, anime?), & &1.id)

      if length(acc) >= want or not more? or p >= @max_raw_pages,
        do: {:ok, acc, more?},
        else: collect(p + 1, acc, want, fetch_raw, anime?)
    end
  end

  @doc false
  def without_anime(items, anime?) do
    Enum.reject(items, &(anime?.(&1.id) and &1.id not in @keep_as_shows))
  end

  defp now, do: System.system_time(:second)
end
