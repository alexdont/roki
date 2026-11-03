defmodule RokiWeb.ContinueControllerTest do
  @moduledoc """
  `/continue/:type/:id`, the home page's Continue: straight to playing what is next, with no title
  page in between.
  """
  use RokiWeb.ConnCase

  @film %{
    type: "movie",
    id: 10_331,
    title: "Easy A",
    year: "2010",
    date: "2010-09-10",
    poster_path: "/easyA.jpg",
    overview: "A rumour.",
    status: "Released",
    seasons: [],
    search: %{search: ["Easy A"], accept: ["Easy A"]}
  }

  setup %{conn: conn} do
    Roki.Titles.put(@film)

    {title, _} =
      Code.eval_file(Path.expand("support/fixtures/frieren_title.exs", __DIR__ |> Path.dirname()))

    Roki.Titles.put(title)

    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "continue@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "continueuser"
      })

    token = PhoenixKit.Users.Auth.generate_user_session_token(user, [])
    {:ok, signed_in: Plug.Test.init_test_session(conn, %{user_token: token}), conn: conn}
  end

  test "a film goes to the sources page asking for the best source to start by itself", %{
    signed_in: conn
  } do
    assert redirected_to(get(conn, "/continue/movie/10331")) == "/sources/movie/10331?auto=1"
  end

  test "a series goes to an episode of it, to play", %{signed_in: conn} do
    path = redirected_to(get(conn, "/continue/tv/209867"))
    assert path =~ ~r{^/sources/tv/209867/\d+/\d+\?auto=1$}
  end

  test "someone not signed in, or a bad address, goes to the title's own page or home", %{
    conn: conn
  } do
    assert redirected_to(get(conn, "/continue/movie/10331")) == "/title/movie/10331"
    assert redirected_to(get(conn, "/continue/movie/abc")) == "/"
    assert redirected_to(get(conn, "/continue/manga/5")) == "/"
  end
end
