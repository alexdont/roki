defmodule RokiWeb.MangaArcDateTest do
  @moduledoc """
  The Adjust Time Read dialog's arc dates, from the form to the row and back.
  """
  use RokiWeb.ConnCase

  alias Roki.Manga.ArcDates
  alias Roki.Manga.Library

  setup %{conn: conn} do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "arcdate@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "arcdate"
      })

    {:ok, _} =
      Library.save_manga(user.uuid, %{
        source: "mangafreak",
        slug: "berserk",
        title: "Berserk",
        cover_url: "https://example.invalid/b.jpg"
      })

    token = PhoenixKit.Users.Auth.generate_user_session_token(user, [])
    {:ok, conn: Plug.Test.init_test_session(conn, %{user_token: token}), user: user}
  end

  test "a date on the form is saved, and an empty field clears it", %{conn: conn, user: user} do
    put(conn, ~p"/manga/mangafreak/berserk/reading_time", %{
      "arc_date" => %{"arc:3" => "2019-06-01", "arc:4" => ""}
    })

    assert ArcDates.get(user.uuid, "mangafreak", "berserk") == %{{"arc", 3} => ~D[2019-06-01]}

    put(conn, ~p"/manga/mangafreak/berserk/reading_time", %{"arc_date" => %{"arc:3" => ""}})

    assert ArcDates.get(user.uuid, "mangafreak", "berserk") == %{}
  end

  test "a volume is dated the same way, and junk is ignored", %{conn: conn, user: user} do
    put(conn, ~p"/manga/mangafreak/berserk/reading_time", %{
      "arc_date" => %{
        "volume:2" => "2020-02-02",
        "season:1" => "2020-02-02",
        "arc:abc" => "2020-02-02"
      }
    })

    assert ArcDates.get(user.uuid, "mangafreak", "berserk") == %{{"volume", 2} => ~D[2020-02-02]}
  end
end
