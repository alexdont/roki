defmodule Roki.Manga.CommentNotifier do
  @moduledoc """
  PhoenixKitComments resource-handler that fires bell notifications
  when one of the user's comments is replied to or liked.

  Registered in `config/config.exs` under
  `:phoenix_kit, :comment_resource_handlers` for both resource types
  this app uses for comments — `"manga_annotation"` (legacy reader)
  and `"manga_mark"` (fresco / etcher reader). Routing every comment
  surface through the same handler means the bell behaves identically
  no matter where the like or reply happened.

  ## Callbacks

    * `on_comment_created/3` — built-in phoenix_kit_comments callback.
      Fires for every newly-created comment. We only act when the new
      comment has a `parent_uuid` (a reply), and notify the parent's
      author.

    * `on_comment_liked/3` — **local patch** to phoenix_kit_comments
      (see `deps/phoenix_kit_comments/lib/phoenix_kit_comments.ex`,
      `like_comment/2`). Fires when a user likes a comment. Payload
      is `%{comment: %Comment{}, liker_uuid: binary}`.

  Self-actions (liking or replying to one's own comment) are skipped
  inside `Library.notify_comment_action/3`, so the callbacks here can
  stay branch-free.
  """

  alias Roki.Manga.Library

  # Top-level annotation / mark comment. Fan out to every saved-manga
  # user who has read PAST this chapter — they get an aggregated
  # "N new comments on earlier chapters of TITLE" bell entry.
  def on_comment_created(_resource_type, _resource_uuid, %{parent_uuid: nil} = comment) do
    Library.notify_past_chapter_comment(comment)
  end

  # Reply to an existing comment. Notify the parent's author.
  def on_comment_created(_resource_type, _resource_uuid, %{parent_uuid: parent_uuid} = reply)
      when is_binary(parent_uuid) do
    case PhoenixKitComments.get_comment(parent_uuid) do
      nil -> :ok
      parent -> Library.notify_comment_action(parent, reply.user_uuid, :replied)
    end
  end

  def on_comment_created(_resource_type, _resource_uuid, _comment), do: :ok

  def on_comment_liked(_resource_type, _resource_uuid, %{comment: comment, liker_uuid: liker_uuid}) do
    Library.notify_comment_action(comment, liker_uuid, :liked)
  end
end
