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

  defp told(user), do: for(n <- PhoenixKit.Notifications.recent_for_user(user.uuid, 20), do: PhoenixKit.Notifications.Render.render(n))

  test "a friend request tells the other person, with where to answer it; accepting tells the asker", %{ann: ann, bob: bob} do
    {:ok, _} = Social.request(ann.uuid, bob.uuid)

    assert [%{text: "friendann sent you a friend request", link: "/friendbob/friends", icon: "hero-user-plus"}] = told(bob)
    assert told(ann) == []

    {:ok, _} = Social.accept(bob.uuid, ann.uuid)
    assert [%{text: "friendbob accepted your friend request", link: "/friendbob"}] = told(ann)

    # Turning someone down is not announced.
    {:ok, _} = Social.remove(ann.uuid, bob.uuid)
    {:ok, _} = Social.request(ann.uuid, bob.uuid)
    {:ok, _} = Social.decline(bob.uuid, ann.uuid)
    assert length(told(ann)) == 1
  end

  test "when two people ask each other, both are friends and each is told the right thing", %{ann: ann, bob: bob} do
    {:ok, _} = Social.request(ann.uuid, bob.uuid)
    {:ok, _} = Social.request(bob.uuid, ann.uuid)

    assert Social.relationship(ann.uuid, bob.uuid).connected
    # Bob heard that ann asked; ann hears that bob accepted (his asking was the answer).
    assert Enum.map(told(bob), & &1.text) == ["friendann sent you a friend request"]
    assert Enum.map(told(ann), & &1.text) == ["friendbob accepted your friend request"]
    assert Social.pending_count(bob.uuid) == 0
  end

  test "asking again after taking a request back tells them again; a refused ask (already friends) says nothing", %{ann: ann, bob: bob} do
    {:ok, _} = Social.request(ann.uuid, bob.uuid)
    {:ok, _} = Social.cancel(ann.uuid, bob.uuid)
    {:ok, _} = Social.request(ann.uuid, bob.uuid)
    assert length(told(bob)) == 2

    {:ok, _} = Social.accept(bob.uuid, ann.uuid)
    assert {:error, :already_connected} = Social.request(ann.uuid, bob.uuid)
    assert length(told(bob)) == 2
  end

  test "a comment on a profile tells its owner, a reply tells the one replied to, and never the writer", %{ann: ann, bob: bob} do
    {:ok, first} = PhoenixKitComments.create_comment("profile", bob.uuid, ann.uuid, %{content: "hello bob"})
    assert [%{text: "friendann commented on your profile", link: "/friendbob"}] = told(bob)
    assert told(ann) == []

    # Bob answers on his own page: ann is told, bob is not told of his own writing.
    {:ok, _} = PhoenixKitComments.create_comment("profile", bob.uuid, bob.uuid, %{content: "hi ann", parent_uuid: first.uuid})
    assert Enum.map(told(ann), & &1.text) == ["friendbob replied to your comment"]
    assert length(told(bob)) == 1

    # Someone commenting on their own profile tells no one.
    {:ok, _} = PhoenixKitComments.create_comment("profile", ann.uuid, ann.uuid, %{content: "note to self"})
    assert length(told(ann)) == 1
  end

  test "a like tells the one who wrote the comment, never the liker, and not for a dislike", %{ann: ann, bob: bob} do
    {:ok, comment} = PhoenixKitComments.create_comment("profile", bob.uuid, ann.uuid, %{content: "worth a like"})
    assert length(told(bob)) == 1

    PhoenixKitComments.like_comment(comment.uuid, bob.uuid)
    assert Enum.map(told(ann), & &1.text) == ["friendbob liked your comment"]

    # Liking your own comment, or taking a like back and giving it again, tells no one new.
    PhoenixKitComments.like_comment(comment.uuid, ann.uuid)
    assert length(told(ann)) == 1

    # A dislike is not announced.
    {:ok, other} = PhoenixKitComments.create_comment("profile", bob.uuid, ann.uuid, %{content: "meh"})
    PhoenixKitComments.dislike_comment(other.uuid, bob.uuid)
    assert length(told(ann)) == 1
  end

  test "a name written as @username is told, unless they switched comment notices off", %{ann: ann, bob: bob} do
    carol = register("friendcarol")

    {:ok, _} = PhoenixKitComments.create_comment("profile", ann.uuid, ann.uuid, %{content: "thanks @friendbob and @friendcarol, not @nobodyatall"})
    assert Enum.map(told(bob), & &1.text) == ["friendann mentioned you in a comment"]
    assert Enum.map(told(carol), & &1.text) == ["friendann mentioned you in a comment"]

    Roki.Notify.set(carol.uuid, "comments", false)
    {:ok, _} = PhoenixKitComments.create_comment("profile", ann.uuid, ann.uuid, %{content: "again @friendcarol"})
    assert length(told(carol)) == 1

    # Naming yourself tells no one; the profile's owner is told once, as the owner, not twice.
    {:ok, _} = PhoenixKitComments.create_comment("profile", bob.uuid, ann.uuid, %{content: "hello @friendbob @friendann"})
    assert Enum.sort(Enum.map(told(bob), & &1.text)) == ["friendann commented on your profile", "friendann mentioned you in a comment"]
    assert Roki.CommentHandler.mentioned("a @friendbob, @friendbob. and @friendbob") == [bob.uuid]
  end

  test "friend activity: told only to friends who asked, once per title, and never for the test account", %{ann: ann, bob: bob} do
    carol = register("friendcarol2")
    # What friends did, apart from the friend requests that made them friends.
    news = fn user -> Enum.reject(told(user), &(&1.text =~ ~r/accepted|friend request/)) end

    for friend <- [bob, carol] do
      {:ok, _} = Social.request(ann.uuid, friend.uuid)
      {:ok, _} = Social.accept(friend.uuid, ann.uuid)
    end

    # Starts off: nobody is told what their friends do until they ask.
    Social.friend_activity(ann.uuid, :finished, "movie", 603, "The Matrix")
    assert news.(bob) == []

    Roki.Notify.set(bob.uuid, "friend_activity", true)
    Social.friend_activity(ann.uuid, :finished, "movie", 604, "Reloaded")

    assert [%{text: "friendann finished Reloaded", link: "/title/movie/604", icon: "hero-film"}] = news.(bob)
    assert news.(carol) == []

    # Rating the same film right after finishing it is the same news.
    Social.friend_activity(ann.uuid, :rated, "movie", 604, "Reloaded", 9.0)
    assert length(news.(bob)) == 1

    # Another film, rated: the score is in it.
    Social.friend_activity(ann.uuid, :rated, "movie", 605, "Revolutions", 6.5)
    assert "friendann rated Revolutions ★ 6.5" in Enum.map(told(bob), & &1.text)

    # The friend's own doings are not told back to them, and strangers hear nothing.
    stranger = register("friendstranger")
    Roki.Notify.set(stranger.uuid, "friend_activity", true)
    Social.friend_activity(ann.uuid, :finished, "movie", 700, "Another")
    assert told(stranger) == []
  end

  test "a reply on a title names the title and links to it; the moderation list names it too", %{ann: ann, bob: bob} do
    Social.remember_title("movie", 603, "The Matrix")
    thread = Social.title_uuid("movie", 603)

    {:ok, first} = PhoenixKitComments.create_comment("title", thread, ann.uuid, %{content: "great"})
    {:ok, _} = PhoenixKitComments.create_comment("title", thread, bob.uuid, %{content: "agreed", parent_uuid: first.uuid})

    assert [%{text: "friendbob replied to your comment on The Matrix", link: "/title/movie/603"}] = told(ann)
    # A first comment on a title has no one to tell.
    assert told(bob) == []

    assert %{^thread => %{title: "The Matrix", path: "/title/movie/603"}} = Roki.CommentHandler.Title.resolve_comment_resources([thread])
    assert %{} = Roki.CommentHandler.Profile.resolve_comment_resources([bob.uuid])
    assert Roki.CommentHandler.Profile.resolve_comment_resources([bob.uuid])[bob.uuid].path == "/friendbob"
  end

  test "the bell is in the header of a signed-in person's pages, and not a visitor's", %{ann: ann} do
    {:ok, _view, html} = live(signed_in(ann), "/friendann")
    assert html =~ ~s(title="Notifications")

    {:ok, _view, visitor_html} = live(build_conn(), "/friendann")
    refute visitor_html =~ ~s(title="Notifications")
  end

  test "a profile has a comment thread at its bottom" do
    ann = register("commentann")
    {:ok, _view, html} = live(signed_in(ann), "/commentann")
    assert html =~ "Comments"
  end
end
