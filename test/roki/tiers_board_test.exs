defmodule Roki.TiersBoardTest do
  use Roki.DataCase, async: false

  alias Roki.{Profile, Tiers}

  defp register(username) do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "#{username}@example.com",
        "password" => "a-long-enough-password-123",
        "username" => username
      })

    user
  end

  # A season of an anime the way the site keeps it: its MyAnimeList entry (`type`/`id` "mal"), the
  # show it belongs to on TMDB, and the season's number there.
  defp season(user, mal, tmdb, season) do
    {:ok, bin} = Ecto.UUID.dump(user.uuid)

    Repo.query!(
      "insert into roki_watched (user_uuid, type, id, tmdb_type, tmdb_id, season, title, anime, at, dated) " <>
        "values ($1, 'mal', $2, 'tv', $3, $4, $5, true, now(), true)",
      [bin, mal, tmdb, season, "Show part #{season}"]
    )
  end

  defp rate(user, key, score), do: Profile.note_rating(user.uuid, key, score)

  defp board(user) do
    {buckets, _placed} = Tiers.board(user.uuid)
    for {_tier, items} <- buckets, i <- items, into: %{}, do: {i.key_string, i}
  end

  test "an anime season is placed by its own MyAnimeList score, not left unrated" do
    user = register("tierseason")
    season(user, 111, 5000, 1)
    rate(user, {"mal", 111}, 9.0)

    assert %{"mal:111" => %{tier: "a", placed?: true}} = board(user)
  end

  test "two seasons of one show are two entries, each in the tier its own score says" do
    user = register("tiertwo")
    season(user, 201, 6000, 1)
    season(user, 202, 6000, 2)
    rate(user, {"mal", 201}, 10.0)
    rate(user, {"mal", 202}, 6.0)

    entries = board(user)
    assert map_size(entries) == 2
    assert entries["mal:201"].tier == "s"
    assert entries["mal:202"].tier == "d"
  end

  test "a season with no score of its own falls back to a rating of the show" do
    user = register("tierfallback")
    season(user, 301, 7000, 1)
    rate(user, {"tv", 7000}, 8.0)

    assert %{"mal:301" => %{tier: "b"}} = board(user)
  end

  test "a place saved before seasons had keys of their own is still where the season sits" do
    user = register("tierlegacy")
    season(user, 401, 8000, 1)
    Tiers.replace(user.uuid, %{"e" => [{"tv", 8000}]})

    assert %{"mal:401" => %{tier: "e", placed?: false}} = board(user)
  end

  test "an anime season with no score at all is the pool's" do
    user = register("tierpool")
    season(user, 501, 9000, 1)

    assert %{"mal:501" => %{tier: "pool"}} = board(user)
  end

  test "a film or a show watched whole keeps its TMDB key" do
    assert Tiers.tier_key(%{type: "movie", id: 603, mal_id: nil}) == {"movie", 603}
    assert Tiers.tier_key(%{type: "tv", id: 1396}) == {"tv", 1396}
    assert Tiers.tier_key(%{type: "tv", id: 45790, mal_id: 20899}) == {"mal", 20899}
  end
end
