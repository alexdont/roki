defmodule Roki.ActivityDbTest do
  use Roki.DataCase, async: false

  alias Roki.Activity

  defp register(username) do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "#{username}@example.com",
        "password" => "a-long-enough-password-123",
        "username" => username
      })

    user
  end

  defp film(id), do: %{type: "movie", tmdb_id: id, title: "Film #{id}"}

  test "a recent finish becomes the backdating instead of staying a finish" do
    u = register("activ1")
    Activity.insert_now(u.uuid, film(1), "finished")
    assert Activity.backdated(u.uuid, [film(1)], ~D[2015-05-05]) == 1

    [e] = Activity.recent(10, users: [u.uuid])
    assert e.kind == "backdated" and e.watched_on == ~D[2015-05-05]
    assert Activity.recent(10, users: [u.uuid], kinds: ["finished"]) == []
  end

  test "backdating a title with no recent finish adds an entry of its own" do
    u = register("activ2")
    assert Activity.backdated(u.uuid, [film(2)], ~D[2012-01-01]) == 1
    assert [%{kind: "backdated", title: "Film 2"}] = Activity.recent(10, users: [u.uuid])
  end

  test "unmarking takes the finish out of the feed, and only that title's" do
    u = register("activ9")
    Activity.insert_now(u.uuid, film(8), "finished")
    Activity.insert_now(u.uuid, film(9), "finished")
    Activity.insert_now(u.uuid, film(8), "saved")

    assert Activity.retract(u.uuid, "movie", 8, ["finished", "backdated"]) == 1
    kinds = Activity.recent(10, users: [u.uuid]) |> Enum.map(&{&1.title, &1.kind}) |> Enum.sort()
    assert kinds == [{"Film 8", "saved"}, {"Film 9", "finished"}]
  end

  test "the test account records nothing" do
    u = register("test")
    assert Activity.backdated(u.uuid, [film(3)], ~D[2012-01-01]) == 0
    Activity.insert_now(u.uuid, film(3), "saved")
    assert Activity.recent(10, users: [u.uuid]) == []
  end

  test "recent filters by kind and by person" do
    a = register("activ3")
    b = register("activ4")
    Activity.insert_now(a.uuid, film(4), "saved")
    Activity.insert_now(a.uuid, film(5), "finished")
    Activity.insert_now(b.uuid, film(6), "saved")

    assert [%{kind: "saved", username: "activ3"}] =
             Activity.recent(10, users: [a.uuid], kinds: ["saved"])

    assert length(Activity.recent(10, users: [a.uuid])) == 2

    names =
      Activity.recent(10, kinds: ["saved"])
      |> Enum.flat_map(&if(&1.batch?, do: [&1.username], else: [&1.username]))

    assert "activ3" in names and "activ4" in names
  end

  test "what a deleted account did is not shown as someone" do
    u = register("activ4")
    Activity.insert_now(u.uuid, film(4), "finished")
    assert [%{username: "activ4"}] = Activity.recent(10)

    Roki.Repo.query!("delete from phoenix_kit_users where uuid = $1", [Ecto.UUID.dump!(u.uuid)])
    assert Activity.recent(10) == []
  end
end
