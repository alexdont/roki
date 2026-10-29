defmodule Roki.ImdbDatesTest do
  use Roki.DataCase, async: true

  alias Roki.{ImdbDates, Profile}

  @uuid "0199f7a1-0000-7000-8000-000000000002"

  @csv """
  Const,Your Rating,Date Rated,Title,Original Title,URL,Title Type,Year
  tt1,8,2024-05-03,"A, Film",x,u,Movie,2020
  tt2,9,2023-01-02,Show,x,u,TV Series,2021
  tt3,7,2022-02-02,Episode,x,u,TV Episode,2021
  tt4,7,2021-03-03,Old,x,u,Movie,2019
  tt5,7,2020-04-04,Unlisted,x,u,Movie,2019
  tt6,7,2020-05-05,Ghost,x,u,Movie,2019
  tt7,7,not a date,Bad,x,u,Movie,2019
  """

  test "an export is read down to its titles, episodes and bad dates left out" do
    assert {:ok, rows} = ImdbDates.parse(@csv)
    assert Enum.map(rows, & &1.const) == ["tt1", "tt2", "tt4", "tt5", "tt6"]
    assert hd(rows).date == ~D[2024-05-03]
    assert {:error, :not_imdb} = ImdbDates.parse("a,b\n1,2\n")
    assert {:error, :not_imdb} = ImdbDates.parse("")
  end

  test "undated watched titles take the rated date; set dates stay" do
    {:ok, bin} = Ecto.UUID.dump(@uuid)

    for {type, id} <- [{"movie", 1}, {"tv", 2}, {"movie", 4}] do
      Roki.Repo.query!(
        "insert into roki_watched (user_uuid, type, id, tmdb_type, tmdb_id, title, anime, at, dated, status) values ($1, $2, $3, $2, $3, 'T', false, now(), false, 'finished')",
        [bin, type, id]
      )
    end

    assert {:ok, 1} = Profile.set_watched_at(@uuid, ["movie:4"], ~D[2010-01-01])

    resolve = fn
      "tt1" -> {"movie", 1}
      "tt2" -> {"tv", 2}
      "tt4" -> {"movie", 4}
      "tt5" -> {"movie", 5}
      _ -> nil
    end

    assert {:ok, %{dated: 2, kept: 1, unlisted: 1, unresolved: 1}} =
             ImdbDates.import(@uuid, @csv, resolve)

    by_key =
      Map.new(Profile.history(@uuid), &{&1.key, DateTime.from_unix!(&1.at) |> DateTime.to_date()})

    assert by_key["movie:1"] == ~D[2024-05-03]
    assert by_key["tv:2"] == ~D[2023-01-02]
    assert by_key["movie:4"] == ~D[2010-01-01]
  end
end
