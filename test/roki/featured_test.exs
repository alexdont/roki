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
