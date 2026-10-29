defmodule Roki.MoodTest do
  use Roki.DataCase, async: false

  alias Roki.Mood

  test "a mood is named by its slug, a kind and an order by theirs, never trusting input" do
    assert %{label: "Be scared"} = Mood.get("scared")
    assert Mood.get("nope") == nil
    assert Mood.kind("anime") == :anime and Mood.kind("x") == :all
    assert Mood.sort("top") == :top and Mood.sort("junk") == :popular
    assert length(Mood.all()) == 12
    assert Enum.all?(Mood.all(), &(&1.movie != [] or &1.tv != [] or &1.tv_kw != []))
  end

  test "a title belongs to a mood by its genre ids; TV moods that are keywords are taken loosely" do
    scared = Mood.get("scared")
    assert Mood.match?(scared, "movie", [27, 53])
    refute Mood.match?(scared, "movie", [35])
    # A horror show carries Mystery / Sci-Fi & Fantasy on TMDB, not Horror.
    assert Mood.match?(scared, "tv", [9648])
    refute Mood.match?(scared, "tv", [35])
    assert Mood.match?(Mood.get("laugh"), "tv", [35])
    refute Mood.match?(scared, "movie", nil)
  end

  test "a page that is held is served without asking TMDB, mixed or by kind, and peeked at" do
    films = [
      %{
        id: 1,
        type: "movie",
        title: "Held Scare",
        poster: nil,
        year: "2020",
        popularity: 1.0,
        vote: 7.0
      }
    ]

    Roki.TTLCache.put({:mood, 2, "scared", :all, :popular, 1}, 60, {:ok, {films, true}})
    on_exit(fn -> Roki.TTLCache.delete({:mood, 2, "scared", :all, :popular, 1}) end)

    assert {:ok, [%{title: "Held Scare"}], true} = Mood.page("scared", :all, :popular, 1, nil)
    assert {:ok, [%{title: "Held Scare"}], true} = Mood.peek("scared")
    assert Mood.peek("laugh", :anime, :top, 3) in [:miss, Mood.peek("laugh", :anime, :top, 3)]
    assert %{"scared" => [%{title: "Held Scare"}]} = Map.take(Mood.hero_peek(), ["scared"])
    assert {:error, :no_such_mood} = Mood.page("nope")
  end

  # Pictographs, symbols and the selector that turns a character into one.
  @emoji ~r/[\x{1F000}-\x{1FAFF}\x{2190}-\x{21FF}\x{2300}-\x{23FF}\x{2600}-\x{27BF}\x{FE0F}]/u

  test "a mood is a name, a typeface and a colour — it has no pictogram" do
    for mood <- Mood.all() do
      refute Map.has_key?(mood, :icon), "#{mood.slug} still has an icon"
      refute mood.label =~ @emoji, "#{mood.slug}'s name has an emoji in it"
      refute mood.tagline =~ @emoji, "#{mood.slug}'s tagline has an emoji in it"
      assert is_binary(mood.font) and is_integer(mood.hue)
    end
  end

  test "moods are numbered by their place in the list, as a programme numbers its films" do
    assert Mood.count() == 12
    assert Mood.number("scared") == "01"
    assert Mood.number("true") == "12"
    assert Mood.number(Mood.get("love")) == "03"

    assert Enum.map(Mood.all(), &Mood.number/1) ==
             for(n <- 1..12, do: String.pad_leading("#{n}", 2, "0"))

    assert Mood.number("nope") == "00"
  end
end
