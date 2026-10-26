defmodule Roki.AnimeCornerTest do
  use ExUnit.Case, async: true

  alias Roki.AnimeCorner

  @html """
  <h2 class="wp-block-heading">Top 73 Anime of the Week 3 – Fall 2026</h2>
  <figure class="wp-block-table"><table class="has-fixed-layout"><thead><tr><th>Rank</th><th>Title</th><th>Votes</th></tr></thead>
  <tbody><tr><td class="has-text-align-center">1st</td><td class="has-text-align-center">Bleach: Thousand-Year Blood War &#8211; The Calamity</td><td>20.15%</td></tr>
  <tr><td>2nd</td><td>Firefly Wedding</td><td>9.23%</td></tr>
  <tr><td>4th</td><td>STEEL BALL RUN JoJo&#8217;s Bizarre Adventure 2nd-3rd STAGE</td><td>8.19%</td></tr>
  <tr><td>8th</td><td>Ranma &frac12; (2024) Season 3</td><td>2.15%</td></tr>
  <tr><td>73rd</td><td>Little Mouse&#8217;s Red Vest Season 2</td><td>0.03%</td></tr>
  </tbody></table></figure>
  <h2>Best Ship or Couple</h2>
  <table><tbody><tr><td>1st</td><td>Hikaru Indo x Yoshiki Tsujinaka</td><td>21.07%</td></tr></tbody></table>
  """

  test "the ranking table is read with its places, titles and shares" do
    assert [
             %{rank: 1, title: "Bleach: Thousand-Year Blood War – The Calamity", votes: 20.15},
             %{rank: 2, title: "Firefly Wedding", votes: 9.23},
             %{rank: 4, title: "STEEL BALL RUN JoJo’s Bizarre Adventure 2nd-3rd STAGE", votes: 8.19},
             %{rank: 8, title: "Ranma ½ (2024) Season 3", votes: 2.15},
             %{rank: 73, title: "Little Mouse’s Red Vest Season 2", votes: 0.03}
           ] = AnimeCorner.parse(@html)

    assert AnimeCorner.parse("<p>no table</p>") == []
    # A season's final post goes on with other polls; only the first table is the ranking.
    assert AnimeCorner.parse("<table><tr><td>Male</td><td>72%</td></tr></table>" <> @html) |> length() == 5
  end

  test "what names a season is cut off, and a long title is tried ever shorter" do
    assert AnimeCorner.clean("The Apothecary Diaries Season 3") == "The Apothecary Diaries"
    assert AnimeCorner.clean("STEEL BALL RUN JoJo’s Bizarre Adventure 2nd-3rd STAGE") == "STEEL BALL RUN JoJo's Bizarre Adventure"
    assert AnimeCorner.clean("Ranma ½ (2024) Season 3") == "Ranma ½"
    assert AnimeCorner.clean("Attack on Titan The Final Season Part 2") == "Attack on Titan"
    assert AnimeCorner.clean("My Hero Academia 7th Season") == "My Hero Academia"
    assert AnimeCorner.clean("Firefly Wedding") == "Firefly Wedding"

    assert AnimeCorner.variants("Bleach: Thousand-Year Blood War – The Calamity") ==
             ["Bleach: Thousand-Year Blood War – The Calamity", "Bleach: Thousand-Year Blood War", "Bleach"]

    assert AnimeCorner.key("Ranma ½ (2024) Season 3") == "ranma12"
    assert AnimeCorner.key("Ranma1/2") == "ranma12"
    assert AnimeCorner.key("JoJo's Bizarre Adventure") == "jojosbizarreadventure"
  end

  test "posts are named by season and week" do
    assert AnimeCorner.slug({2026, :fall}, 3) == "fall-2026-anime-rankings-week-3"
    assert AnimeCorner.slug({2026, :summer}, :final) == "summer-2026-anime-of-the-season-rankings"
    assert AnimeCorner.url({2026, :fall}, 1) == "https://animecorner.me/fall-2026-anime-rankings-week-1/"
    assert AnimeCorner.week("3") == 3
    assert AnimeCorner.week("final") == :final
    assert AnimeCorner.week("99") == nil
    assert AnimeCorner.week(nil) == nil
    assert AnimeCorner.week_label(:final) == "Season final"
  end
end
