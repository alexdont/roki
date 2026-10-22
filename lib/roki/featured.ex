defmodule Roki.Featured do
  @moduledoc """
  What is popular right now — the same three shelves laev's Featured screen
  has: trending movies, trending shows, and anime airing now.

  One answer for the whole site, kept for 30 minutes, so a busy home page is
  three TMDB requests per half hour rather than three per visitor. It needs a
  TMDB key, which laev reads from the application environment for anything that
  runs outside a user's scope (`config :laev, tmdb_key:`, set from
  `TMDB_API_KEY` in `config/runtime.exs`); without one this returns
  `{:error, :no_tmdb_key}` and the page says so.
  """

  @ttl_s 30 * 60
  @key {__MODULE__, :cache}

  @doc "`{:ok, %{movies: [...], shows: [...], anime: [...]}}` or `{:error, reason}`."
  def get do
    case cached() do
      {:fresh, data} -> {:ok, data}
      {:stale, old} -> refresh(old)
    end
  end

  def configured?, do: Application.get_env(:laev, :tmdb_key) not in [nil, ""]

  defp cached do
    case :persistent_term.get(@key, nil) do
      {at, data} ->
        if now() - at < @ttl_s, do: {:fresh, data}, else: {:stale, data}

      nil ->
        {:stale, nil}
    end
  end

  # One refresh at a time: a cold cache under a burst of visitors would
  # otherwise be a burst of identical TMDB requests.
  defp refresh(old) do
    :global.trans({{__MODULE__, :refresh}, self()}, fn ->
      case cached() do
        {:fresh, data} ->
          {:ok, data}

        _ ->
          case fetch() do
            {:ok, data} ->
              :persistent_term.put(@key, {now(), data})
              {:ok, data}

            {:error, _} = error ->
              # Better a stale shelf than an empty page.
              if old, do: {:ok, old}, else: error
          end
      end
    end)
  end

  defp fetch do
    if configured?() do
      run(fn ->
        with {:ok, movies, _} <- Laev.Tmdb.trending("movie"),
             {:ok, shows, _} <- Laev.Tmdb.trending("tv"),
             {:ok, anime, _} <- Laev.Tmdb.discover_anime() do
          {:ok, %{movies: movies, shows: shows, anime: anime}}
        end
      end)
    else
      {:error, :no_tmdb_key}
    end
  end

  # Laev wants a scope (a directory for its caches) even when nobody owns it.
  defp run(fun) do
    Path.join(Roki.Laev.base_dir(), "_featured") |> Laev.Scope.load() |> Laev.Scope.run(fun)
  end

  defp now, do: System.system_time(:second)
end
