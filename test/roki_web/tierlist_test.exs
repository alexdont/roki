defmodule RokiWeb.TierlistTest do
  @moduledoc """
  The tierlist holds everything this account has finished or read, not only manga: where each
  thing sits, how a rating puts it there on its own, and what a drag saves.
  """
  use RokiWeb.ConnCase

  alias Roki.Manga.Library
  alias Roki.Tiers

  setup %{conn: conn} do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "tiers@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "tiers"
      })

    token = PhoenixKit.Users.Auth.generate_user_session_token(user, [])
    {:ok, bin} = Ecto.UUID.dump(user.uuid)
    {:ok, conn: Plug.Test.init_test_session(conn, %{user_token: token}), user: user, bin: bin}
  end

  defp watched!(bin, id, title, opts \\ []) do
    Roki.Repo.query!(
      "insert into roki_watched (user_uuid, type, id, tmdb_type, tmdb_id, title, anime, at, dated) " <>
        "values ($1, $2, $3, $2, $3, $4, $5, now(), true)",
      [bin, Keyword.get(opts, :type, "movie"), id, title, Keyword.get(opts, :anime, false)]
    )

    if score = opts[:score] do
      Roki.Repo.query!(
        "insert into roki_ratings (user_uuid, type, id, score, rated_at) values ($1, $2, $3, $4, now())",
        [bin, Keyword.get(opts, :type, "movie"), id, score]
      )
    end
  end

  defp read!(user, slug, title) do
    {:ok, _} =
      Library.save_manga(user.uuid, %{
        source: "mangadex",
        slug: slug,
        title: title,
        cover_url: "https://example.invalid/#{slug}.jpg"
      })

    {:ok, bin} = Ecto.UUID.dump(user.uuid)

    %{rows: [[id]]} =
      Roki.Repo.query!("select id from saved_manga where user_id = $1 and slug = $2", [bin, slug])

    id
  end

  test "a score maps to a tier, and a tier back to a score" do
    assert Tiers.tier(10.0) == "s"
    assert Tiers.tier(9.0) == "a"
    assert Tiers.tier(8.4) == "b"
    assert Tiers.tier(8.5) == "b"
    assert Tiers.tier(9.5) == "a"
    assert Tiers.tier(5.5) == "e"
    assert Tiers.tier(6.5) == "d"
    assert Tiers.tier(5.0) == "e"
    assert Tiers.tier(nil) == nil

    assert Tiers.score("s") == 10
    assert Tiers.score("a") == 9
    # Not a rating, so nothing is said about a score.
    assert Tiers.score("want") == nil
    assert Tiers.score("pool") == nil
  end

  test "a rated film is already in its tier the first time the board is opened", %{
    conn: conn,
    user: user,
    bin: bin
  } do
    watched!(bin, 603, "The Matrix", score: 10)
    watched!(bin, 604, "The Matrix Reloaded", score: 8)
    watched!(bin, 605, "The Matrix Revolutions")

    html = conn |> get("/u/tiers/tierlist") |> html_response(200)

    assert html =~ "movie:603"
    assert html =~ "movie:604"
    assert html =~ "movie:605"

    # Each where its rating says, the unrated one still waiting.
    {buckets, placed} = Tiers.board(user.uuid)
    assert Enum.map(buckets["s"], & &1.id) == [603]
    assert Enum.map(buckets["b"], & &1.id) == [604]
    assert Enum.map(buckets["pool"], & &1.id) == [605]
    assert Enum.map(placed, & &1.id) |> Enum.sort() == [603, 604]
  end

  test "one board, two kinds of thing: a drag saves each where it belongs", %{
    conn: conn,
    user: user,
    bin: bin
  } do
    watched!(bin, 603, "The Matrix")
    id = read!(user, "berserk", "Berserk")

    conn =
      put(conn, "/manga/tierlist", %{
        "tiers" => %{"a" => ["movie:603", "manga:#{id}"], "pool" => []}
      })

    assert json_response(conn, 200) == %{"ok" => true}

    assert Tiers.list(user.uuid) == %{{"movie", 603} => "a"}
    assert Library.user_tier_for(user.uuid, "mangadex", "berserk") == "a"
  end

  test "what is not on the board is not kept", %{conn: conn, user: user, bin: bin} do
    watched!(bin, 603, "The Matrix")
    put(conn, "/manga/tierlist", %{"tiers" => %{"s" => ["movie:603"]}})
    assert Tiers.list(user.uuid) == %{{"movie", 603} => "s"}

    put(conn, "/manga/tierlist", %{"tiers" => %{"s" => [], "pool" => ["movie:603"]}})
    assert Tiers.list(user.uuid) == %{{"movie", 603} => "pool"}
  end

  test "anime is its own kind on the board", %{conn: conn, bin: bin} do
    watched!(bin, 1429, "Attack on Titan", type: "tv", anime: true)
    html = conn |> get("/u/tiers/tierlist") |> html_response(200)

    assert html =~ ~s(data-mode="anime")
    assert html =~ "tv:1429"
  end

  test "someone else's board is not yours", %{conn: conn} do
    assert redirected_to(get(conn, "/u/someone-else/tierlist")) == "/"
  end
end
