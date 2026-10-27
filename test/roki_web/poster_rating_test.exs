defmodule RokiWeb.PosterRatingTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  @item %{type: "movie", id: 7, title: "A", poster: nil, year: "2020", vote: 7.5}

  defp poster_html(item, opts \\ []),
    do: render_component(&RokiWeb.PosterComponents.poster/1, [item: item, compact: true] ++ opts)

  test "a title the person rated shows their rating, not TMDB's, and says whose it is" do
    html = poster_html(Map.put(@item, :my_rating, 9.0))

    assert html =~ ~s(title="Your rating")
    assert html =~ "★ 9"
    refute html =~ "7.5"
  end

  test "half marks are kept" do
    assert poster_html(Map.put(@item, :my_rating, 8.5)) =~ "★ 8.5"
  end

  test "an unrated title still shows TMDB's score" do
    html = poster_html(@item)

    assert html =~ "7.5"
    refute html =~ "Your rating"
  end

  test "a watched title is grayed and ticked, and still carries the rating" do
    html = poster_html(Map.put(@item, :my_rating, 6.0), seen: true)

    assert html =~ "opacity-50"
    assert html =~ ~s(title="Watched")
    assert html =~ "★ 6"
  end

  test "where it stopped wins over the rating: the bottom of a poster in progress is the progress" do
    html = poster_html(Map.merge(@item, %{my_rating: 9.0, resume_at: 3579, runtime: 4779}))

    assert html =~ "59:39"
    refute html =~ "Your rating"
  end
end
