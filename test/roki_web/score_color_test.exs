defmodule RokiWeb.ScoreColorTest do
  @moduledoc """
  The rating scale's colours and where the thumb sits. The scale used to run red, yellow, green, and then back to yellow
  for the top scores, so 8 looked worse than 7 and 10 looked like a yellow 4.
  """
  use ExUnit.Case, async: true

  alias RokiWeb.ScoreColor

  defp hue("hsl(" <> rest), do: rest |> String.split(" ") |> hd() |> String.to_integer()

  # Every score a slider can land on below the top, in order.
  @ramp for halves <- 1..19, do: halves / 2

  describe "the ramp" do
    test "only ever turns one way: the hue never falls as the score rises" do
      hues = for v <- @ramp, do: hue(ScoreColor.color(v))

      assert hues == Enum.sort(hues), "the hue came back round: #{inspect(Enum.zip(@ramp, hues))}"
    end

    test "starts red, passes yellow, and is green by seven" do
      assert hue(ScoreColor.color(1)) == 0
      assert hue(ScoreColor.color(3)) in 35..55
      assert hue(ScoreColor.color(7)) == 130
    end

    test "never goes back toward yellow once it is green" do
      # 7, 7.5 … 9.5
      for v <- Enum.map(14..19, &(&1 / 2)) do
        assert hue(ScoreColor.color(v)) >= 130, "#{v} is not green: #{ScoreColor.color(v)}"
      end
    end

    test "deepens toward emerald past seven rather than staying flat" do
      assert hue(ScoreColor.color(9.5)) > hue(ScoreColor.color(7))
      assert hue(ScoreColor.color(9.5)) <= 160
    end

    test "scores outside the scale are held to it" do
      assert ScoreColor.color(0) == ScoreColor.color(1)
      assert ScoreColor.color(0.5) == ScoreColor.color(1)
    end

    test "a score between 9.5 and ten stays on the ramp's last colour" do
      assert ScoreColor.color(9.8) == ScoreColor.color(9.5)
      refute ScoreColor.gold?(9.8)
    end
  end

  describe "ten" do
    test "is gold, and nothing else is" do
      assert ScoreColor.gold?(10)
      assert ScoreColor.gold?(10.0)
      refute ScoreColor.gold?(9.5)
      refute ScoreColor.gold?(9)
      refute ScoreColor.gold?(7)
      refute ScoreColor.gold?(nil)
      refute ScoreColor.gold?("10")
    end

    test "is the stylesheet's gold, not a colour computed on the ramp" do
      assert ScoreColor.color(10) == "var(--gold)"
      refute ScoreColor.color(10) =~ "hsl"
    end
  end

  describe "where the thumb is" do
    test "is how far along the bar the score is, from nothing to the whole of it" do
      assert ScoreColor.fraction(0.5) == 0.0
      assert ScoreColor.fraction(10) == 1.0
      assert ScoreColor.fraction(5.25) == 0.5
    end

    test "for a TMDB rating the bar starts at 0.5, for MyAnimeList's whole numbers at 1" do
      # Seven is 6.5 of 9.5 along one slider and 6 of 9 along the other.
      assert ScoreColor.fraction(7, 0.5) == 0.6842
      assert ScoreColor.fraction(7, 1) == 0.6667
      assert ScoreColor.fraction(1, 1) == 0.0
      assert ScoreColor.fraction(10, 1) == 1.0
    end

    test "never leaves the bar" do
      assert ScoreColor.fraction(0, 0.5) == 0.0
      assert ScoreColor.fraction(-3) == 0.0
      assert ScoreColor.fraction(12) == 1.0
    end

    test "only rises with the score" do
      fractions = for halves <- 1..20, do: ScoreColor.fraction(halves / 2)

      assert fractions == Enum.sort(fractions)
      assert Enum.uniq(fractions) == fractions
    end
  end

  describe "the table the script reads" do
    test "has every score the slider can land on, keyed the way the script writes them" do
      table = ScoreColor.table()

      assert Map.keys(table) |> Enum.sort() ==
               ~w(0.5 1 1.5 10 2 2.5 3 3.5 4 4.5 5 5.5 6 6.5 7 7.5 8 8.5 9 9.5) |> Enum.sort()
    end

    test "says gold for ten and a colour for everything else" do
      table = ScoreColor.table()

      assert table["10"] == "gold"

      assert table
             |> Map.delete("10")
             |> Map.values()
             |> Enum.all?(&String.starts_with?(&1, "hsl("))
    end

    test "agrees with the colour of each score, so the slider and the first paint cannot differ" do
      for {key, color} <- Map.delete(ScoreColor.table(), "10") do
        {v, ""} = Float.parse(key)
        assert color == ScoreColor.color(v)
      end
    end
  end
end
