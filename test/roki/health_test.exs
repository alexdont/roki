defmodule Roki.HealthTest do
  use Roki.DataCase, async: false

  alias Roki.{Health, Notify}

  defp register(username) do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "#{username}@example.com",
        "password" => "a-long-enough-password-123",
        "username" => username
      })

    user
  end

  defp bell(user),
    do: for(n <- PhoenixKit.Notifications.recent_for_user(user.uuid, 20), do: PhoenixKit.Notifications.Render.render(n))

  test "how near the end a premium is: fine, then the steps people are told at, then gone" do
    now = ~U[2026-10-27 12:00:00Z]
    in_days = fn d -> now |> DateTime.add(round(d * 86_400), :second) |> DateTime.to_iso8601() end

    assert Health.premium(in_days.(30), true, now) == :ok
    assert Health.premium(in_days.(6.5), true, now) == {:bad, "expiring:7"}
    assert Health.premium(in_days.(2.5), true, now) == {:bad, "expiring:3"}
    assert Health.premium(in_days.(0.5), true, now) == {:bad, "expiring:1"}
    assert Health.premium(in_days.(-1), true, now) == {:bad, "expired"}
    # No date at all is not a problem, but a free account is not premium.
    assert Health.premium(nil, true, now) == :ok
    assert Health.premium(in_days.(30), false, now) == {:bad, "expired"}
  end

  test "a key that is rejected is told at once, once, and again only after it was fixed and broke again" do
    user = register("healthrd")

    assert Health.settle(user.uuid, "rd", {:bad, "rejected"}) == :told
    assert [%{text: "Your Real-Debrid key was rejected, so nothing can play. Add a new one in settings.", link: "/healthrd/settings"}] = bell(user)

    # Still broken at the next check: nothing new to say.
    assert Health.settle(user.uuid, "rd", {:bad, "rejected"}) == :quiet
    assert length(bell(user)) == 1

    # A network failure says nothing either way.
    assert Health.settle(user.uuid, "rd", :unreachable) == :quiet
    assert Health.settle(user.uuid, "rd", {:bad, "rejected"}) == :quiet

    # Fixed, then broken again: news again.
    assert Health.settle(user.uuid, "rd", :ok) == :quiet
    assert Health.settle(user.uuid, "rd", {:bad, "rejected"}) == :told
    assert length(bell(user)) == 2
  end

  test "an ending premium is told at each step nearer, not at each check" do
    user = register("healthpremium")

    assert Health.settle(user.uuid, "torbox", {:bad, "expiring:7"}) == :told
    assert Health.settle(user.uuid, "torbox", {:bad, "expiring:7"}) == :quiet
    assert Health.settle(user.uuid, "torbox", {:bad, "expiring:3"}) == :told
    assert Health.settle(user.uuid, "torbox", {:bad, "expiring:1"}) == :told
    assert Health.settle(user.uuid, "torbox", {:bad, "expired"}) == :told
    assert Enum.map(bell(user), & &1.text) |> Enum.member?("Your TorBox premium ends within 3 days.")
    assert length(bell(user)) == 4
  end

  test "a MyAnimeList or TMDB 'no' has to be said twice in a row before anyone is told" do
    user = register("healthmal")

    assert Health.settle(user.uuid, "mal", {:bad, "invalid"}) == :quiet
    assert bell(user) == []
    # A good answer in between wipes the suspicion.
    assert Health.settle(user.uuid, "mal", :ok) == :quiet
    assert Health.settle(user.uuid, "mal", {:bad, "invalid"}) == :quiet
    assert Health.settle(user.uuid, "mal", {:bad, "invalid"}) == :told

    assert [%{text: "Your MyAnimeList login stopped working. Connect it again in settings."}] = bell(user)

    assert Health.settle(user.uuid, "tmdb", {:bad, "invalid"}) == :quiet
    assert Health.settle(user.uuid, "tmdb", {:bad, "invalid"}) == :told
  end

  test "a problem nobody acted on is told once more after a week" do
    user = register("healthremind")
    assert Health.settle(user.uuid, "rd", {:bad, "locked"}) == :told

    Roki.Repo.query!("update roki_health set told_at = now() - interval '8 days' where user_uuid = $1", [Ecto.UUID.dump!(user.uuid)])
    assert Health.settle(user.uuid, "rd", {:bad, "locked"}) == :told
    assert Health.settle(user.uuid, "rd", {:bad, "locked"}) == :quiet
    assert length(bell(user)) == 2
  end

  test "a login that is not there is not a problem, and clears what was said before" do
    user = register("healthnone")
    assert Health.settle(user.uuid, "rd", {:bad, "rejected"}) == :told
    assert Health.settle(user.uuid, "rd", :none) == :quiet
    assert Health.settle(user.uuid, "rd", {:bad, "rejected"}) == :told
  end

  test "preferences: each kind has a default, a person's choice wins, and an unknown kind is refused" do
    user = register("healthprefs")

    assert Notify.wants?(user.uuid, "release")
    refute Notify.wants?(user.uuid, "friend_activity")

    assert :ok = Notify.set(user.uuid, "release", false)
    assert :ok = Notify.set(user.uuid, "friend_activity", true)
    refute Notify.wants?(user.uuid, "release")
    assert Notify.wants?(user.uuid, "friend_activity")
    assert Notify.choices(user.uuid)["release"] == false
    assert Notify.choices(user.uuid)["digest"] == true

    assert {:error, :unknown_kind} = Notify.set(user.uuid, "nonsense", true)
  end
end
