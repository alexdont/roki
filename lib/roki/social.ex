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
  @namespace <<0x5A, 0x1E, 0x7C, 0x3D, 0x90, 0x4B, 0x42, 0x11, 0xB8, 0x6F, 0x0C, 0xE2, 0x71, 0xA3, 0x5D, 0x94>>

  @doc "The comment thread's resource id of a title (`\"movie\"` or `\"tv\"`, and TMDB's id)."
  def title_uuid(type, id) when type in ["movie", "tv"] and is_integer(id) do
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48, _::binary>> = :crypto.hash(:sha, @namespace <> "#{type}:#{id}")
    Ecto.UUID.cast!(<<a::32, b::16, 5::4, c::12, 2::2, d::14, e::48>>)
  end

  @doc "Are friends switched on (the module's own setting)?"
  def friends_on?, do: Conn.enabled?()

  @doc "How `viewer` stands with `other`, or nil for oneself or for a visitor not signed in."
  def relationship(viewer, other) when is_binary(viewer) and is_binary(other) and viewer != other,
    do: Conn.get_relationship(viewer, other)

  def relationship(_viewer, _other), do: nil

  @doc "Ask `other` to be a friend. If they had already asked, both are accepted."
  def request(viewer, other), do: Conn.request_connection(viewer, other)

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
      nil -> {:error, :not_found}
      connection -> Conn.accept_connection(connection)
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
    do: Enum.find(Conn.list_pending_requests(viewer, preload: false), &(&1.requester_uuid == other))

  @doc "How many friends someone has."
  def friend_count(uuid), do: Conn.connections_count(uuid)

  @doc "How many requests wait for someone's answer."
  def pending_count(uuid), do: Conn.pending_requests_count(uuid)

  @doc "The friends of someone, newest first: the other person of each, as PhoenixKit's user."
  def friends(uuid) do
    for c <- Conn.list_connections(uuid), do: if(c.requester_uuid == uuid, do: c.recipient, else: c.requester)
  end

  @doc "Requests that wait for this person's answer: the people who asked."
  def requests_in(uuid), do: for(c <- Conn.list_pending_requests(uuid), do: c.requester)

  @doc "Requests this person has sent that are not answered yet: the people asked."
  def requests_out(uuid), do: for(c <- Conn.list_sent_requests(uuid), do: c.recipient)
end
