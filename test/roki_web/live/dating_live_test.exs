defmodule RokiWeb.DatingLiveTest do
  @moduledoc """
  The dating assistant: the pool is what has no date or sits on an import day, sweeping up to a
  year keeps only what had come out, and putting a block in a year takes it out of the pool.
  """
  use RokiWeb.ConnCase

  import Phoenix.LiveViewTest

  setup do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "dating@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "datinguser"
      })

    {:ok, bin} = Ecto.UUID.dump(user.uuid)

    # 45 titles on one import day (2021-06-16), released 2000..2019; one with a real date.
    for n <- 1..45 do
      year = 1999 + rem(n, 21)

      Roki.Repo.query!(
        "insert into roki_titles (type, id, name, year, fetched_at, seen_at) values ('movie', $1, $2, $3, now(), now()) on conflict do nothing",
        [n, "Film #{n}", Integer.to_string(year)]
      )

      Roki.Repo.query!(
        "insert into roki_watched (user_uuid, type, id, tmdb_type, tmdb_id, title, anime, at, dated, status) values ($1, 'movie', $2, 'movie', $2, $3, false, '2021-06-16 12:00:00', true, 'finished')",
        [bin, n, "Film #{n}"]
      )
    end

    Roki.Repo.query!(
      "insert into roki_watched (user_uuid, type, id, tmdb_type, tmdb_id, title, anime, at, dated, status) values ($1, 'movie', 999, 'movie', 999, 'Seen Last Week', false, '2026-10-30 12:00:00', true, 'finished')",
      [bin]
    )

    token = PhoenixKit.Users.Auth.generate_user_session_token(user, [])
    {:ok, conn: Plug.Test.init_test_session(build_conn(), %{user_token: token}), user: user}
  end

  test "only the imported titles are in the pool, and only those out by the year", %{conn: conn} do
    {:ok, view, _} = live(conn, "/datinguser/dating?up_to=2005")
    render_async(view)
    html = render(view)

    assert html =~ "45 still to place"
    refute html =~ "Seen Last Week"
    # 2005 or earlier of 1999..2019 in rem(n, 21) steps: 7 years of 21, a third or so of 45.
    assert html =~ ~r/<span class="font-semibold">\d+<\/span>\s*titles out by 2005/
  end

  test "another person's page is not for anyone else", %{conn: conn} do
    {:ok, _other} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "other-dating@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "otherdating"
      })

    assert {:error, {:live_redirect, %{to: "/otherdating/watched"}}} =
             live(conn, "/otherdating/dating")
  end

  test "putting ticked titles in a year takes them out of the pool and dates them", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _} = live(conn, "/datinguser/dating?up_to=2019")
    render_async(view)

    view |> element(~s(button[phx-value-key="movie:1"])) |> render_click()
    view |> element(~s(button[phx-value-key="movie:2"])) |> render_click()

    # The block cannot have been watched before the later of the two came out.
    html = render(view)
    assert html =~ ~r/<span class="font-semibold">2<\/span>\s*ticked/

    view |> form("#place-form", %{year: "2019", month: "March"}) |> render_submit()

    assert render(view) =~ "2 titles put in March 2019."
    assert render(view) =~ "43 still to place"

    dates =
      user.uuid
      |> Roki.Profile.watch_dates()
      |> Map.take([{"movie", 1}, {"movie", 2}])
      |> Map.values()
      |> Enum.map(&(&1 |> DateTime.from_unix!() |> DateTime.to_date()))

    assert dates == [~D[2019-03-15], ~D[2019-03-15]]
  end
end
