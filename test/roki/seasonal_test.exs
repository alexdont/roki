defmodule Roki.SeasonalTest do
  use ExUnit.Case, async: true

  alias Roki.{Mood, Seasonal}

  test "the right season for the time of year" do
    assert Seasonal.current(~D[2026-10-31]).slug == "halloween"
    assert Seasonal.current(~D[2026-09-20]).slug == "halloween"
    assert Seasonal.current(~D[2026-11-20]).slug == "thanksgiving"
    assert Seasonal.current(~D[2026-12-24]).slug == "christmas"
    assert Seasonal.current(~D[2026-12-28]).slug == "new-years"
    assert Seasonal.current(~D[2027-01-03]).slug == "new-years"
    assert Seasonal.current(~D[2027-02-10]).slug == "valentines"
    assert Seasonal.current(~D[2027-04-10]).slug == "spring"
    assert Seasonal.current(~D[2027-07-04]).slug == "summer"
  end

  test "every day of the year has a season, and each is a season the page can show" do
    for day <- Date.range(~D[2027-01-01], ~D[2027-12-31]) do
      assert %{season: true} = Seasonal.current(day)
    end
  end

  test "a season is shaped like a mood, and the mood page finds it" do
    season = Seasonal.get("halloween")

    assert %{
             slug: "halloween",
             label: "Halloween",
             movie_kw: [_ | _],
             tv_kw: [_ | _],
             season: true
           } = season

    assert Mood.get("halloween") == season
    assert Mood.get("scared").slug == "scared"
    assert Mood.get("nonsense") == nil
  end

  test "a season is not one of the moods in the picker" do
    refute Enum.any?(Mood.all(), & &1[:season])
  end

  test "every season's typeface is one the page loads" do
    families =
      Mood.fonts() |> Enum.map(&(&1 |> String.split(":") |> hd() |> String.replace("+", " ")))

    for s <- Seasonal.all() do
      [name] = Regex.run(~r/'([^']+)'/, s.font, capture: :all_but_first)
      assert name in families, "#{s.slug} is set in #{name}, which the page does not load"
    end
  end
end
