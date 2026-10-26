defmodule RokiWeb.MalControllerTest do
  use RokiWeb.ConnCase, async: true

  test "the MyAnimeList callback needs a signed-in user", %{conn: conn} do
    conn = get(conn, "/mal/callback?code=abc&state=xyz")
    assert redirected_to(conn) == "/phoenix_kit/users/log-in"
  end

  test "the callback address is this site's own" do
    assert Roki.Laev.mal_redirect() =~ ~r{^https?://[^/]+/mal/callback$}
  end
end
