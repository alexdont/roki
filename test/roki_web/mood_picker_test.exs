defmodule RokiWeb.MoodPickerTest do
  @moduledoc """
  The home page's mood carousel: every mood a slide in one grid cell (so the box is as tall as the
  tallest, whatever the length of a tagline), the mood's top titles fanned as posters, the moods as
  named tabs. The real widths are measured by `test/e2e/mood_layout.js`.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  @item %{
    id: 1,
    type: "movie",
    title: "A Film",
    poster: "https://image.tmdb.org/t/p/w500/a.jpg",
    backdrop: "https://image.tmdb.org/t/p/w1280/b.jpg"
  }

  setup do
    {:ok, html: render_component(&RokiWeb.FeaturedLive.mood_picker/1, moods: %{})}
  end

  test "every mood is a slide in the same grid cell", %{html: html} do
    assert length(Regex.scan(~r/data-mood="[a-z]+"/, html)) == length(Roki.Mood.all())

    assert length(Regex.scan(~r/relative col-start-1 row-start-1 flex transition-opacity/, html)) ==
             length(Roki.Mood.all())

    assert html =~ "grid-cols-[minmax(0,1fr)]"
  end

  test "the moods are named tabs that open their page", %{html: html} do
    assert length(Regex.scan(~r/data-mood-chip=/, html)) == length(Roki.Mood.all())
    assert length(Regex.scan(~r/data-mood-bar/, html)) == length(Roki.Mood.all())

    for m <- Roki.Mood.all() do
      assert html =~ ~s(href="/mood/#{m.slug}")
      assert html =~ m.label
    end
  end

  test "a mood shows its top three titles as posters, linked to their pages" do
    items = for n <- 1..5, do: %{@item | id: n, title: "Film #{n}"}
    html = render_component(&RokiWeb.FeaturedLive.mood_picker/1, moods: %{"scared" => items})

    scared =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-mood="scared"] a[title]))

    assert Enum.count(scared) == 3
    assert LazyHTML.attribute(scared, "href") == ~w(/title/movie/1 /title/movie/2 /title/movie/3)
    assert html =~ "aspect-[2/3]"
  end

  test "the title is in the site's own face, the mood's colour only in the line above it", %{
    html: html
  } do
    scared = Roki.Mood.get("scared")
    refute html =~ "mood-title"
    refute html =~ "mood-grain"
    refute html =~ Phoenix.HTML.safe_to_string(Phoenix.HTML.html_escape(scared.font))
    assert html =~ "color: hsl(#{scared.hue} 90% 62%)"
  end
end
