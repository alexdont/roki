defmodule Roki.Search do
  @moduledoc """
  Title search, the way laev's `watch` does it: TMDB's multi search for movies
  and shows, a year hint ("heat 1995") that floats matching years to the top, and
  an IMDb id ("tt0113277") that resolves to exactly one title.

  Runs in the caller's scope — a signed-in user searches with their own TMDB key
  and gets their watched marks back with the results; a visitor uses the
  server-wide key and gets no marks.
  """

  @year ~r/^(.*\S)\s+((?:19|20)\d\d)$/
  @imdb ~r/^tt\d{6,}$/

  @doc "`{:ok, items, more?, seen}` — `seen` is a set of `{type, id}` — or `{:error, reason}`."
  def search(uuid, query, page \\ 1) when is_binary(query) and is_integer(page) do
    query = String.trim(query)

    Roki.Laev.run_as(uuid, fn ->
      case lookup(query, page) do
        {:ok, items, more?} -> {:ok, items, more?, Roki.Laev.seen_keys(items)}
        error -> error
      end
    end)
  end

  defp lookup("", _page), do: {:ok, [], false}

  defp lookup(query, page) do
    if Regex.match?(@imdb, query) do
      imdb(query)
    else
      {text, year} = split_year(query)

      with {:ok, results, more?} <- Laev.Tmdb.search(text, page) do
        {:ok, rank(results, year), more?}
      end
    end
  end

  defp imdb(id) do
    case Laev.Tmdb.find_imdb(id) do
      {:ok, title} -> {:ok, [title], false}
      {:error, :not_found} -> {:ok, [], false}
      error -> error
    end
  end

  @doc false
  def split_year(query) do
    case Regex.run(@year, query) do
      [_, text, year] -> {text, year}
      _ -> {query, nil}
    end
  end

  # TMDB's own order is relevance; a year hint only floats matching years up.
  defp rank(results, nil), do: results
  defp rank(results, year), do: Enum.sort_by(results, &(&1.year != year))
end
