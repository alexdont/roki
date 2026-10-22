defmodule Roki.Featured do
  @moduledoc """
  What is popular right now — the same three shelves laev's Featured screen
  has: trending movies, trending shows, and anime airing now — a TMDB page at
  a time, so a shelf can grow with a "More" button the way laev's does.

  One answer for the whole site per (shelf, page), kept for 30 minutes: a busy
  home page is a handful of TMDB requests per half hour rather than a handful
  per visitor. It needs a TMDB key, which laev reads from the application
  environment for anything that runs outside a user's scope (`config :laev,
  tmdb_key:`, set from `TMDB_API_KEY` in `config/runtime.exs`); without one
  this returns `{:error, :no_tmdb_key}` and the page says so.
  """

  @ttl_s 30 * 60
  @kinds [:movies, :shows, :anime]

  def kinds, do: @kinds

  @doc "`{:ok, items, more?}` for page `n` of a shelf, or `{:error, reason}`."
  def page(kind, n \\ 1) when kind in @kinds and is_integer(n) and n >= 1 do
    case cached(kind, n) do
      {:fresh, result} -> result
      {:stale, old} -> refresh(kind, n, old)
    end
  end

  def configured?, do: Application.get_env(:laev, :tmdb_key) not in [nil, ""]

  defp key(kind, n), do: {__MODULE__, kind, n}

  defp cached(kind, n) do
    case :persistent_term.get(key(kind, n), nil) do
      {at, result} -> if now() - at < @ttl_s, do: {:fresh, result}, else: {:stale, result}
      nil -> {:stale, nil}
    end
  end

  # One refresh per page at a time: a cold cache under a burst of visitors would
  # otherwise be a burst of identical TMDB requests.
  defp refresh(kind, n, old) do
    :global.trans({{__MODULE__, kind, n}, self()}, fn ->
      case cached(kind, n) do
        {:fresh, result} ->
          result

        _ ->
          case fetch(kind, n) do
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

  defp fetch(kind, n) do
    if configured?() do
      run(fn -> call(kind, n) end)
    else
      {:error, :no_tmdb_key}
    end
  end

  defp call(:movies, n), do: Laev.Tmdb.trending("movie", n)
  defp call(:shows, n), do: Laev.Tmdb.trending("tv", n)
  defp call(:anime, n), do: Laev.Tmdb.discover_anime(n)

  # Laev wants a scope (a directory for its caches) even when nobody owns it.
  defp run(fun) do
    Path.join(Roki.Laev.base_dir(), "_featured") |> Laev.Scope.load() |> Laev.Scope.run(fun)
  end

  defp now, do: System.system_time(:second)
end
