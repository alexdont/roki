defmodule RokiWeb.ScoreColorTest do
  @moduledoc """
  The rating scale's colours. The scale used to run red, yellow, green, and then back to yellow
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

  describe "the track" do
    # "hsl(…) 94.7%" -> {"hsl(…)", 94.7}
    defp stops(track) do
      [_, inner] = Regex.run(~r/^linear-gradient\(90deg, (.*)\)$/, track)

      inner
      |> String.split(~r/,\s(?![^()]*\))/)
      |> Enum.map(fn stop ->
        [color, pos] = Regex.run(~r/^(.*) ([\d.]+)%$/, stop, capture: :all_but_first)
        {color, pos |> Float.parse() |> elem(0)}
      end)
    end

    test "is a gradient left to right whose stops only move forward" do
      positions = stops(ScoreColor.track()) |> Enum.map(&elem(&1, 1))

      assert positions == Enum.sort(positions)
      assert List.last(positions) == 100.0
      assert Enum.all?(positions, &(&1 >= 0 and &1 <= 100))
    end

    test "ends in a gold notch with a hard edge, so nothing blends toward it" do
      stops = stops(ScoreColor.track())
      [{green_end, edge}, {gold_start, edge2}, {gold_end, 100.0}] = Enum.take(stops, -3)

      assert gold_start == "var(--gold)" and gold_end == "var(--gold)"
      # The edge is one position, with green on its left and gold on its right.
      assert edge == edge2
      assert hue(green_end) > 140
    end

    test "has no yellow, and no turning back, between green and the gold" do
      ramp = stops(ScoreColor.track()) |> Enum.reject(fn {c, _} -> c == "var(--gold)" end)
      hues = Enum.map(ramp, fn {c, _} -> hue(c) end)

      assert hues == Enum.sort(hues)
      assert hue(elem(List.last(ramp), 0)) > 140
    end

    test "puts a score where the thumb will be: from 0.5 for a TMDB rating, from 1 for MyAnimeList" do
      tmdb = stops(ScoreColor.track(0.5))
      mal = stops(ScoreColor.track(1))

      # Seven is 6.5 of 9.5 along one slider and 6 of 9 along the other.
      assert {_, 68.4} = Enum.find(tmdb, fn {c, _} -> c == ScoreColor.color(7) end)
      assert {_, 66.7} = Enum.find(mal, fn {c, _} -> c == ScoreColor.color(7) end)
    end

    test "is the same notch on both, a little under three per cent of the way" do
      for min <- [0.5, 1] do
        [{_, edge} | _] = stops(ScoreColor.track(min)) |> Enum.take(-2)
        assert edge > 96 and edge < 98
      end
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
