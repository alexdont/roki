defmodule Roki.AdminWatchTest do
  use Roki.DataCase, async: false

  alias Roki.{AdminWatch, Keys}

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
    do:
      for(
        n <- PhoenixKit.Notifications.recent_for_user(user.uuid, 20),
        do: PhoenixKit.Notifications.Render.render(n)
      )

  test "the owner hears of each new account after the first look, never of their own" do
    owner = register("watchowner")
    Keys.save_config!(owner.uuid, Keys.shareable())

    # The first look only marks the time: the accounts that are already there are not news.
    assert AdminWatch.signups(owner.uuid) == 0
    assert bell(owner) == []

    Process.sleep(1_100)
    register("watchnewbie")
    assert AdminWatch.signups(owner.uuid) == 1
    assert [%{text: "New account: watchnewbie", link: "/u/watchnewbie/profile"}] = bell(owner)

    # Looked at again: nothing new.
    assert AdminWatch.signups(owner.uuid) == 0
    assert length(bell(owner)) == 1
  end

  test "an account that borrows the keys and uses its daily plays up is told to the owner once a day" do
    owner = register("limitowner")
    borrower = register("limitborrower")
    Keys.save_config!(owner.uuid, Keys.shareable())
    Keys.grant!(borrower.uuid, 2)

    today = ~D[2026-10-27]
    assert AdminWatch.limits(owner.uuid, today) == 0

    Keys.record(borrower.uuid, :play, 2)
    assert AdminWatch.limits(owner.uuid, today) == 1

    assert [
             %{
               text: "limitborrower reached today's limit of 2 plays",
               icon: "hero-exclamation-triangle"
             }
           ] = bell(owner)

    # Not again the same day, and the owner's own account is never listed.
    assert AdminWatch.limits(owner.uuid, today) == 0
    assert length(bell(owner)) == 1
  end

  test "with no owner chosen there is no one to tell" do
    Keys.save_config!(nil, Keys.shareable())
    assert AdminWatch.check() == 0
  end
end
