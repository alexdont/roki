defmodule RokiWeb.GridTest do
  @moduledoc """
  The grid: fifteen named places per board, filled by hand and by nothing else, holding manga
  on the reader's boards and films, shows and anime on this site's — either kind on Overall.
  """
  use RokiWeb.ConnCase

  alias Roki.Grid
  alias Roki.Manga.Library

  setup %{conn: conn} do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "grid@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "gridder"
      })

    token = PhoenixKit.Users.Auth.generate_user_session_token(user, [])
    {:ok, bin} = Ecto.UUID.dump(user.uuid)
    {:ok, conn: Plug.Test.init_test_session(conn, %{user_token: token}), user: user, bin: bin}
  end

  defp watched!(bin, id, title, type \\ "movie", anime \\ false) do
    Roki.Repo.query!(
      "insert into roki_watched (user_uuid, type, id, tmdb_type, tmdb_id, title, anime, at, dated) " <>
        "values ($1, $2, $3, $2, $3, $4, $5, now(), true)",
      [bin, type, id, title, anime]
    )
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

  test "a board starts with fifteen empty places and fills none of them", %{user: user} do
    board = Grid.board(user.uuid, "movie")

    assert length(board) == 15
    assert Enum.map(board, & &1.slot) == Enum.to_list(1..15)
    assert Enum.all?(board, &(&1.type == nil))
    assert hd(board).label == "Favorite"
  end

  test "every board is offered, each its own", %{conn: conn, bin: bin} do
    watched!(bin, 603, "The Matrix")
    html = conn |> get("/gridder/grid?mode=movie") |> html_response(200)

    for label <- ~w(Overall Movies Shows Anime Manga Manhwa), do: assert(html =~ label)
    assert html =~ "movie:603"
  end

  test "a film goes in a place, and taking it off leaves the place empty", %{
    conn: conn,
    user: user,
    bin: bin
  } do
    watched!(bin, 603, "The Matrix")

    put(conn, "/manga/grid", %{"slot" => "1", "id" => "movie:603", "mode" => "movie"})
    assert %{type: "movie", id: 603} = Grid.board(user.uuid, "movie") |> hd()

    put(conn, "/manga/grid", %{"slot" => "1", "id" => "", "mode" => "movie"})
    assert %{type: nil, id: nil} = Grid.board(user.uuid, "movie") |> hd()
  end

  test "on Overall a place holds one thing, whichever kind it is", %{
    conn: conn,
    user: user,
    bin: bin
  } do
    watched!(bin, 603, "The Matrix")
    id = read!(user, "berserk", "Berserk")

    put(conn, "/manga/grid", %{"slot" => "2", "id" => "manga:#{id}", "mode" => "overall"})
    assert Enum.at(Library.list_grid_slots(user.uuid, "overall"), 1).slug == "berserk"
    assert Enum.at(Grid.board(user.uuid, "overall"), 1).type == nil

    # The film takes the place; the manga is not left sitting under it.
    put(conn, "/manga/grid", %{"slot" => "2", "id" => "movie:603", "mode" => "overall"})
    assert Enum.at(Library.list_grid_slots(user.uuid, "overall"), 1).slug == nil
    assert Enum.at(Grid.board(user.uuid, "overall"), 1).id == 603
  end

  test "someone else's board is not yours", %{conn: conn} do
    assert redirected_to(get(conn, "/someone-else/grid")) == "/home"
  end
end
