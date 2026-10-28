defmodule Roki.CommentHandler do
  @moduledoc """
  What the site does when something is said in a comment thread (`phoenix_kit_comments` calls a
  handler named in `config :phoenix_kit, :comment_resource_handlers`): tell the people it
  concerns, and name and link the thread in the moderation list.

  Two kinds of thread, one handler module each (the module cannot be told which kind it is asked
  about when it resolves names): `Roki.CommentHandler.Profile` and `Roki.CommentHandler.Title`.
  Who is told:

    * a comment on a profile: the profile's owner;
    * a reply to a comment, on a profile or a title: the one who wrote that comment;
    * a name written as `@username` in a comment: that person (if they want comment notices);
    * a like on a comment: the one who wrote it (if they want comment notices).

  Never the person who did it, and no one twice for one comment. Dislikes are not announced.
  """

  alias Roki.{Repo, Social}

  @doc false
  def created(type, resource_uuid, comment) do
    commenter = comment.user_uuid
    parent_author = parent_author(comment)
    owner = if type == "profile", do: resource_uuid

    # Addressed to someone by where it was written: always arrives.
    addressed = Enum.uniq(Enum.reject([owner, parent_author], &(is_nil(&1) or &1 == commenter)))

    for target <- addressed do
      Social.notify_comment(
        target,
        commenter,
        type,
        resource_uuid,
        if(target == parent_author, do: :reply, else: :comment)
      )
    end

    # Someone named in it, who was not already told above: theirs to switch off.
    for target <- mentioned(comment.content),
        target != commenter,
        target not in addressed,
        Roki.Notify.wants?(target, "comments") do
      Social.notify_comment(target, commenter, type, resource_uuid, :mention)
    end

    :ok
  end

  @doc false
  def liked(type, resource_uuid, %{comment: comment, liker_uuid: liker}) do
    if comment.user_uuid != liker and Roki.Notify.wants?(comment.user_uuid, "comments"),
      do: Social.notify_comment(comment.user_uuid, liker, type, resource_uuid, :like)

    :ok
  end

  @doc "The people named as `@username` in some text: their uuids, each once."
  def mentioned(text) when is_binary(text) do
    ~r/(?<![\w@])@([A-Za-z0-9_.-]{2,40})/
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.flat_map(fn username ->
      case PhoenixKit.Users.Auth.get_user_by_username(String.trim_trailing(username, ".")) do
        %{uuid: uuid} -> [uuid]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  def mentioned(_), do: []

  defp parent_author(%{parent_uuid: nil}), do: nil

  defp parent_author(%{parent_uuid: parent}) do
    case PhoenixKitComments.get_comment(parent) do
      %{user_uuid: author} -> author
      _ -> nil
    end
  end

  @doc "`%{thread uuid => %{title, path}}` for the titles among these threads."
  def titles(uuids) do
    %{rows: rows} =
      Repo.query!("select uuid, type, id, name from roki_comment_titles where uuid = any($1)", [
        Enum.map(uuids, &Ecto.UUID.dump!/1)
      ])

    Map.new(rows, fn [uuid, type, id, name] ->
      {Ecto.UUID.load!(uuid), %{title: name || "#{type} #{id}", path: "/title/#{type}/#{id}"}}
    end)
  end
end

defmodule Roki.CommentHandler.Profile do
  @moduledoc "Comments on a profile (`resource_type` \"profile\", the thread is the owner's uuid)."
  @behaviour PhoenixKitComments.ResourceHandler

  @impl true
  def on_comment_created(type, uuid, comment),
    do: Roki.CommentHandler.created(type, uuid, comment)

  @impl true
  def on_comment_liked(type, uuid, reaction), do: Roki.CommentHandler.liked(type, uuid, reaction)

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
  def on_comment_created(type, uuid, comment),
    do: Roki.CommentHandler.created(type, uuid, comment)

  @impl true
  def on_comment_liked(type, uuid, reaction), do: Roki.CommentHandler.liked(type, uuid, reaction)

  @impl true
  def resolve_comment_resources(uuids), do: Roki.CommentHandler.titles(uuids)
end
