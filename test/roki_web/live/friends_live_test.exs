defmodule RokiWeb.FriendsLiveTest do
  use RokiWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Roki.Social

  defp register(username) do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "#{username}@example.com",
        "password" => "a-long-enough-password-123",
        "username" => username
      })

    user
  end

  defp signed_in(user) do
    token = PhoenixKit.Users.Auth.generate_user_session_token(user, [])
    Plug.Test.init_test_session(build_conn(), %{user_token: token})
  end

  setup do
    PhoenixKitUserConnections.enable_system()
    PhoenixKitComments.enable_system()
    {:ok, ann: register("friendann"), bob: register("friendbob")}
  end

  test "a title's comment thread is one id, the same every time, and different for a show of the same number" do
    assert Social.title_uuid("movie", 603) == Social.title_uuid("movie", 603)
    refute Social.title_uuid("movie", 603) == Social.title_uuid("tv", 603)
    refute Social.title_uuid("movie", 603) == Social.title_uuid("movie", 604)
    assert {:ok, _} = Ecto.UUID.cast(Social.title_uuid("movie", 603))
    # A version 5 UUID: the version digit leads the third group.
    assert Social.title_uuid("tv", 1) =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-/
  end

  test "asking, answering, taking back and ending a friendship", %{ann: ann, bob: bob} do
    assert Social.relationship(ann.uuid, ann.uuid) == nil
    assert %{connected: false, connection_pending: nil} = Social.relationship(ann.uuid, bob.uuid)

    assert {:ok, _} = Social.request(ann.uuid, bob.uuid)
    assert Social.relationship(ann.uuid, bob.uuid).connection_pending == :sent
    assert Social.relationship(bob.uuid, ann.uuid).connection_pending == :received
    assert Social.pending_count(bob.uuid) == 1
    assert Enum.map(Social.requests_in(bob.uuid), & &1.username) == ["friendann"]
    assert Enum.map(Social.requests_out(ann.uuid), & &1.username) == ["friendbob"]

    # Taking it back leaves nothing waiting.
    assert {:ok, _} = Social.cancel(ann.uuid, bob.uuid)
    assert Social.pending_count(bob.uuid) == 0

    # Asking and being turned down.
    {:ok, _} = Social.request(ann.uuid, bob.uuid)
    assert {:ok, _} = Social.decline(bob.uuid, ann.uuid)
    refute Social.relationship(ann.uuid, bob.uuid).connected

    # Asking and being accepted: both see a friend.
    {:ok, _} = Social.request(ann.uuid, bob.uuid)
    assert {:ok, _} = Social.accept(bob.uuid, ann.uuid)
    assert {Social.friend_count(ann.uuid), Social.friend_count(bob.uuid)} == {1, 1}
    assert Enum.map(Social.friends(ann.uuid), & &1.username) == ["friendbob"]
    assert Enum.map(Social.friends(bob.uuid), & &1.username) == ["friendann"]

    assert {:ok, _} = Social.remove(bob.uuid, ann.uuid)
    assert {Social.friend_count(ann.uuid), Social.friend_count(bob.uuid)} == {0, 0}

    # There is nothing to answer when nobody asked.
    assert {:error, :not_found} = Social.accept(bob.uuid, ann.uuid)
  end

  test "a visitor's buttons on a profile follow how the two stand", %{ann: ann, bob: bob} do
    {:ok, view, html} = live(signed_in(ann), "/friendbob")
    assert html =~ "Add friend"
    assert html =~ "0 friends"

    view |> element("button[phx-click=friend_add]") |> render_click()
    assert render(view) =~ "Request sent"
    refute has_element?(view, "button[phx-click=friend_add]")

    # Their side: the request is waiting, on their own page and on the asker's.
    {:ok, own, own_html} = live(signed_in(bob), "/friendbob")
    assert own_html =~ "1 new"
    refute has_element?(own, "button[phx-click^=friend_]")

    {:ok, theirs, _} = live(signed_in(bob), "/friendann")
    assert has_element?(theirs, "button[phx-click=friend_accept]")
    theirs |> element("button[phx-click=friend_accept]") |> render_click()
    assert render(theirs) =~ "1 friend"
    assert has_element?(theirs, "button[phx-click=friend_remove]")

    {:ok, _list, friends_html} = live(signed_in(bob), "/friendbob/friends")
    assert friends_html =~ "friendann"
  end

  test "the friends page: open to anyone, and the answers are the owner's", %{ann: ann, bob: bob} do
    {:ok, _} = Social.request(ann.uuid, bob.uuid)

    # A visitor sees the page and no requests.
    {:ok, visitor, html} = live(signed_in(ann), "/friendbob/friends")
    assert html =~ "Friends"
    refute html =~ "Asking to be your friend"
    # A visitor's answer does nothing.
    render_click(visitor, "accept", %{"uuid" => ann.uuid})
    assert Social.pending_count(bob.uuid) == 1

    # The owner sees who asked, and accepts.
    {:ok, owner, owner_html} = live(signed_in(bob), "/friendbob/friends")
    assert owner_html =~ "Asking to be your friend"
    assert owner_html =~ "friendann"
    owner |> element("button[phx-click=accept]") |> render_click()
    refute render(owner) =~ "Asking to be your friend"
    assert Social.friend_count(bob.uuid) == 1

    {:ok, _gone, missing} = live(signed_in(bob), "/nobody-here-either/friends")
    assert missing =~ "There is no one called"
  end

  test "a profile has a comment thread at its bottom" do
    ann = register("commentann")
    {:ok, _view, html} = live(signed_in(ann), "/commentann")
    assert html =~ "Comments"
  end
end
