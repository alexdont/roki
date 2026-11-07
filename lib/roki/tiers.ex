defmodule Roki.Tiers do
  @moduledoc """
  The tierlist for the things this site knows about — films, shows and anime — beside the
  reader's own, which keeps its tables and its MyAnimeList sync (`Roki.Manga.Library`).

  A tier is a rating said another way, so the two are kept in step both ways:

    * a title that has a rating and no tier yet is **placed** in the tier its rating maps to,
      so a board is not empty on the first visit;
    * a title dropped into a tier is **rated** at that tier's score, through the same path the
      rest of the site rates with, so it reaches TMDB or MyAnimeList like any other rating.

  The mapping is the reader's, which is what it pushes to MyAnimeList: S is 10, A is 9, B is 8,
  C is 7, D is 6, E is 5.
  """
  alias Roki.{Profile, Repo}
  alias Roki.Manga.Trackers.MAL

  @doc "The score a tier stands for, or nil for the tiers that are not a rating."
  def score(tier), do: MAL.tier_score(tier)

  @doc """
  The tier a score belongs in. A half score is rounded *down*: 8.5 is a B, with the 8s, not an A —
  if it were good enough for the 9s it would have been given a 9. (`board/1` still puts it above
  the plain 8s inside the tier.)
  """
  def tier(nil), do: nil
  def tier(score) when score >= 10, do: "s"
  def tier(score) when score >= 9, do: "a"
  def tier(score) when score >= 8, do: "b"
  def tier(score) when score >= 7, do: "c"
  def tier(score) when score >= 6, do: "d"
  def tier(score) when score > 0, do: "e"
  def tier(_), do: nil

  @doc "Where this account has put each title: `%{{type, id} => tier}`."
  def list(uuid) when is_binary(uuid) do
    {:ok, bin} = Ecto.UUID.dump(uuid)

    %{rows: rows} =
      Repo.query!("select type, id, tier from roki_tiers where user_uuid = $1", [bin])

    Map.new(rows, fn [type, id, tier] -> {{type, id}, tier} end)
  end

  @doc """
  Replace this account's tiers with what the board was left holding, and rate what moved.

  `tiers` is `%{tier => [{type, id}]}` in the board's own order. Rating is done in the
  background and its failure is not the board's: the tier is saved either way, and an account
  with no TMDB or MyAnimeList connection still has a tierlist.
  """
  def replace(uuid, tiers, titles \\ %{}) when is_map(tiers) do
    before = list(uuid)
    {:ok, bin} = Ecto.UUID.dump(uuid)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      for {tier, keys} <- tiers,
          {{type, id}, position} <- Enum.with_index(keys),
          do: [bin, type, id, to_string(tier), position, titles[{type, id}], now, now]

    Repo.transaction(fn ->
      Repo.query!("delete from roki_tiers where user_uuid = $1", [bin])

      for row <- rows do
        Repo.query!(
          "insert into roki_tiers (user_uuid, type, id, tier, position, title, inserted_at, updated_at) " <>
            "values ($1, $2, $3, $4, $5, $6, $7, $8)",
          row
        )
      end
    end)

    rate_what_moved(uuid, before, tiers, titles)
    :ok
  end

  # Only a title whose tier now means a different score is rated: dragging within a tier, or
  # into one that is not a rating ("Don't know", "Want to watch"), says nothing about a score.
  defp rate_what_moved(uuid, before, tiers, titles) do
    moved =
      for {tier, keys} <- tiers,
          key <- keys,
          score = score(to_string(tier)),
          score != score(before[key]),
          do: {key, score}

    if moved != [] do
      Task.Supervisor.start_child(Roki.TaskSupervisor, fn ->
        for {{type, id}, score} <- moved do
          title = rating_title(uuid, type, id, titles[{type, id}])

          try do
            # A season is rated on its own MyAnimeList entry, not on the show.
            Roki.Watch.rate(uuid, title, score * 1.0, if(type == "mal", do: id))
          rescue
            e ->
              require Logger
              Logger.warning("tier rating failed: #{inspect(e)}")
          end
        end
      end)
    end
  end

  # What `Roki.Watch.rate/4` is told it is rating: a film or show by its TMDB id; a season by the
  # show it belongs to (laev's cross-id list) and — passed beside it — its MyAnimeList entry.
  defp rating_title(uuid, "mal", mal, name) do
    tmdb =
      Roki.Laev.run(uuid, fn ->
        case Laev.AnimeMap.tmdb(mal) do
          {"tv", id, _season} -> id
          _ -> nil
        end
      end)

    %{type: "tv", id: tmdb, anime?: true, title: name}
  end

  defp rating_title(_uuid, type, id, name), do: %{type: type, id: id, title: name}

  @doc """
  Everything this account has finished, as the board draws it: each entry its own tier when it
  has one, else the tier its rating maps to, else the pool. Returns `{buckets, placed}` —
  `placed` being the entries put somewhere by their rating alone, which the board saves as soon
  as anything is dragged.
  """
  def board(uuid) when is_binary(uuid) do
    saved = list(uuid)
    ratings = Profile.ratings(uuid)

    items =
      for i <- Profile.history(uuid) do
        key = tier_key(i)

        # What the show itself was filed under: a rating on TMDB covers every season that has none of
        # its own, and a place saved before a season had a key of its own is still its place.
        legacy = Profile.favorite_key(i)
        from_rating = tier(ratings[key] || ratings[legacy])
        saved_tier = saved[key] || saved[legacy]

        Map.merge(i, %{
          key: key,
          key_string: "#{elem(key, 0)}:#{elem(key, 1)}",
          tier: saved_tier || from_rating || "pool",
          rating: ratings[key] || ratings[legacy],
          placed?: saved_tier == nil and from_rating != nil,
          mode: mode_of(i)
        })
      end

    # Inside a tier the better-rated come first, so an 8.5 sits above the 8s (the sort is stable:
    # the unrated, and those with the same score, keep their order).
    buckets =
      items
      |> Enum.group_by(& &1.tier)
      |> Map.new(fn {tier, list} -> {tier, Enum.sort_by(list, &(-(&1.rating || 0)))} end)

    {buckets, Enum.filter(items, & &1.placed?)}
  end

  # A season of an anime is its MyAnimeList entry: it is rated there, one score to a season, and
  # that — not the show's TMDB id, which every season shares — is what it is on the board. Two
  # seasons filed under one key were one entry, and a rating on either was nobody's.
  def tier_key(%{mal_id: mal}) when is_integer(mal), do: {"mal", mal}
  def tier_key(item), do: Profile.favorite_key(item)

  defp mode_of(%{anime: true}), do: "anime"
  defp mode_of(%{type: type}), do: type

  @doc "The titles on the board, by key, so a saved row can carry a name."
  def titles(items), do: Map.new(items, fn i -> {i.key, i.title} end)
end
