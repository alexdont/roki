defmodule Roki.Watch.Anime do
  @moduledoc """
  Anime is counted two ways: MyAnimeList lists every cour as its own entry ("Seihantai na Kimi
  to Boku", then "… 2nd Season"), TMDB keeps one show with seasons. laev's cross-id list ties
  each MAL entry to a TMDB show and season, and where TMDB itself has merged two cours into one
  season (25 episodes, not 12 + 13) both entries land on the same season — and laev's
  season → entry lookup keeps only one of them, so half of the episodes would be searched and
  marked under the wrong anime.

  This sorts them out: the entries that share a TMDB season are laid end to end, oldest first
  (MAL ids grow with time), each taking as many episodes as MAL says it has. Episode 13 of
  TMDB's season 1 is then episode 1 of the second entry. A season with one entry is exactly
  what laev's lookup gives.

  Everything here reads laev's files: call it inside `Roki.Laev.run/2` / `public/2`.
  """

  @doc "The MAL entries of a TMDB season, oldest first, each with its episode count (or nil)."
  def parts(tmdb_id, season) do
    for mal <- Laev.AnimeMap.mal_ids("tv", tmdb_id),
        {"tv", _id, s} <- [Laev.AnimeMap.tmdb(mal)],
        (s || 1) == season,
        do: {mal, Laev.Anime.episodes(mal)}
  end

  @doc """
  Where an episode of a TMDB season really is: `{mal_id, episode_of_that_entry}`, or nil when
  the season has no MAL entry at all.
  """
  def locate(tmdb_id, season, episode) when is_integer(season) and is_integer(episode) do
    case parts(tmdb_id, season) do
      [] -> nil
      [{mal, _count}] -> {mal, episode}
      parts -> place(parts, episode, 0)
    end
  end

  def locate(_tmdb_id, _season, _episode), do: nil

  # An entry whose length is unknown takes whatever is left; so does the last one.
  defp place([{mal, count} | rest], episode, offset) do
    if rest == [] or not is_integer(count) or episode <= offset + count,
      do: {mal, episode - offset},
      else: place(rest, episode, offset + count)
  end

  @doc "The reverse: an episode of a MAL entry, as TMDB's season numbers it."
  def to_tmdb(tmdb_id, season, mal, local) when is_integer(local) do
    offset =
      parts(tmdb_id, season)
      |> Enum.take_while(fn {m, _} -> m != mal end)
      |> Enum.reduce(0, fn {_m, count}, acc -> acc + (count || 0) end)

    offset + local
  end

  @doc "The entry a whole title is rated under: its first season's first entry."
  def first_entry(tmdb_id) do
    case parts(tmdb_id, 1) do
      [{mal, _} | _] -> mal
      [] -> List.first(Laev.AnimeMap.mal_ids("tv", tmdb_id))
    end
  end

  @doc "How many episodes of a season are marked watched, from laev's per-entry counts."
  def watched_in_season(tmdb_id, season, marks) do
    tmdb_id
    |> parts(season)
    |> Enum.reduce(0, fn {mal, _}, acc -> acc + Map.get(marks, mal, 0) end)
  end
end
