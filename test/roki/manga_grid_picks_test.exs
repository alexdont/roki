defmodule Roki.MangaGridPicksTest do
  @moduledoc """
  The manga shelf on a profile reads the reader's grid. Which of its three boards it reads,
  and in what order, is the whole of the rule — so it is the whole of this test.
  """
  use Roki.DataCase

  alias Roki.Manga.Library

  defp user(name) do
    {:ok, u} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "#{name}@example.com",
        "password" => "a-long-enough-password-123",
        "username" => name
      })

    u
  end

  defp save!(user, slug) do
    {:ok, _} =
      Library.save_manga(user.uuid, %{
        source: "mangadex",
        slug: slug,
        title: String.upcase(slug),
        cover_url: "https://example.invalid/#{slug}.jpg"
      })
  end

  defp place!(user, mode, slot, slug) do
    {:ok, bin} = Ecto.UUID.dump(user.uuid)

    Roki.Repo.query!(
      "insert into manga_grid_slots (user_id, slot, mode, label, source, slug, inserted_at, updated_at) " <>
        "values ($1, $2, $3, 'x', 'mangadex', $4, now(), now())",
      [bin, slot, mode, slug]
    )
  end

  test "the Overall board is the shelf when it has anything on it" do
    u = user("gridoverall")
    for s <- ~w(a b c), do: save!(u, s)
    place!(u, "overall", 2, "b")
    place!(u, "overall", 1, "a")
    place!(u, "manga", 1, "c")

    assert Enum.map(Library.list_grid_picks(u.uuid), & &1.slug) == ["a", "b"]
  end

  test "with Overall empty the other two boards stand in, rank by rank, manga then manhwa" do
    u = user("gridboth")
    for s <- ~w(m1 m2 w1 w2), do: save!(u, s)
    place!(u, "manga", 1, "m1")
    place!(u, "manga", 2, "m2")
    place!(u, "manhwa", 1, "w1")
    place!(u, "manhwa", 2, "w2")

    assert Enum.map(Library.list_grid_picks(u.uuid), & &1.slug) == ["m1", "w1", "m2", "w2"]
  end

  test "a place pointing at a series no longer saved costs the shelf nothing" do
    u = user("gridgone")
    for s <- ~w(a b c), do: save!(u, s)
    place!(u, "manga", 1, "a")
    place!(u, "manga", 2, "vanished")
    place!(u, "manga", 3, "b")

    picks = Library.list_grid_picks(u.uuid, 2)
    assert Enum.map(picks, & &1.slug) == ["a", "b"]
    assert hd(picks).title == "A"
  end
end
