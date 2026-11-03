defmodule Roki.Manga.ShelfTest do
  @moduledoc "The saved-manga page's rules: chips, caught up, sorts (ported from the old page's script)."
  use ExUnit.Case, async: true

  alias Roki.Manga.Shelf

  defp m(attrs) do
    Map.merge(
      %{
        last_chapter: nil,
        completed: false,
        last_chapter_number: nil,
        total_chapters: nil,
        updated_at: nil,
        inserted_at: nil,
        newest_chapter_at: nil
      },
      Map.new(attrs)
    )
  end

  defp item(key, kind, attrs, status \\ "ongoing"),
    do: %{key: key, kind: kind, status: status, m: m(attrs)}

  test "a chip cycles on, excluded, off; a category comes back on from excluded; All clears" do
    assert Shelf.next_chip(nil, {:mode, "reading"}) == {:mode, "reading"}
    assert Shelf.next_chip({:mode, "reading"}, {:mode, "reading"}) == {:exclude_mode, "reading"}
    assert Shelf.next_chip({:exclude_mode, "reading"}, {:mode, "reading"}) == nil

    assert Shelf.next_chip({:exclude_mode, "reading"}, {:mode, "completed"}) ==
             {:mode, "completed"}

    assert Shelf.next_chip({:category, 3}, {:category, 3}) == {:exclude, 3}
    assert Shelf.next_chip({:exclude, 3}, {:category, 3}) == {:category, 3}
    assert Shelf.next_chip({:mode, "reading"}, {:category, 3}) == {:category, 3}
    assert Shelf.next_chip({:exclude, 3}, :all) == nil
  end

  test "caught up: the floor of the chapter read reaches the newest known one" do
    assert Shelf.caught_up?(m(last_chapter: "42.5", last_chapter_number: 42))
    assert Shelf.caught_up?(m(last_chapter: "10", total_chapters: 10))
    refute Shelf.caught_up?(m(last_chapter: "9", total_chapters: 10))
    refute Shelf.caught_up?(m(last_chapter: "10", total_chapters: 10, completed: true))
    refute Shelf.caught_up?(m(last_chapter: "10"))
    refute Shelf.caught_up?(m(last_chapter: nil, total_chapters: 0))
  end

  test "each chip keeps its own titles" do
    items = [
      item("a", "scroll", last_chapter: "3", total_chapters: 50),
      item("b", "scroll", last_chapter: "50", total_chapters: 50),
      item("c", "paged", []),
      item("d", "scroll", []),
      item("e", "paged", last_chapter: "9", completed: true)
    ]

    keys = fn chip ->
      items
      |> Shelf.visible(chip, "all", "any", "updated_at")
      |> Enum.map(& &1.key)
      |> Enum.sort()
    end

    assert keys.({:mode, "reading"}) == ["a"]
    assert keys.({:mode, "caughtup"}) == ["b"]
    assert keys.({:mode, "mangatoread"}) == ["c"]
    assert keys.({:mode, "manhwatoread"}) == ["d"]
    assert keys.({:mode, "completed"}) == ["e"]
    assert keys.({:exclude_mode, "reading"}) == ["b", "c", "d", "e"]
    assert keys.(nil) == ["a", "b", "c", "d", "e"]

    members = MapSet.new(["a", "c"])

    assert items
           |> Shelf.visible({:category, 1}, "all", "any", "updated_at", members)
           |> Enum.map(& &1.key)
           |> Enum.sort() == ["a", "c"]

    assert items
           |> Shelf.visible({:exclude, 1}, "all", "any", "updated_at", members)
           |> Enum.map(& &1.key)
           |> Enum.sort() == ["b", "d", "e"]
  end

  test "read/unread and series status narrow further" do
    items = [
      item("a", "scroll", [last_chapter: "1"], "ongoing"),
      item("b", "scroll", [], "completed")
    ]

    assert Shelf.visible(items, nil, "read", "any", "updated_at") |> Enum.map(& &1.key) == ["a"]
    assert Shelf.visible(items, nil, "unread", "any", "updated_at") |> Enum.map(& &1.key) == ["b"]

    assert Shelf.visible(items, nil, "all", "completed", "updated_at") |> Enum.map(& &1.key) == [
             "b"
           ]
  end

  test "sorts: newest first with no date last, chapter counts, fastest to catch up" do
    t = fn s -> NaiveDateTime.add(~N[2026-11-01 00:00:00], s) end

    items = [
      item("old", "paged", updated_at: t.(1), total_chapters: 10, last_chapter: "9"),
      item("none", "paged", total_chapters: 300),
      item("new", "paged", updated_at: t.(5), total_chapters: 100, last_chapter: "20"),
      item("unknown", "paged", updated_at: t.(3))
    ]

    order = fn sort -> items |> Shelf.sort(sort) |> Enum.map(& &1.key) end

    assert order.("updated_at") == ["new", "unknown", "old", "none"]
    assert order.("chapters_desc") == ["none", "new", "old", "unknown"]
    assert order.("chapters_asc") == ["unknown", "old", "new", "none"]
    # 1 left, 80 left, 300 left (never started), unknown last.
    assert order.("catch_up") == ["old", "new", "none", "unknown"]
  end
end
