defmodule Roki.OpenGraphTest do
  use ExUnit.Case, async: true

  alias Roki.OpenGraph

  @title %{
    title: "Heat",
    year: "1995",
    vote: 7.947,
    genres: ["Crime", "Drama", "Action", "Thriller"],
    tagline: "A Los Angeles crime saga."
  }

  test "the facts line: year, up to three genres, the score" do
    assert OpenGraph.facts(@title) == "1995  ·  Crime, Drama, Action  ·  TMDB 7.9"
    assert OpenGraph.facts(%{title: "X"}) == ""
  end

  test "the watched line counts what there is" do
    assert OpenGraph.watched_line(0, 0, 0) == "Nothing watched yet"
    assert OpenGraph.watched_line(1, 2, 0) == "1 film  ·  2 shows watched"
    assert OpenGraph.watched_line(0, 0, 3) == "3 anime watched"
  end

  test "the head's tags for a title and a profile" do
    og = OpenGraph.for_title("movie", 949, @title)
    assert og.title == "Heat"
    assert og.description == "A Los Angeles crime saga."
    assert String.ends_with?(og.image, "/og/title/movie/949/card.jpg")

    og = OpenGraph.for_profile("alex", %{bio: ""})
    assert og.title == "alex on Roki"
    assert og.description == nil
    assert String.ends_with?(og.image, "/og/u/alex/card.jpg")
  end

  @tag :magick
  test "a title's scene renders to a JPEG without any picture" do
    scene = OpenGraph.title_scene(@title)
    values = %{"title" => "Heat", "facts" => OpenGraph.facts(@title)}

    case OpenGraph.render(scene, values) do
      {:ok, <<0xFF, 0xD8, _::binary>> = jpeg} -> assert byte_size(jpeg) > 1000
      {:error, :rasterizer} -> :skip
    end
  end
end
