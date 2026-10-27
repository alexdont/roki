defmodule Roki.SearchGenreTest do
  use Roki.DataCase, async: false

  alias Roki.{Search, TTLCache}

  # Pages a search already holds are served from the cache, so these never ask TMDB.
  defp seed(q, page, items, more?) do
    TTLCache.fetch({:search, Search.canonical(q), page}, 60, fn -> {:ok, {items, more?, []}} end)
  end

  defp item(id, title), do: %{type: "movie", id: id, title: title, year: "2020", poster: nil, popularity: 1.0}

  test "a genre keeps only its own titles, and reads on past pages that have few of it" do
    q = "genre filter probe #{System.unique_integer([:positive])}"

    seed(q, 1, [item(9_001, "Scary A"), item(9_002, "Funny B")], true)
    seed(q, 2, [item(9_003, "Scary C"), item(9_004, "Drama D")], false)

    for {id, genres} <- [{9_001, [27]}, {9_002, [35]}, {9_003, [27, 53]}, {9_004, [18]}] do
      Roki.Repo.query!("insert into roki_titles (type, id, name, genres, seen_at) values ('movie', $1, 'x', $2, now())", [id, genres])
    end

    assert {:ok, items, more?, franchises, _seen, read_to} = Search.search_genre({:user, "t"}, nil, q, 1, "horror")
    assert Enum.map(items, & &1.title) == ["Scary A", "Scary C"]
    # Page 1 had one, so it went on to page 2, which was the last; no franchise lists.
    assert read_to == 2
    refute more?
    assert franchises == []

    # Coming back to a list that had two pages: exactly those pages, filtered.
    assert {:ok, again, _, _, _, 2} = Search.search_genre({:user, "t"}, nil, q, 1, "horror", 2)
    assert Enum.map(again, & &1.title) == ["Scary A", "Scary C"]

    # Another genre, the same cached pages.
    assert {:ok, funny, _, _, _, _} = Search.search_genre({:user, "t"}, nil, q, 1, "comedy")
    assert Enum.map(funny, & &1.title) == ["Funny B"]
  end
end
