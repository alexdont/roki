defmodule Roki.PenguAccessTest do
  use Roki.DataCase, async: false

  alias Roki.{Keys, Pengu}

  @link "https://pengu.uk/%7B%22auth_token%22%3A%22abc%22%7D/manifest.json"
  @base "https://pengu.uk/%7B%22auth_token%22%3A%22abc%22%7D"

  defp register(username) do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "#{username}@example.com",
        "password" => "a-long-enough-password-123",
        "username" => username
      })

    user
  end

  defp give_link(user) do
    {:ok, _} =
      PhoenixKit.Users.Auth.update_user_custom_fields(
        user,
        Map.put(user.custom_fields || %{}, "pengu_addon_url", @link)
      )

    Roki.TTLCache.delete({:pengu_own, user.uuid})
  end

  setup do
    owner = register("pgowner")
    friend = register("pgfriend")
    Keys.save_config!(owner.uuid, Keys.shareable())
    Keys.revoke!(friend.uuid)
    give_link(owner)
    on_exit(fn -> Roki.TTLCache.delete(:key_config) end)
    %{owner: owner, friend: friend}
  end

  test "an account with a link of its own searches with it", %{friend: friend} do
    assert Pengu.account(friend.uuid) == nil
    give_link(friend)
    assert Pengu.account(friend.uuid) == {:own, @base}
    assert Pengu.configured?(friend.uuid)
  end

  test "the owner's link reaches only the accounts it is lent to", %{owner: owner, friend: friend} do
    assert Pengu.account(owner.uuid) == {:own, @base}
    assert Pengu.account(friend.uuid) == nil

    Keys.set_pengu!(friend.uuid, true)
    assert Pengu.account(friend.uuid) == {:lent, @base}
    assert %{kind: :lent, used: 0, cap: 30} = Pengu.status(friend.uuid)

    Keys.set_pengu!(friend.uuid, false)
    assert Pengu.account(friend.uuid) == nil
  end

  test "lending PenguPlay leaves the lent API keys alone", %{friend: friend} do
    Keys.set_access!(friend.uuid, %{keys: ["TMDB_API_KEY"], heavy: false})
    Keys.set_pengu!(friend.uuid, true)
    assert %{keys: ["TMDB_API_KEY"], pengu: true} = Keys.grant(friend.uuid)

    Keys.set_access!(friend.uuid, %{keys: [], heavy: false})
    assert Keys.pengu_lent?(friend.uuid), "taking the keys away keeps the PenguPlay lending"
  end

  test "a lent account stops at its daily cap, before anything is asked of PenguPlay", %{
    friend: friend
  } do
    Keys.set_pengu!(friend.uuid, true)
    Keys.set_daily_pengu!(friend.uuid, 2)
    assert Keys.pengu_allowed?(friend.uuid)

    Keys.record_pengu(friend.uuid)
    Keys.record_pengu(friend.uuid)
    assert Keys.pengu_today(friend.uuid) == 2
    refute Keys.pengu_allowed?(friend.uuid)

    # A title nobody searched yet: it would be a real request, so the cap answers instead.
    assert {:error, :cap} = Pengu.streams(friend.uuid, "tt0000001")
  end

  test "Sources says what an account can play from, and follows lending", %{friend: friend} do
    assert %{torrent: false, pengu: false} = Roki.Sources.available(friend.uuid)

    Keys.set_pengu!(friend.uuid, true)
    assert %{pengu: true} = Roki.Sources.available(friend.uuid)

    Keys.set_pengu!(friend.uuid, false)
    assert %{pengu: false} = Roki.Sources.available(friend.uuid)
    assert Roki.Sources.current(friend.uuid, %{torrent: false, pengu: true}) == :pengu
    assert Roki.Sources.current(friend.uuid, %{torrent: true, pengu: true}) == :torrent
  end

  test "an account on its own link is not capped", %{friend: friend} do
    give_link(friend)
    Keys.set_pengu!(friend.uuid, true)
    Keys.set_daily_pengu!(friend.uuid, 0)
    assert {:own, _} = Pengu.account(friend.uuid)
  end
end
