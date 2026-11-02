defmodule Roki.SeasonPosters do
  @moduledoc """
  A season's own poster, for the places that draw a show once per season.

  TMDB's poster for a show is its first season's, so a show with several seasons is drawn the same
  every time it comes up — a tier list of JoJo's seven parts is seven copies of one picture, and a
  show that is back with a new season is drawn as it was years ago. TMDB does keep a poster for each
  season; one read of a show gives all of them. They are kept here (`roki_tv_seasons`, a week), so a
  list of a hundred shows is one query and the reads happen once.

  `apply/3` puts them on a list of titles. A title that is a season of a show says which: `:season`
  (TMDB's number) or, for anime, `:mal_id` (MyAnimeList's entry, which laev maps to a TMDB season).
  Where it names none and the show has several seasons, the latest to have begun is taken.
  """

  alias Roki.Repo

  # A week: a running show gets a new season now and then, and a finished one never does.
  @stale_s 7 * 24 * 3600
  # How many shows a list will wait for the first time it is drawn; the rest are read behind it.
  @inline 12

  @doc "A show's seasons, `[%{n:, air_date:, poster:}]` (poster a TMDB path), read now if need be; `[]` if it cannot be."
  def seasons(tv_id, uuid) when is_integer(tv_id) do
    case read_many([tv_id]) do
      %{^tv_id => seasons} -> seasons
      _ -> fetch(tv_id, uuid)
    end
  end

  @doc """
  An anime's title page's poster: the one for `season` (the season Play offers, or the one on screen),
  at the page's size, or the title as it was. A show's own poster is its first season's.
  """
  def for_title(%{type: "tv", anime?: true, id: id} = title, season, uuid)
      when is_integer(season) do
    case Enum.find(seasons(id, uuid), &(&1.n == season)) do
      %{poster: path} when is_binary(path) ->
        %{title | poster: Roki.Titles.poster_url(path, "w500")}

      _ ->
        title
    end
  end

  def for_title(title, _season, _uuid), do: title

  @doc "The latest season of a show to have begun when it has several (what its poster shows), or nil."
  def latest_season(tv_id, uuid) when is_integer(tv_id) do
    case pick(seasons(tv_id, uuid), nil) do
      %{n: n} -> n
      _ -> nil
    end
  end

  @doc "The poster of one season of a show as kept, with no request: a URL, or nil."
  def stored_poster(tv_id, season) when is_integer(tv_id) and is_integer(season) do
    case read_many([tv_id]) do
      %{^tv_id => seasons} -> seasons |> Enum.find(&(&1.n == season)) |> path_to_url()
      _ -> nil
    end
  end

  def stored_poster(_tv_id, _season), do: nil

  @doc """
  `items` with the poster of the season each stands for, where there is one. `opts[:inline]` is how
  many shows not yet read are waited for (the rest are read in the background, for the next look).
  """
  def apply(items, uuid, opts \\ []) do
    wanted = Enum.filter(items, &wanted?/1)

    if wanted == [] do
      items
    else
      ids = wanted |> Enum.map(& &1.id) |> Enum.uniq()
      stored = read_many(ids)
      missing = ids -- Map.keys(stored)
      {now, later} = Enum.split(missing, Keyword.get(opts, :inline, @inline))
      seasons = Map.merge(stored, read_now(now, uuid))
      background(later, uuid)

      mapped = mal_seasons(wanted, uuid)

      Enum.map(items, fn item ->
        with true <- wanted?(item),
             [_ | _] = list <- seasons[item.id],
             %{poster: path} when is_binary(path) <- pick(list, season_of(item, mapped)) do
          Map.put(item, :poster, Roki.Titles.poster_url(path, "w342"))
        else
          _ -> item
        end
      end)
    end
  end

  # A show on a list that is told apart by season: it says which (`:season`), or it is anime — whose
  # entries are seasons, named by MyAnimeList's id.
  defp wanted?(%{type: "tv", id: id} = item) when is_integer(id) do
    (is_integer(item[:season]) and item[:season] > 0) or item[:anime] == true or
      is_integer(item[:mal_id])
  end

  defp wanted?(_), do: false

  defp season_of(%{season: s}, _mapped) when is_integer(s) and s > 0, do: s
  defp season_of(%{mal_id: mal}, mapped) when is_integer(mal), do: mapped[mal]
  defp season_of(_item, _mapped), do: nil

  # MyAnimeList's entry → the TMDB season it is (laev's cross-id list), for what names no season.
  defp mal_seasons(items, uuid) do
    mals =
      for %{mal_id: mal} = i <- items,
          is_integer(mal),
          not is_integer(i[:season]),
          uniq: true,
          do: mal

    if mals == [] do
      %{}
    else
      Roki.Laev.run(uuid, fn ->
        for mal <- mals,
            {"tv", _id, season} <- [Laev.AnimeMap.tmdb(mal)],
            into: %{},
            do: {mal, season || 1}
      end)
    end
  end

  # The season named, else the latest one begun when the show has several; nil when there is
  # nothing to say (one season: the show's own poster is that season's).
  defp pick(list, season) when is_integer(season), do: Enum.find(list, &(&1.n == season))

  defp pick(list, nil) do
    today = Date.utc_today()

    dated =
      list
      |> Enum.filter(
        &(&1.n > 0 and match?(%Date{}, &1.air_date) and Date.compare(&1.air_date, today) != :gt)
      )
      |> Enum.sort_by(& &1.air_date, Date)

    if length(dated) >= 2, do: List.last(dated)
  end

  defp path_to_url(%{poster: path}) when is_binary(path), do: Roki.Titles.poster_url(path, "w342")
  defp path_to_url(_), do: nil

  # ── keeping them ───────────────────────────────────────────────────

  defp read_many([]), do: %{}

  defp read_many(ids) do
    %{rows: fresh} =
      Repo.query!(
        "select tv_id from roki_tv_seasons_read where tv_id = any($1) and read_at > $2",
        [ids, NaiveDateTime.add(NaiveDateTime.utc_now(), -@stale_s)]
      )

    fresh = List.flatten(fresh)

    if fresh == [] do
      %{}
    else
      %{rows: rows} =
        Repo.query!(
          "select tv_id, season, air_date, poster_path from roki_tv_seasons where tv_id = any($1)",
          [fresh]
        )

      by_show =
        Enum.group_by(rows, &hd/1, fn [_, n, date, path] ->
          %{n: n, air_date: date, poster: path}
        end)

      Map.new(fresh, &{&1, Map.get(by_show, &1, [])})
    end
  end

  # Shows read now, a few at a time; each asks in its own scope (the tasks have none).
  defp read_now([], _uuid), do: %{}

  defp read_now(ids, uuid) do
    ids
    |> Task.async_stream(&{&1, fetch(&1, uuid)},
      max_concurrency: 6,
      timeout: 15_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{}, fn
      {:ok, {id, [_ | _] = seasons}}, acc -> Map.put(acc, id, seasons)
      _, acc -> acc
    end)
  end

  # What a list had no time for is read behind it, once each, so the next look is right.
  defp background([], _uuid), do: :ok

  defp background(ids, uuid) do
    ids = Enum.reject(ids, &Roki.TTLCache.cached?({:season_read, &1}))
    for id <- ids, do: Roki.TTLCache.put({:season_read, id}, 600, {:ok, true})

    if ids != [], do: Task.start(fn -> read_now(ids, uuid) end)
    :ok
  end

  defp fetch(tv_id, uuid) do
    Roki.Laev.public(uuid, fn ->
      case Laev.Tmdb.tv(tv_id) do
        {:ok, details} ->
          seasons = Roki.AnimeRank.parse_seasons(details)
          store(tv_id, seasons)
          seasons

        _ ->
          []
      end
    end)
  rescue
    _ -> []
  end

  defp store(tv_id, seasons) do
    Repo.transaction(fn ->
      Repo.query!("delete from roki_tv_seasons where tv_id = $1", [tv_id])

      for s <- seasons do
        Repo.query!(
          "insert into roki_tv_seasons (tv_id, season, air_date, poster_path) values ($1, $2, $3, $4) on conflict do nothing",
          [tv_id, s.n, s.air_date, s.poster]
        )
      end

      Repo.query!(
        "insert into roki_tv_seasons_read (tv_id, read_at) values ($1, $2) on conflict (tv_id) do update set read_at = excluded.read_at",
        [tv_id, NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)]
      )
    end)
  end
end
