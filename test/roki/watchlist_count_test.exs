defmodule Roki.WatchlistCountTest do
  use ExUnit.Case, async: true

  alias Roki.Laev

  defp row(attrs),
    do:
      Map.merge(
        %{
          type: "tv",
          id: 105_248,
          mal_id: nil,
          title: "Edgerunners",
          note: " · 2/20 episodes watched"
        },
        attrs
      )

  test "episodes marked through MyAnimeList are counted with the ones marked on TMDB" do
    # Season 1 (10) marked on its MyAnimeList entry, 2 of season 2 on TMDB: laev says 2
    assert %{note: " · 12/20 episodes watched"} = Laev.true_count(row(%{}), fn _ -> 12 end)
  end

  test "the count never passes the total, and never goes down" do
    assert %{note: " · 20/20 episodes watched"} = Laev.true_count(row(%{}), fn _ -> 25 end)
    assert %{note: " · 2/20 episodes watched"} = Laev.true_count(row(%{}), fn _ -> 1 end)
    assert %{note: " · 2/20 episodes watched"} = Laev.true_count(row(%{}), fn _ -> 2 end)
  end

  test "the rest of the note is kept as it was" do
    assert %{note: "Up next S2E3 · 12/20 episodes watched · 1 new"} =
             Laev.true_count(row(%{note: "Up next S2E3 · 2/20 episodes watched · 1 new"}), fn _ ->
               12
             end)
  end

  test "a row for one MyAnimeList entry keeps its own count — unless it counts more than the entry has" do
    ok = row(%{mal_id: 42_310, note: "2/10 episodes watched"})
    assert Laev.true_count(ok, fn _ -> 12 end) == ok

    # a 4-episode special counted with all of the show it is filed under
    over = row(%{mal_id: 33_191, note: " · 26/4 episodes"})
    assert %{note: " · 4/4 episodes"} = Laev.true_count(over, fn _ -> 4 end)
    assert %{note: " · 3/4 episodes"} = Laev.true_count(over, fn _ -> 3 end)
  end

  test "a film, or a note with no count, is left alone" do
    film = row(%{type: "movie"})
    assert Laev.true_count(film, fn _ -> 12 end) == film

    plain = row(%{note: "1/3 seasons watched"})
    assert Laev.true_count(plain, fn _ -> 12 end) == plain
    assert Laev.true_count(row(%{note: nil}), fn _ -> 12 end) == row(%{note: nil})
  end

  test "a count that cannot be had leaves the note alone" do
    assert %{note: " · 2/20 episodes watched"} = Laev.true_count(row(%{}), fn _ -> nil end)
  end
end
