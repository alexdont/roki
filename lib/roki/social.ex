defmodule Roki.Social do
  @moduledoc """
  The people side of the site, over PhoenixKit's modules: friends (`phoenix_kit_user_connections`,
  the mutual kind: one asks, the other accepts) and the comments on a title or a profile
  (`phoenix_kit_comments`).

  Friends only: following and blocking exist in the module and are not used here yet.
  """

  alias PhoenixKitUserConnections, as: Conn

  # Comments hang off a `(resource_type, resource_uuid)`. A profile is its owner's uuid; a title
  # has no uuid of its own, only TMDB's number, so it gets one made from its kind and number —
  # the same one every time, for everyone (a UUID version 5 in a namespace of the site's own).
  @namespace <<0x5A, 0x1E, 0x7C, 0x3D, 0x90, 0x4B, 0x42, 0x11, 0xB8, 0x6F, 0x0C, 0xE2, 0x71, 0xA3,
               0x5D, 0x94>>

  @doc "The comment thread's resource id of a title (`\"movie\"` or `\"tv\"`, and TMDB's id)."
  def title_uuid(type, id) when type in ["movie", "tv"] and is_integer(id) do
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48, _::binary>> =
      :crypto.hash(:sha, @namespace <> "#{type}:#{id}")

    Ecto.UUID.cast!(<<a::32, b::16, 5::4, c::12, 2::2, d::14, e::48>>)
  end

  @doc "Are friends switched on (the module's own setting)?"
  def friends_on?, do: Conn.enabled?()

  @doc "How `viewer` stands with `other`, or nil for oneself or for a visitor not signed in."
  def relationship(viewer, other) when is_binary(viewer) and is_binary(other) and viewer != other,
    do: Conn.get_relationship(viewer, other)

  def relationship(_viewer, _other), do: nil

  @doc """
  Ask `other` to be a friend. If they had already asked, both are accepted. Either way the other
  person is told (`notify/5`): there is a request for them to answer, or a new friend.
  """
  def request(viewer, other) do
    with {:ok, _} = ok <- Conn.request_connection(viewer, other) do
      if Conn.connected?(viewer, other),
        do: notify_accepted(viewer, other),
        else:
          notify(
            "friend_request",
            viewer,
            other,
            "#{name(viewer)} sent you a friend request",
            "hero-user-plus",
            "/u/#{name(other)}/friends"
          )

      ok
    end
  end

  @doc "Take back a request `viewer` sent to `other`."
  def cancel(viewer, other) do
    case Enum.find(Conn.list_sent_requests(viewer, preload: false), &(&1.recipient_uuid == other)) do
      nil -> {:error, :not_found}
      connection -> Conn.cancel_request(viewer, connection.uuid)
    end
  end

  @doc "Accept the request `other` sent to `viewer`."
  def accept(viewer, other) do
    case incoming(viewer, other) do
      nil ->
        {:error, :not_found}

      connection ->
        with {:ok, _} = ok <- Conn.accept_connection(connection) do
          notify_accepted(viewer, other)
          ok
        end
    end
  end

  @doc "Turn down the request `other` sent to `viewer`."
  def decline(viewer, other) do
    case incoming(viewer, other) do
      nil -> {:error, :not_found}
      connection -> Conn.reject_connection(connection)
    end
  end

  @doc "End a friendship, from either side."
  def remove(viewer, other), do: Conn.remove_connection(viewer, other)

  defp incoming(viewer, other),
    do:
      Enum.find(Conn.list_pending_requests(viewer, preload: false), &(&1.requester_uuid == other))

  # ── notifications ──────────────────────────────────────────────────

  # A notification is a logged activity aimed at someone (`PhoenixKit.Notifications` turns it into
  # a row in their bell). Its words, icon and where a click goes ride in the metadata, which the
  # bell shows as given, so nothing here has to be registered with PhoenixKit first. Nothing is
  # raised: failing to tell someone never fails what was done.
  @doc false
  def notify(action, actor_uuid, target_uuid, text, icon, link) do
    PhoenixKit.Activity.log("roki", "roki." <> action,
      actor_uuid: actor_uuid,
      target_uuid: target_uuid,
      resource_type: "user",
      resource_uuid: actor_uuid,
      metadata: %{
        "notification_text" => text,
        "notification_icon" => icon,
        "notification_link" => link
      }
    )

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Tell the friends of `actor` who asked to hear what their friends do (the "What friends do"
  switch, off unless chosen) that they finished a film (`:finished`) or rated a title (`:rated`,
  with the score). A friend is told about one title at most once in ten minutes — rating a film
  right after finishing it is one piece of news, not two. Nothing for the test account.
  """
  def friend_activity(actor, kind, type, id, title, score \\ nil)

  def friend_activity(actor, kind, type, id, title, score)
      when kind in [:finished, :rated] and type in ["movie", "tv"] and is_integer(id) and
             is_binary(title) do
    if friends_on?() and not Roki.Activity.silent?(actor) do
      who = name(actor)

      for friend <- friends(actor),
          Roki.Notify.wants?(friend.uuid, "friend_activity"),
          first_news?(actor, friend.uuid, type, id) do
        {text, icon} =
          case kind do
            :rated -> {"#{who} rated #{title} ★ #{Roki.Profile.score_text(score)}", "hero-star"}
            :finished -> {"#{who} finished #{title}", "hero-film"}
          end

        notify("friend_activity", actor, friend.uuid, text, icon, "/title/#{type}/#{id}")
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  def friend_activity(_actor, _kind, _type, _id, _title, _score), do: :ok

  defp first_news?(actor, friend, type, id) do
    key = {:friend_note, actor, friend, type, id}

    if Roki.TTLCache.cached?(key) do
      false
    else
      Roki.TTLCache.fetch(key, 600, fn -> {:ok, true} end)
      true
    end
  end

  @doc "Tell `target` what came out (`Roki.Releases.notice/2`): not from anyone, so no actor."
  def notify_release(target, %{text: text, icon: icon, link: link}),
    do: notify_system(target, "release", text, icon, link)

  @doc """
  A notification from the site itself, not from a person (no actor): news, a problem, a summary.
  `kind` names it in the activity log (`roki.<kind>`). `:ok`, or `:error` if it could not be logged.
  """
  def notify_system(target, kind, text, icon, link) do
    PhoenixKit.Activity.log("roki", "roki." <> kind,
      target_uuid: target,
      resource_type: "site",
      metadata: %{
        "notification_text" => text,
        "notification_icon" => icon,
        "notification_link" => link
      }
    )

    :ok
  rescue
    _ -> :error
  end

  defp notify_accepted(accepter, requester),
    do:
      notify(
        "friend_accepted",
        accepter,
        requester,
        "#{name(accepter)} accepted your friend request",
        "hero-user-group",
        "/u/#{name(accepter)}/profile"
      )

  @doc """
  Tell `target` about something in a comment thread, from `commenter`. `kind` is `:comment` (on
  their profile), `:reply` (to a comment of theirs), `:mention` (their name in one) or `:like`
  (of a comment of theirs). `type` and `thread` say where, so the click lands on it.
  """
  def notify_comment(target, commenter, type, thread, kind) do
    {where, link} = thread_place(type, thread)
    who = name(commenter)
    on = if where, do: " on #{where}", else: ""

    {text, icon} =
      case kind do
        :comment -> {"#{who} commented on your profile", "hero-chat-bubble-left-right"}
        :reply -> {"#{who} replied to your comment#{on}", "hero-chat-bubble-left-right"}
        :mention -> {"#{who} mentioned you in a comment#{on}", "hero-at-symbol"}
        :like -> {"#{who} liked your comment#{on}", "hero-heart"}
      end

    notify("comment", commenter, target, text, icon, link)
  end

  # The words and the address of the thread a comment was written in.
  defp thread_place("profile", owner), do: {nil, "/u/" <> (name(owner) || "") <> "/profile"}

  defp thread_place("title", thread) do
    case Roki.CommentHandler.titles([thread])[thread] do
      %{title: title, path: path} -> {title, path}
      _ -> {nil, "/"}
    end
  end

  defp thread_place(_type, _thread), do: {nil, "/"}

  defp name(uuid) do
    case PhoenixKit.Users.Auth.get_user(uuid) do
      %{username: username} -> username
      _ -> "Someone"
    end
  end

  @doc """
  Remember which title a comment thread is (see the `roki_comment_titles` migration), so what
  mentions the thread can name it and link to it.
  """
  def remember_title(type, id, name) when type in ["movie", "tv"] and is_integer(id) do
    Roki.Repo.query!(
      "insert into roki_comment_titles (uuid, type, id, name) values ($1, $2, $3, $4) on conflict (uuid) do update set name = excluded.name",
      [Ecto.UUID.dump!(title_uuid(type, id)), type, id, name]
    )

    :ok
  end

  def remember_title(_type, _id, _name), do: :ok

  @doc "How many friends someone has."
  def friend_count(uuid), do: Conn.connections_count(uuid)

  @doc "How many requests wait for someone's answer."
  def pending_count(uuid), do: Conn.pending_requests_count(uuid)

  @doc "The friends of someone, newest first: the other person of each, as PhoenixKit's user."
  def friends(uuid) do
    for c <- Conn.list_connections(uuid),
        do: if(c.requester_uuid == uuid, do: c.recipient, else: c.requester)
  end

  @doc "Requests that wait for this person's answer: the people who asked."
  def requests_in(uuid), do: for(c <- Conn.list_pending_requests(uuid), do: c.requester)

  @doc "Requests this person has sent that are not answered yet: the people asked."
  def requests_out(uuid), do: for(c <- Conn.list_sent_requests(uuid), do: c.recipient)
end
