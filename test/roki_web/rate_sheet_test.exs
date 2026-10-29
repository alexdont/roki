defmodule RokiWeb.RateSheetTest do
  @moduledoc """
  The rating dialog as the page first draws it. The slider takes over from there, but what it
  starts on has to be right before any script has run, and the table the script reads its colours
  from comes from here.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  @title %{title: "Masterplan", vote: 6.9, vote_count: 1204, type: "movie", id: 1}

  defp sheet(value, provider \\ :tmdb) do
    %{
      title: @title,
      rating: %{state: :ok, value: value, provider: provider},
      error: nil,
      label: nil,
      __changed__: nil
    }
    |> RokiWeb.TitleLive.rate_sheet()
    |> rendered_to_string()
  end

  # The one element with this id, as markup.
  defp element(html, id) do
    [tag] = Regex.run(~r/<[a-z]+[^>]*id="#{id}"[^>]*>/s, html)
    tag
  end

  describe "a score on the ramp" do
    test "is drawn in its colour, and not in gold" do
      html = sheet(7.0)

      assert element(html, "rate-out") =~ "color: hsl(130 75% 46%)"
      assert element(html, "rate-word") =~ "color: hsl(130 75% 46%)"
      refute element(html, "rate-out") =~ "rate-gold"
      refute html =~ "data-gold"
    end

    test "9.5 is a deep green, not gold" do
      html = sheet(9.5)

      assert element(html, "rate-out") =~ "color: hsl(152 80% 42%)"
      refute element(html, "rate-out") =~ "rate-gold"
      refute html =~ "data-gold"
    end

    test "an unrated title starts on seven, which is green" do
      html = sheet(nil)

      assert element(html, "rate-out") =~ "color: hsl(130 75% 46%)"
      refute html =~ "data-gold"
    end
  end

  describe "ten" do
    test "is gold from the first paint: the class on the number and the word, the attribute on the slider" do
      html = sheet(10.0)

      assert element(html, "rate-out") =~ "rate-gold"
      assert element(html, "rate-word") =~ "rate-gold"
      assert html =~ ~r/<input[^>]*data-gold/s
    end

    test "has no colour of its own on the number or the word, which would paint over the gold" do
      html = sheet(10.0)

      refute element(html, "rate-out") =~ "color:"
      refute element(html, "rate-word") =~ "color:"
    end

    test "fills the whole bar: the thumb is at the very end" do
      [input] = Regex.run(~r/<input[^>]*class="rate-range[^>]*>/s, sheet(10.0))

      assert input =~ "--c: var(--gold)"
      assert input =~ "--p: 1.0"
    end

    test "turns the 'your rating' line gold too" do
      assert sheet(10.0) =~ ~r/Your rating:\s*<span class="font-semibold rate-gold"/
      assert sheet(9.5) =~ ~r/Your rating:\s*<span class="font-semibold text-info"/
    end
  end

  describe "what the script is given" do
    test "the colours of every score, as JSON, with ten as gold" do
      [json] = Regex.run(~r/data-colors="([^"]*)"/, sheet(7.0), capture: :all_but_first)

      colors =
        json |> unescape() |> Jason.decode!()

      assert colors["10"] == "gold"
      assert colors["7"] == "hsl(130 75% 46%)"
      assert map_size(colors) == 20
    end

    test "the words of every score" do
      [json] = Regex.run(~r/data-words="([^"]*)"/, sheet(7.0), capture: :all_but_first)
      words = json |> unescape() |> Jason.decode!()

      assert words["10"] == "masterpiece"
    end
  end

  describe "the bar" do
    defp bar(html), do: hd(Regex.run(~r/<input[^>]*class="rate-range[^>]*>/s, html))

    test "is the colour of the score, filled as far as the thumb, on a TMDB slider" do
      bar = bar(sheet(7.0))

      assert bar =~ "--c: hsl(130 75% 46%)"
      # Seven is 6.5 of 9.5 along a slider that starts at 0.5.
      assert bar =~ "--p: 0.6842"
      assert bar =~ ~s(min="0.5")
    end

    test "is laid out for whole numbers on a MyAnimeList slider" do
      bar = bar(sheet(7.0, :mal))

      assert bar =~ ~s(min="1")
      # Seven is 6 of 9 along a slider that starts at 1.
      assert bar =~ "--p: 0.6667"
    end

    test "follows the score it opens on" do
      assert bar(sheet(2.0)) =~ "--c: hsl(22 75% 46%)"
      assert bar(sheet(2.0)) =~ "--p: 0.1579"
      assert bar(sheet(9.5)) =~ "--c: hsl(152 80% 42%)"
      assert bar(sheet(nil)) =~ "--c: hsl(130 75% 46%)"
    end

    test "no longer carries a fixed gradient, since the bar is the colour of the score" do
      html = sheet(7.0)

      refute html =~ "--track"
      refute html =~ "--thumb"
      refute html =~ "linear-gradient"
    end
  end

  defp unescape(text) do
    text
    |> String.replace("&quot;", "\"")
    |> String.replace("&amp;", "&")
    |> String.replace("&#39;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
  end
end
