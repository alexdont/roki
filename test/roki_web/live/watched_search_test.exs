defmodule RokiWeb.WatchedSearchTest do
  @moduledoc """
  The watched page's search box names whose list it searches.
  """
  use RokiWeb.ConnCase

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    register = fn name ->
      {:ok, user} =
        PhoenixKit.Users.Auth.register_user(%{
          "email" => "#{name}@example.com",
          "password" => "a-long-enough-password-123",
          "username" => name
        })

      user
    end

    me = register.("watchedme")
    other = register.("watchedmax")
    token = PhoenixKit.Users.Auth.generate_user_session_token(me, [])
    {:ok, conn: Plug.Test.init_test_session(conn, %{user_token: token}), me: me, other: other}
  end

  test "on your own page it says you, on someone else's it names them", %{conn: conn} do
    # The placeholder is short so it fits beside Select on a phone; the label says whose list.
    {:ok, _view, mine} = live(conn, "/watchedme/watched")
    assert mine =~ ~s(aria-label="Search what you watched")
    assert mine =~ "Search watched…"

    {:ok, _view, theirs} = live(conn, "/watchedmax/watched")
    assert theirs =~ ~s(aria-label="Search what watchedmax watched")
    refute theirs =~ "Search what you watched"
  end

  test "the owner can show only the titles with no date", %{conn: conn, me: me} do
    {:ok, bin} = Ecto.UUID.dump(me.uuid)

    for {id, name, dated} <- [{1, "Dated Film", true}, {2, "Undated Film", false}] do
      Roki.Repo.query!(
        "insert into roki_watched (user_uuid, type, id, tmdb_type, tmdb_id, title, anime, at, dated, status) values ($1, 'movie', $2, 'movie', $2, $3, false, now(), $4, 'finished')",
        [bin, id, name, dated]
      )
    end

    {:ok, view, _} = live(conn, "/watchedme/watched")
    html = render_async(view)
    assert html =~ "Dated Film" and html =~ "Undated Film"
    assert html =~ "No date"

    {:ok, view, _} = live(conn, "/watchedme/watched?dated=no")
    html = render_async(view)
    assert html =~ "Undated Film"
    refute html =~ "Dated Film"
    assert html =~ "dated=no" or html =~ ~s(aria-checked="true")
  end
end
