defmodule Roki.ListsMatchingTest do
  @moduledoc """
  A search finds a list by its own name, not only through the titles it turned up.
  """
  use ExUnit.Case, async: true

  alias Roki.Lists

  defp names(query), do: query |> Lists.matching() |> Enum.map(& &1.name)

  test "the list's own name finds it, however it is cased or accented" do
    assert names("marvel") == ["Marvel"]
    assert names("MARVEL") == ["Marvel"]
    assert names("pokemon") == ["Pokémon"]
    assert names("x-men") == ["X-Men"]
  end

  test "a longer search that goes on from a list's name still finds it" do
    assert names("star wars the last jedi") == ["Star Wars"]
    assert names("naruto shippuden") == ["Naruto"]
  end

  test "the start of a name, or of one of its words, finds it from four letters" do
    assert "Marvel" in names("marv")
    assert "Dragon Ball" in names("dragon")
    assert "Dragon Ball" in names("ball")
  end

  test "short or empty searches name nothing, and so does a word no list starts with" do
    assert Lists.matching("") == []
    assert Lists.matching("ab") == []
    assert Lists.matching("zzzzzz") == []
    # "the" begins a good many list names; it is not a search for any of them.
    assert Lists.matching("the") == []
    assert Lists.matching(nil) == []
  end

  test "an exact name comes before a partial one, and at most five come back" do
    assert length(Lists.matching("man")) <= 5
    [first | _] = Lists.matching("marvel")
    assert first.name == "Marvel"
  end
end
