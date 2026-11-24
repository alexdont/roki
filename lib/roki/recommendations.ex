defmodule Roki.Recommendations do
  @moduledoc """
  People vouching for a film or a show (ALEX-150): the title page's Recommend button, and the
  home page's "Recommended by Roki users" row, which every signed-in person sees — a
  recommendation is meant for the others on the site (a family, say), so it is not limited to
  friends. One row per person and title in `roki_recommendations`, the title's name, year and
  poster kept with it so the row draws without asking TMDB.
  """

  alias Roki.Repo

  @doc "Whether this person recommends the title."
  def recommended?(uuid, type, id) when is_binary(uuid) and is_integer(id) do
    %{rows: rows} =
      Repo.query!(
        "select 1 from roki_recommendations where user_uuid = $1 and type = $2 and id = $3",
        [dump(uuid), type, id]
      )

    rows != []
  end

  def recommended?(_uuid, _type, _id), do: false

  @doc "Recommend a title, or take the recommendation back: `:added | :removed`."
  def toggle(uuid, %{type: type, id: id} = title)
      when type in ["movie", "tv"] and is_integer(id) do
    if recommended?(uuid, type, id) do
      Repo.query!(
        "delete from roki_recommendations where user_uuid = $1 and type = $2 and id = $3",
        [dump(uuid), type, id]
      )

      :removed
    else
      Repo.query!(
        """
        insert into roki_recommendations (user_uuid, type, id, title, year, poster) values ($1, $2, $3, $4, $5, $6)
        on conflict (user_uuid, type, id) do nothing
        """,
        [dump(uuid), type, id, title[:title], to_year(title[:year]), poster(title)]
      )

      :added
    end
  end

  @doc """
  The home page's row: titles recommended by anyone, the most recently vouched for first, each
  once with everyone who recommends it (`by`, usernames, the latest first) — `limit` titles.
  """
  def row(limit \\ 20) do
    %{rows: rows} =
      Repo.query!(
        """
        select r.type, r.id, max(r.title), max(r.year), max(r.poster), max(r.recommended_at) as last,
               array_agg(u.username order by r.recommended_at desc),
               (array_agg(u.custom_fields order by r.recommended_at desc))[1]
        from roki_recommendations r
        join phoenix_kit_users u on u.uuid = r.user_uuid
        group by r.type, r.id
        order by last desc
        limit $1
        """,
        [limit]
      )

    for [type, id, title, year, poster, _last, by, fields] <- rows do
      %{
        type: type,
        id: id,
        title: title || "Untitled",
        year: year,
        poster: poster,
        by: by,
        # Who vouched, shown only on the opened card: the latest one's picture (or initial).
        rec_name: List.first(by),
        rec_more: length(by) - 1,
        rec_avatar: avatar(fields)
      }
    end
  end

  @doc "The usernames that recommend a title, the latest first."
  def by(type, id) when is_integer(id) do
    %{rows: rows} =
      Repo.query!(
        """
        select u.username from roki_recommendations r join phoenix_kit_users u on u.uuid = r.user_uuid
        where r.type = $1 and r.id = $2 order by r.recommended_at desc
        """,
        [type, id]
      )

    List.flatten(rows)
  end

  # The avatar as PhoenixKit's `user_avatar` finds it — an upload, else the sign-in provider's
  # picture — or nil (the card shows the name's initial). Not Gravatar: that would put a hash of
  # the person's email on the page.
  @doc false
  def avatar(%{"avatar_file_uuid" => uuid}) when is_binary(uuid) and uuid != "",
    do: PhoenixKit.Modules.Storage.URLSigner.signed_url(uuid, "thumbnail")

  def avatar(%{"oauth_avatar_url" => "http" <> _ = url}), do: url
  def avatar(_), do: nil

  # Who vouched, in words — "👍 alex", "👍 alex +2" (no longer on the posters; kept for tests/tools).
  @doc false
  def badge([one]), do: "👍 #{one}"
  def badge([first | rest]), do: "👍 #{first} +#{length(rest)}"
  def badge(_), do: nil

  # The poster as the rows draw it: a full address (the site's copies are made from it).
  defp poster(%{poster: "http" <> _ = url}), do: url
  defp poster(%{poster_path: "/" <> _ = path}), do: "https://image.tmdb.org/t/p/w342" <> path
  defp poster(_), do: nil

  defp to_year(nil), do: nil
  defp to_year(y) when is_integer(y), do: Integer.to_string(y)
  defp to_year(y) when is_binary(y), do: String.slice(y, 0, 4)

  defp dump(uuid) do
    {:ok, bin} = Ecto.UUID.dump(uuid)
    bin
  end
end
