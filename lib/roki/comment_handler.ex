defmodule Roki.CommentHandler do
  @moduledoc """
  What the site does when something is said in a comment thread (`phoenix_kit_comments` calls a
  handler named in `config :phoenix_kit, :comment_resource_handlers`): tell the people it
  concerns, and name and link the thread in the moderation list.

  Two kinds of thread, one handler module each (the module cannot be told which kind it is asked
  about when it resolves names): `Roki.CommentHandler.Profile` and `Roki.CommentHandler.Title`.
  Who is told:

    * a comment on a profile: the profile's owner;
    * a reply to a comment, on a profile or a title: the one who wrote that comment.

  Never the person who wrote it, and no one twice for one comment.
  """

  alias Roki.{Repo, Social}

  @doc false
  def created(type, resource_uuid, comment) do
    commenter = comment.user_uuid
    parent_author = parent_author(comment)

    owner = if type == "profile", do: resource_uuid

    for target <- Enum.uniq(Enum.reject([owner, parent_author], &(is_nil(&1) or &1 == commenter))) do
      reply? = target == parent_author
      Social.notify_comment(target, commenter, type, resource_uuid, reply?)
    end

    :ok
  end

  defp parent_author(%{parent_uuid: nil}), do: nil

  defp parent_author(%{parent_uuid: parent}) do
    case PhoenixKitComments.get_comment(parent) do
      %{user_uuid: author} -> author
      _ -> nil
    end
  end

  @doc "`%{thread uuid => %{title, path}}` for the titles among these threads."
  def titles(uuids) do
    %{rows: rows} = Repo.query!("select uuid, type, id, name from roki_comment_titles where uuid = any($1)", [Enum.map(uuids, &Ecto.UUID.dump!/1)])

    Map.new(rows, fn [uuid, type, id, name] ->
      {Ecto.UUID.load!(uuid), %{title: name || "#{type} #{id}", path: "/title/#{type}/#{id}"}}
    end)
  end
end

defmodule Roki.CommentHandler.Profile do
  @moduledoc "Comments on a profile (`resource_type` \"profile\", the thread is the owner's uuid)."
  @behaviour PhoenixKitComments.ResourceHandler

  @impl true
  def on_comment_created(type, uuid, comment), do: Roki.CommentHandler.created(type, uuid, comment)

  @impl true
  def resolve_comment_resources(uuids) do
    for uuid <- uuids, user = PhoenixKit.Users.Auth.get_user(uuid), user != nil, into: %{} do
      {uuid, %{title: "#{user.username}'s profile", path: "/#{user.username}"}}
    end
  end
end

defmodule Roki.CommentHandler.Title do
  @moduledoc "Comments on a film or show (`resource_type` \"title\", the thread is `Roki.Social.title_uuid/2`)."
  @behaviour PhoenixKitComments.ResourceHandler

  @impl true
  def on_comment_created(type, uuid, comment), do: Roki.CommentHandler.created(type, uuid, comment)

  @impl true
  def resolve_comment_resources(uuids), do: Roki.CommentHandler.titles(uuids)
end
