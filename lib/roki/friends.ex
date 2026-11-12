defmodule Roki.Friends do
  @moduledoc """
  What a person's friends on the site made of a title: who has seen it, and what they rated
  it — against what each of them usually gives, so a score reads as "loved it" or "less than
  their usual" rather than a bare number (the way the Reviews sheet puts a service's score
  against what is typical there).

  Read from the site's own copies (`roki_watched`, `roki_ratings`), never from a friend's laev
  scope, so a page of a hundred posters costs one query. `seen/1` is what the grids draw (a
  count per title, kept five minutes); `on_title/3` is the detail for one title (the hover
  card, the title page). An anime a friend watched under its MyAnimeList entry counts for the
  TMDB title it maps to.
  """

  alias Roki.{Repo, TTLCache}

  @ttl 300
  @seen_statuses ["finished", "up_to_date"]

  @doc "How many of this person's friends have seen each title: `%{{type, id} => n}`. Empty for a visitor."
  def seen(uuid) when is_binary(uuid) do
    TTLCache.fetch({:friends_seen, uuid}, @ttl, fn -> {:ok, read_seen(uuid)} end)
    |> case do
      {:ok, map} -> map
      _ -> %{}
    end
  end

  def seen(_), do: %{}

  @doc "Forget what was read for this person (their friends changed)."
  def forget(uuid), do: TTLCache.delete({:friends_seen, uuid})

  defp read_seen(uuid) do
    case friend_ids(uuid) do
      [] ->
        %{}

      ids ->
        %{rows: rows} =
          Repo.query!(
            """
            select coalesce(w.tmdb_type, w.type), coalesce(w.tmdb_id, w.id), count(distinct w.user_uuid)
            from roki_watched w
            where w.user_uuid = any($1) and coalesce(w.status, 'finished') = any($2)
            group by 1, 2
            """,
            [ids, @seen_statuses]
          )

        Map.new(rows, fn [type, id, n] -> {{type, id}, n} end)
    end
  end

  @doc """
  The friends who have seen or rated a title: `[%{username, seen?, score, average, verdict}]`,
  the ones with a score first, highest first. `verdict` puts the score against the friend's own
  average (`verdict/2`).
  """
  def on_title(uuid, type, id)
      when is_binary(uuid) and type in ["movie", "tv"] and is_integer(id) do
    friends = friends(uuid)
    ids = Enum.map(friends, &dump(&1.uuid))

    if ids == [] do
      []
    else
      %{rows: seen} =
        Repo.query!(
          """
          select distinct w.user_uuid from roki_watched w
          where w.user_uuid = any($1) and coalesce(w.status, 'finished') = any($4)
            and ((w.type = $2 and w.id = $3) or (w.tmdb_type = $2 and w.tmdb_id = $3))
          """,
          [ids, type, id, @seen_statuses]
        )

      %{rows: scores} =
        Repo.query!(
          """
          select r.user_uuid, max(r.score) from roki_ratings r
          where r.user_uuid = any($1) and r.score > 0
            and ((r.type = $2 and r.id = $3)
                 or (r.type = 'mal' and exists (
                   select 1 from roki_watched w
                   where w.user_uuid = r.user_uuid and w.type = 'mal' and w.id = r.id
                     and w.tmdb_type = $2 and w.tmdb_id = $3)))
          group by 1
          """,
          [ids, type, id]
        )

      seen = MapSet.new(seen, &hd/1)
      scores = Map.new(scores, fn [u, s] -> {u, s * 1.0} end)
      averages = averages(ids)

      friends
      |> Enum.map(fn f ->
        bin = dump(f.uuid)
        score = scores[bin]
        average = averages[bin]

        %{
          username: f.username,
          seen?: MapSet.member?(seen, bin) or score != nil,
          score: score,
          average: average,
          verdict: verdict(score, average)
        }
      end)
      |> Enum.filter(& &1.seen?)
      |> Enum.sort_by(&{&1.score == nil, -(&1.score || 0), &1.username})
    end
  end

  def on_title(_, _, _), do: []

  # Each friend's average rating (films, shows and anime together), by uuid binary.
  defp averages(ids) do
    %{rows: rows} =
      Repo.query!(
        "select user_uuid, avg(score) from roki_ratings where user_uuid = any($1) and score > 0 group by 1",
        [ids]
      )

    Map.new(rows, fn [u, avg] -> {u, to_float(avg)} end)
  end

  @doc """
  A score against the person's own average: `:great` (1.5 or more above), `:good` (0.5–1.5
  above), `:typical`, `:below` (0.5–1.5 under), `:poor` (1.5 or more under); `nil` without both.
  """
  def verdict(score, average) when is_number(score) and is_number(average) do
    delta = score - average

    cond do
      delta >= 1.5 -> :great
      delta >= 0.5 -> :good
      delta > -0.5 -> :typical
      delta > -1.5 -> :below
      true -> :poor
    end
  end

  def verdict(_, _), do: nil

  @doc "The verdict as words: what the score says about how much they liked it."
  def words(:great), do: "loved it"
  def words(:good), do: "more than their usual"
  def words(:typical), do: "about their usual"
  def words(:below), do: "less than their usual"
  def words(:poor), do: "did not like it"
  def words(_), do: nil

  @doc "One friend's line for a hover card: `alex ★ 8.5 · loved it`, or `alex · seen`."
  def describe(%{username: name, score: score, verdict: verdict}) when is_number(score) do
    base = "#{name} ★ #{format(score)}"
    if w = words(verdict), do: base <> " · " <> w, else: base
  end

  def describe(%{username: name}), do: "#{name} · seen"

  @doc "A short count for a poster's chip: nil for none."
  def chip(nil), do: nil
  def chip(0), do: nil
  def chip(n) when n > 9, do: "9+"
  def chip(n), do: Integer.to_string(n)

  defp friends(uuid) do
    if Roki.Social.friends_on?(), do: Roki.Social.friends(uuid), else: []
  rescue
    _ -> []
  end

  defp friend_ids(uuid), do: uuid |> friends() |> Enum.map(&dump(&1.uuid))

  defp dump(uuid) do
    {:ok, bin} = Ecto.UUID.dump(uuid)
    bin
  end

  defp format(score) do
    if score == Float.round(score),
      do: Integer.to_string(trunc(score)),
      else: Float.to_string(score)
  end

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_number(n), do: n * 1.0
  defp to_float(_), do: nil
end
