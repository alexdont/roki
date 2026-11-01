defmodule Roki.SeasonPostersTest do
  use Roki.DataCase, async: false

  alias Roki.{Repo, SeasonPosters}

  @tv 990_001
  @url "https://image.tmdb.org/t/p/w342"

  # What TMDB would have said, put where `SeasonPosters` keeps it, so nothing is asked of TMDB.
  defp keep(tv_id, seasons) do
    for {n, date, path} <- seasons do
      Repo.query!(
        "insert into roki_tv_seasons (tv_id, season, air_date, poster_path) values ($1, $2, $3, $4)",
        [tv_id, n, date && Date.from_iso8601!(date), path]
      )
    end

    Repo.query!("insert into roki_tv_seasons_read (tv_id, read_at) values ($1, now())", [tv_id])
  end

  setup do
    keep(@tv, [
      {0, "2017-09-20", "/special.jpg"},
      {1, "2012-10-06", "/s1.jpg"},
      {2, "2014-04-05", "/s2.jpg"},
      {3, "2016-04-02", "/s3.jpg"}
    ])

    :ok
  end

  defp item(attrs), do: Map.merge(%{type: "tv", id: @tv, poster: "show-poster", title: "T"}, attrs)

  test "a title that is a season gets that season's poster" do
    [a, b] = SeasonPosters.apply([item(%{season: 2}), item(%{season: 3})], nil)
    assert a.poster == @url <> "/s2.jpg"
    assert b.poster == @url <> "/s3.jpg"
  end

  test "two entries of different seasons of one show are different pictures" do
    items = for n <- 1..3, do: item(%{season: n})
    posters = items |> SeasonPosters.apply(nil) |> Enum.map(& &1.poster) |> Enum.uniq()
    assert length(posters) == 3
  end

  test "an anime naming no season gets the latest season that has begun" do
    [a] = SeasonPosters.apply([item(%{anime: true})], nil)
    assert a.poster == @url <> "/s3.jpg"
  end

  test "a show naming no season, and not anime, keeps the show's poster" do
    assert [%{poster: "show-poster"}] = SeasonPosters.apply([item(%{})], nil)
  end

  test "films, other kinds and a season TMDB has no poster for are left as they were" do
    keep(990_002, [{1, "2020-01-01", "/a.jpg"}, {2, "2021-01-01", nil}])

    items = [
      %{type: "movie", id: @tv, season: 2, poster: "film"},
      %{type: "manga", id: 5, poster: "manga"},
      item(%{id: 990_002, season: 2}),
      item(%{season: 9})
    ]

    assert SeasonPosters.apply(items, nil) == items
  end

  test "a show with one season gets nothing to say when no season is named" do
    keep(990_003, [{1, "2020-01-01", "/only.jpg"}])
    assert [%{poster: "show-poster"}] = SeasonPosters.apply([item(%{id: 990_003, anime: true})], nil)
  end

  test "stored_poster reads what is kept, and nothing else" do
    assert SeasonPosters.stored_poster(@tv, 2) == @url <> "/s2.jpg"
    assert SeasonPosters.stored_poster(@tv, 8) == nil
    assert SeasonPosters.stored_poster(777, 1) == nil
  end

  test "an anime's title page is drawn as the season on screen" do
    title = %{type: "tv", anime?: true, id: @tv, poster: "first"}
    assert SeasonPosters.for_title(title, 3, nil).poster == "https://image.tmdb.org/t/p/w500/s3.jpg"
    assert SeasonPosters.for_title(title, 9, nil) == title
    plain = %{type: "tv", anime?: false, id: @tv, poster: "first"}
    assert SeasonPosters.for_title(plain, 3, nil) == plain
  end
end
