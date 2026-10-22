defmodule Roki.Featured do
  @moduledoc """
  What is popular right now — the same three shelves laev's Featured screen
  has: trending movies, trending shows, and anime airing now — a TMDB page at
  a time, so a shelf can grow with a "More" button the way laev's does.

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
  @version 2

  # Titles MyAnimeList lists but that read as shows here: Cyberpunk: Edgerunners is
  # an animation from a Western game, not what anyone means by anime. TMDB ids.
  @keep_as_shows [105_248]

  def kinds, do: @kinds

  @doc "`{:ok, items, more?}` for page `n` of a shelf, or `{:error, reason}`."
  def page(kind, n \\ 1, uuid \\ nil) when kind in @kinds and is_integer(n) and n >= 1 do
    case cached(kind, n) do
      {:fresh, result} -> result
      {:stale, old} -> refresh(kind, n, old, uuid)
    end
  end

  def configured?, do: Application.get_env(:laev, :tmdb_key) not in [nil, ""]

  defp key(kind, n), do: {__MODULE__, @version, kind, n}

  defp cached(kind, n) do
    case :persistent_term.get(key(kind, n), nil) do
      {at, result} -> if now() - at < @ttl_s, do: {:fresh, result}, else: {:stale, result}
      nil -> {:stale, nil}
    end
  end

  # One refresh per page at a time: a cold cache under a burst of visitors would
  # otherwise be a burst of identical TMDB requests.
  defp refresh(kind, n, old, uuid) do
    :global.trans({{__MODULE__, @version, kind, n}, self()}, fn ->
      case cached(kind, n) do
        {:fresh, result} ->
          result

        _ ->
          case fetch(kind, n, uuid) do
            {:ok, _items, _more?} = ok ->
              :persistent_term.put(key(kind, n), {now(), ok})
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
  defp fetch(kind, n, uuid), do: Roki.Laev.public(uuid, fn -> call(kind, n) end)

  defp call(:movies, n), do: Laev.Tmdb.trending("movie", n)
  # TMDB's "trending TV" includes anime (One Piece, Bleach …), which has its own shelf.
  # Anime is what MyAnimeList has an entry for — laev's own definition, the one it
  # splits your stats by — so those come out of Shows. Live-action One Piece is a
  # different TMDB id and stays.
  defp call(:shows, n) do
    with {:ok, items, more?} <- Laev.Tmdb.trending("tv", n),
         {:ok, _count} <- Laev.AnimeMap.ensure() do
      {:ok, without_anime(items, &Laev.AnimeMap.anime?("tv", &1)), more?}
    else
      {:error, _} = error -> error
    end
  end

  defp call(:anime, n), do: Laev.Tmdb.discover_anime(n)

  @doc false
  def without_anime(items, anime?) do
    Enum.reject(items, &(anime?.(&1.id) and &1.id not in @keep_as_shows))
  end

  defp now, do: System.system_time(:second)
end
