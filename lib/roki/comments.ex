defmodule Roki.Comments do
  @moduledoc """
  What has been said on this site outside the reader: under a film or a show, and on someone's
  profile. The comments page lists these beside the reader's own notes on a page of a chapter,
  which live in the reader's tables and come from `Roki.Manga.Library`.

  All of it is one table (`phoenix_kit_comments`); what tells the three apart is the thread a
  comment hangs on — a title's thread is a hash of its kind and id (`Roki.Social.title_uuid/2`),
  a profile's thread is the owner's own uuid, and the reader's rows point back at a chapter.
  """
  alias Roki.{CommentHandler, Repo}

  @doc """
  The newest comments on titles and profiles, oldest-first cursor `before` for the next page.

  Each one carries where it was said and how to get there, so the page can draw it without
  knowing any of this.
  """
  def recent(limit, before \\ nil) when is_integer(limit) do
    %{rows: rows} =
      Repo.query!(
        """
        select c.resource_type, c.resource_uuid, c.content, c.like_count, c.inserted_at,
               u.username, c.metadata
          from phoenix_kit_comments c
          join phoenix_kit_users u on u.uuid = c.user_uuid
         where c.status = 'published'
           and c.resource_type in ('title', 'profile')
           and ($2::timestamp is null or c.inserted_at < $2)
         order by c.inserted_at desc
         limit $1
        """,
        [limit, before]
      )

    {titles, profiles} =
      Enum.split_with(rows, fn [type | _] -> type == "title" end)

    places =
      Map.merge(
        CommentHandler.titles(Enum.map(titles, &Ecto.UUID.load!(Enum.at(&1, 1)))),
        CommentHandler.Profile.resolve_comment_resources(
          Enum.map(profiles, &Ecto.UUID.load!(Enum.at(&1, 1)))
        )
      )

    for [type, uuid, content, likes, at, username, metadata] <- rows do
      place = places[Ecto.UUID.load!(uuid)] || %{title: "Somewhere", path: "/"}

      %{
        kind: :site,
        where: type,
        title: place.title,
        path: place.path,
        content: content || "",
        gif_url: get_in(metadata || %{}, ["giphy", "url"]),
        username: username,
        like_count: likes || 0,
        reply_count: 0,
        inserted_at: to_naive(at)
      }
    end
  end

  defp to_naive(%DateTime{} = at), do: DateTime.to_naive(at)
  defp to_naive(%NaiveDateTime{} = at), do: at
end
