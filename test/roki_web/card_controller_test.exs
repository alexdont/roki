defmodule RokiWeb.CardControllerTest do
  @moduledoc """
  `/card/:type/:id`: what a home-page card shows once it has opened. The title comes from the site's
  kept copy and the trailer from the day's cache, so nothing here asks TMDB or YouTube.
  """
  use RokiWeb.ConnCase

  setup do
    {title, _} =
      Code.eval_file(Path.expand("support/fixtures/frieren_title.exs", __DIR__ |> Path.dirname()))

    Roki.Titles.put(title)
    on_exit(fn -> Roki.TTLCache.delete({:trailer, "tv", 209_867}) end)
    :ok
  end

  test "a title's facts, its wide picture and its trailer, for anyone", %{conn: conn} do
    Roki.TTLCache.put({:trailer, "tv", 209_867}, 600, {:ok, "abc123xyz"})

    json = conn |> get("/card/tv/209867") |> json_response(200)

    assert json["title"] =~ "Frieren"
    assert json["minutes"] == 25
    assert json["trailer"] == "abc123xyz"
    assert json["seasons"] == 1
    # A few lines of the story, cut at a word.
    assert is_binary(json["overview"])
    assert String.length(json["overview"]) <= 192
    assert String.ends_with?(json["overview"], "…")
    refute json["overview"] =~ ~r/\s…$/
    assert length(json["genres"]) <= 3
    assert is_binary(json["backdrop"])
  end

  test "a title with no trailer says so, rather than failing", %{conn: conn} do
    Roki.TTLCache.put({:trailer, "tv", 209_867}, 600, {:ok, nil})

    assert %{"trailer" => nil, "title" => _} =
             conn |> get("/card/tv/209867") |> json_response(200)
  end

  test "nonsense is a 404", %{conn: conn} do
    assert conn |> get("/card/book/1") |> response(404)
    assert conn |> get("/card/movie/abc") |> response(404)
  end
end
