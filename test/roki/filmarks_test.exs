defmodule Roki.FilmarksTest do
  use ExUnit.Case, async: true

  defp cassette(name, href, date, score) do
    """
    <div class="js-cassette"><div class="p-content-cassette">
      <h3 class="p-content-cassette__title">#{name}</h3>
      <div class="p-content-cassette__other-info up-screen_and_country">
        <h4 class="p-content-cassette__other-info-title">公開日：</h4><span>#{date}</span>
      </div>
      <div class="p-content-cassette__rate"><div class="c-rating"><div class="c-rating__score">#{score}</div></div></div>
      <a href="#{href}">>></a>
    </div></div>
    """
  end

  test "a search page is read into its results" do
    html =
      cassette("デューン 砂の惑星PART2", "/movies/99843", "2024年03月15日", "4.14") <>
        cassette("デューン 砂の惑星PART3", "/movies/126696", "2026年12月18日", "-")

    assert [a, b] = Roki.Filmarks.parse("<html><body>" <> html <> "</body></html>")
    assert %{name: "デューン 砂の惑星PART2", href: "/movies/99843", year: 2024, score: 4.14} = a
    assert %{year: 2026, score: nil} = b
  end

  test "the result that is the title is taken: same name, the year, a score" do
    results = [
      %{name: "デューン 砂の惑星PART3", href: "/movies/126696", year: 2026, score: nil},
      %{name: "デューン 砂の惑星PART2", href: "/movies/99843", year: 2024, score: 4.14},
      %{name: "DUNE/デューン 砂の惑星", href: "/movies/82861", year: 2021, score: 3.9}
    ]

    assert %{score: 4.14, text: "4.14/5", url: "https://filmarks.com/movies/99843"} =
             Roki.Filmarks.pick(results, "デューン 砂の惑星PART2", 2024)
  end

  test "nothing is better than the wrong one: another year or another name gives no score" do
    results = [%{name: "デューン 砂の惑星", href: "/movies/1", year: 2021, score: 3.9}]
    assert Roki.Filmarks.pick(results, "デューン 砂の惑星", 2024) == nil
    assert Roki.Filmarks.pick(results, "マトリックス", 2021) == nil
  end

  test "a show is taken by its first season's year, the plainest name first" do
    results = [
      %{name: "葬送のフリーレン 第2期", href: "/animes/3844/6185", year: 2026, score: 4.3},
      %{name: "葬送のフリーレン ～●●の魔法～", href: "/animes/4302/5796", year: 2023, score: 4.0},
      %{name: "葬送のフリーレン", href: "/animes/3844/5200", year: 2023, score: 4.34}
    ]

    assert %{url: "https://filmarks.com/animes/3844/5200"} =
             Roki.Filmarks.pick(results, "葬送のフリーレン", 2023)
  end
end
