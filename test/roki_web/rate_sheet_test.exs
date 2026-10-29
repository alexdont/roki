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

    test "has no ramp colour on its thumb either: the stylesheet's gold draws it" do
      html = sheet(10.0)

      [input] = Regex.run(~r/<input[^>]*class="rate-range[^>]*>/s, html)
      assert input =~ "--thumb: var(--gold)"
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

  describe "the track" do
    test "ends in the gold notch on a TMDB slider" do
      html = sheet(7.0)

      assert html =~ "var(--gold) 97.4%, var(--gold) 100%"
      assert html =~ ~s(min="0.5")
    end

    test "is laid out for whole numbers on a MyAnimeList slider" do
      html = sheet(7.0, :mal)

      assert html =~ ~s(min="1")
      assert html =~ "var(--gold) 97.2%, var(--gold) 100%"
      # One is the very start of that slider, not 5% along it.
      assert html =~ "hsl(0 75% 46%) 0.0%"
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
