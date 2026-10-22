defmodule Roki.FeaturedTest do
  use ExUnit.Case, async: true

  alias Roki.Featured

  @items [
    %{id: 1, title: "A real show"},
    %{id: 37_854, title: "One Piece (anime)"},
    %{id: 111_110, title: "One Piece (live action)"},
    %{id: 105_248, title: "Cyberpunk: Edgerunners"},
    %{id: 4, title: "Bleach"}
  ]

  test "anime comes out of Shows; the live-action show with the same name stays" do
    anime? = fn id -> id in [37_854, 105_248, 4] end

    assert @items |> Featured.without_anime(anime?) |> Enum.map(& &1.title) ==
             ["A real show", "One Piece (live action)", "Cyberpunk: Edgerunners"]
  end

  test "Edgerunners is kept as a show on purpose, though MyAnimeList lists it" do
    assert [%{id: 105_248}] = Featured.without_anime([%{id: 105_248}], fn _ -> true end)
  end

  test "nothing is removed when nothing is anime" do
    assert Featured.without_anime(@items, fn _ -> false end) == @items
  end
end

defmodule Roki.FeaturedShowsPagingTest do
  use ExUnit.Case, async: true

  alias Roki.Featured

  # 20 titles a TMDB page, ids 1..; every 4th is anime, so each page loses 5.
  defp raw(total_pages) do
    fn p when p <= total_pages ->
      items = for i <- ((p - 1) * 20 + 1)..(p * 20), do: %{id: i, title: "t#{i}"}
      {:ok, items, p < total_pages}
    end
  end

  defp anime?(id), do: rem(id, 4) == 0

  test "every Shows page is a full twenty, topped up from the next TMDB page" do
    {:ok, p1, more?} = Featured.shows_slice(1, raw(10), &anime?/1)
    assert length(p1) == 20
    assert more?
    refute Enum.any?(p1, &anime?(&1.id))
  end

  test "pages follow on with no gaps and no repeats" do
    pages = for n <- 1..4, do: elem(Featured.shows_slice(n, raw(10), &anime?/1), 1)
    ids = pages |> List.flatten() |> Enum.map(& &1.id)
    assert Enum.all?(pages, &(length(&1) == 20))
    assert ids == Enum.uniq(ids)

    expected = Enum.reject(1..200, &anime?/1) |> Enum.take(80)
    assert ids == expected
  end

  test "the last page is short, says there is no more, and stops asking TMDB" do
    {:ok, last, more?} = Featured.shows_slice(2, raw(2), &anime?/1)
    # 40 raw titles, 10 anime: 30 shows, so page 2 holds the remaining 10
    assert length(last) == 10
    refute more?
  end

  test "a list that is nearly all anime does not walk on forever" do
    pages_read = :counters.new(1, [])

    fetch = fn p ->
      :counters.add(pages_read, 1, 1)
      {:ok, for(i <- ((p - 1) * 20 + 1)..(p * 20), do: %{id: i}), true}
    end

    assert {:ok, [], true} = Featured.shows_slice(1, fetch, fn _ -> true end)
    assert :counters.get(pages_read, 1) == 8
  end

  test "a TMDB error is passed up, not swallowed into an empty shelf" do
    assert {:error, :boom} = Featured.shows_slice(1, fn _ -> {:error, :boom} end, &anime?/1)
  end

  test "a title that sits on two overlapping TMDB pages appears once" do
    fetch = fn
      1 -> {:ok, for(i <- 1..20, do: %{id: i}), true}
      # page 2 starts with five that were already on page 1 (the ranking shifted)
      2 -> {:ok, for(i <- 16..35, do: %{id: i}), false}
    end

    {:ok, shows, _} = Featured.shows_slice(1, fetch, fn _ -> false end)
    ids = Enum.map(shows, & &1.id)
    assert ids == Enum.to_list(1..20)

    {:ok, rest, more?} = Featured.shows_slice(2, fetch, fn _ -> false end)
    assert Enum.map(rest, & &1.id) == Enum.to_list(21..35)
    refute more?
  end
end
