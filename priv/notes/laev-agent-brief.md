# Brief for the laev package agent: bring roki's fixes into `laev`

You are working on the **`laev` Elixir package** (Hex, current 0.1.41). Another app, **roki** (a Phoenix site that
uses laev as a library for many users), hit real problems and patched them *in the app* because the package could
not be changed at the time. The goal now: move those fixes into laev so **terminal-app (CLI) users get the same
behaviour**, then publish a new version. Roki will then delete its workarounds.

Everything you need is below, including the working code from roki (module names there are `Roki.*`; adapt to
laev's own modules, don't paste blindly). You do not have access to roki's repo. Keep laev's public behaviour for
existing callers; add options rather than changing defaults where a caller could depend on the old behaviour,
except where this brief says a default is a bug.

Do the work in this order. After each numbered item: tests, then a short note of what changed. Publish once at the
end (bump version, CHANGELOG, `mix hex.publish`). Items 1 and 3 matter most.

---

## 1. Picking the right episode file (BUGS)

Seen on *You and I Are Polar Opposites* (TMDB merges two MAL cours into one 25-episode season; releases are named
per cour, and one pack is named "(13-25)" and numbers its files 13..25):

* `Laev.FilePick.choose/3` falls back to the **largest file** in a pack when no file names the episode. Asked for
  local episode 2 of the "(13-25)" pack it returned `- 13v2` and called it playable. Return a "no match" result
  unless the caller passes an explicit `fallback: :largest`.
* `Laev.FilePick.names_episode?/3` reads `13v2` (a re-release of episode 13) as episode 2. Strip `(\d)v\d` to `\1`
  before matching.
* A pack named with a range whose start is not 1 (`(13-25)`) numbers files across the whole TMDB season, so it must
  be asked for the **TMDB** episode number, not the cour-local one. Releases are grouped by the number they use and
  probed per group.
* A pick whose file names a different episode or cour must be rejected (e.g. file `S02E01` when S1E2 was asked; a
  bare fansub `- 13v2` for episode 2), and a pack with no file for the episode must be rejected, not "largest".
* Source probing: roki probes 4 at a time (laev's default is 2) and stops early once 5 releases play (or 1 plays and
  3 s have passed); the rest go back to a "load more" list. Consider the same for the CLI's source check.

Roki's working code (resolver.ex), the part to port — `probe_page` grouping, `numbered_as`, `confirm_episode`,
`wrong_numbering?`, `pack?`, `names_episode?`:

### `lib/roki/watch/resolver.ex` — grouping + early cutoff

```elixir
  # One round of probing, 8 releases two at a time. Each answer is counted on the page as it
  # arrives; the task keeps the ones that play.
  defp probe_page(parent, token, uuid, ctx, page) do
    {:ok, agent} = Agent.start_link(fn -> %{done: 0, ok: [], seen: []} end)
    total = length(page)
    send(parent, {:probe, token, 0, 0, total})
    send(parent, {:candidates, token, Enum.map(page, &Roki.Watch.Checks.summary/1)})

    notify = fn {:result, idx, source, result} ->
      result = confirm_episode(result, source, ctx)

      {done, ok} =
        Agent.get_and_update(agent, fn st ->
          ok =
            if match?({:ok, _}, result), do: [{idx, source, elem(result, 1)} | st.ok], else: st.ok

          st = %{st | done: st.done + 1, ok: ok, seen: [source.hash | st.seen]}
          {{st.done, length(st.ok)}, st}
        end)

      send(parent, {:probe, token, done, ok, total})

      state =
        case result do
          {:ok, _} -> :ok
          other -> {:bad, Roki.Watch.Checks.why(other)}
        end

      send(parent, {:checked, token, source.hash, state})
    end

    # Four at a time (laev's default is two): the releases are checked in half the waves.
    opts =
      [notify: notify, episode: ctx.episode, concurrency: 4] ++
        if(ctx.anime, do: [], else: [season: ctx.season])

    # Releases are not all numbered alike: most name the episode of the season asked for, a season
    # pack of an anime cour that TMDB merged names them 13…25. Each release is asked for the
    # number it uses, so the right file is picked inside a pack.
    groups =
      page |> Enum.with_index() |> Enum.group_by(fn {source, _i} -> numbered_as(source, ctx) end)

    task =
      Task.async(fn ->
        Roki.Laev.run(uuid, fn ->
          for {episode, items} <- groups do
            Laev.Providers.probe_sources(items, Keyword.put(opts, :episode, episode))
          end
        end)
      end)

    late = await_probes(task, agent, page, parent, token, nil)

    ok = Agent.get(agent, & &1.ok)
    Agent.stop(agent)

    {ok
     |> Enum.sort_by(&elem(&1, 0))
     |> Enum.map(fn {_i, source, stream} -> {source, stream} end), late}
  end

  defp await_probes(task, agent, page, parent, token, first_ok_at) do
    case Task.yield(task, 150) do
      {:ok, _} ->
        []

      {:exit, _} ->
        []

      nil ->
        st = Agent.get(agent, & &1)
        ok = length(st.ok)
        now = System.monotonic_time(:millisecond)
        first = first_ok_at || if(ok > 0, do: now)

        if ok >= @enough or (first && now - first >= @grace_ms) do
          Task.shutdown(task, :brutal_kill)
          seen = MapSet.new(st.seen)
          late = Enum.reject(page, &MapSet.member?(seen, &1.hash))
          for s <- late, do: send(parent, {:checked, token, s.hash, {:bad, "slow, set aside"}})
          late
        else
          await_probes(task, agent, page, parent, token, first)
        end
    end
  end

  # The episode number a release is numbered with. A pack named with a range that does not start at
  # 1 — "(13-25)" — numbers its files across the whole TMDB season, so it is asked for the TMDB
  # number (15), not the number inside its own cour (3). Everything else: the episode as
  # `Watch.ctx` set it.
  defp numbered_as(source, ctx) do
    tmdb = ctx[:tmdb_episode]

    with true <- is_integer(tmdb),
         [_, a, b] <- Regex.run(~r/(\d{1,4})\s*[-~–]\s*(\d{1,4})/, source.name),
         {a, b} = {String.to_integer(a), String.to_integer(b)},
         true <- a > 1 and a <= b and tmdb in a..b do
      tmdb
    else
      _ -> ctx.episode
    end
  end

  # laev picks the *largest* file in a pack when none names the episode, and calls the pack
  # playable: a "(13-25)" pack asked for episode 2 hands over "… - 13v2". A pack only counts if the
  # file it picked says it is this episode.
  defp confirm_episode({:ok, stream} = ok, source, ctx) do
    name = stream[:filename]

    cond do
      not is_binary(name) ->
        ok

      wrong_numbering?(name, ctx) ->
        {:error, "that release is another episode"}

      pack?(source.name) and not names_episode?(name, source, ctx) ->
        {:error, "that pack has no file for this episode"}

      true ->
        ok
    end
  end

  defp confirm_episode(other, _source, _ctx), do: other

  # A file that says "S02E01" is that episode whatever was asked for: a single-file release of
  # another episode (or another cour — the first one has season 1, the later ones season 2…) plays
  # fine and is not what was clicked.
  defp wrong_numbering?(file, ctx) do
    case Regex.run(~r/S(\d{1,2})\s*E(\d{1,4})/i, Path.basename(file)) do
      [_, s, e] ->
        s = String.to_integer(s)
        e = String.to_integer(e)
        wanted = [ctx.episode, ctx[:tmdb_episode]]

        season_ok =
          cond do
            not ctx.anime -> s == ctx.season
            ctx[:tmdb_episode] == ctx.episode -> s == 1
            true -> s != 1
          end

        e not in wanted or not season_ok

      _ ->
        # fansub style: "Show - 13v2 (1080p)"
        case ctx.anime && Regex.run(~r/ - (\d{1,4})(?:v\d)?(?=[\s.\[(]|$)/, Path.basename(file)) do
          [_, e] -> String.to_integer(e) not in [ctx.episode, ctx[:tmdb_episode]]
          _ -> false
        end
    end
  end

  defp pack?(name),
    do: Regex.match?(~r/\bbatch|complete|\d+\s*[-~–]\s*\d+|\bS\d+\b(?!E)/i, name)

  defp names_episode?(file, source, ctx) do
    episode = numbered_as(source, ctx)
    season = if ctx.anime, do: nil, else: ctx.season
    # "- 13v2" is a re-release of episode 13: its "v2" is not an episode number.
    file = Regex.replace(~r/(\d)v\d/i, file, "\\1")
    Laev.FilePick.names_episode?(file, season, episode)
  end
```

Acceptance tests to add (all must pass):
* pack "(13-25)", asked TMDB ep 15 → picks the file named 15 (e.g. `- 15v2` counts as 15), not the largest.
* same pack asked local ep 2 where no file is 2 → "no file for this episode" (not 13).
* single release `S02E01` asked for S1E2 → rejected; asked for S2E1 → accepted.
* `Show - 13v2 (1080p)` asked for episode 2 → rejected; asked for 13 → accepted.

---

## 2. Anime numbering: TMDB season ↔ MyAnimeList entries

laev has `Laev.AnimeMap` (MAL id ↔ TMDB id + season) but nothing that maps *an episode of a TMDB season* to
*(MAL entry, episode inside that entry)* when TMDB merged cours. Roki's `Roki.Watch.Anime` does (whole file below).
Add it to laev (e.g. `Laev.Anime.Parts`, with `parts/3`, `locate/3`, `first_entry/1`).

The CLI also has a private `mal_page/3` ("open the MAL entry you watched most"). Make it public
(`Laev.Anime.page_url(type, tmdb_id, title)` or similar): roki re-implemented it for an "Open on MyAnimeList" link
that follows the season being watched, and for **rating per season** (MAL rates by entry, TMDB by show — roki's
`rating_target(title, entry)`).

### `lib/roki/watch/anime.ex` — whole file

```elixir
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

  @doc """
  The MAL entries of a TMDB season, oldest first, each with its episode count (or nil).

  laev's list also files specials, recaps and OVAs under the season they belong to, with no
  episode count and no episodes on TMDB's side. They are not parts of the season, so: an entry
  whose length is unknown is skipped unless it is the last one, and once `total` (the season's
  episodes on TMDB) is used up nothing more is a part. "That Time I Got Reincarnated as a
  Slime" season 1 is one entry of 24 plus two such extras.
  """
  def parts(tmdb_id, season, total \\ nil) do
    all =
      for mal <- Laev.AnimeMap.mal_ids("tv", tmdb_id),
          {"tv", _id, s} <- [Laev.AnimeMap.tmdb(mal)],
          (s || 1) == season,
          do: {mal, Laev.Anime.episodes(mal)}

    trim(all, total, 0, [])
  end

  defp trim([], _total, _offset, acc), do: Enum.reverse(acc)

  defp trim([{_mal, count} = part | rest], total, offset, acc) do
    cond do
      is_integer(total) and total > 0 and offset >= total -> Enum.reverse(acc)
      count == nil and rest != [] -> trim(rest, total, offset, acc)
      true -> trim(rest, total, offset + (count || 0), [part | acc])
    end
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
  def watched_in_season(tmdb_id, season, marks, total \\ nil) do
    tmdb_id
    |> parts(season, total)
    |> Enum.reduce(0, fn {mal, _}, acc -> acc + Map.get(marks, mal, 0) end)
  end
end
```

### `lib/roki/watch.ex` — rating per MAL entry

```elixir
  @doc """
  Where a title is rated; `entry` is the MyAnimeList entry of the season on screen (MAL rates
  by season, TMDB by show).

  Where a title is rated. Anime goes to MyAnimeList while an account is connected (the entry
  is the title's first season, or the film itself) and to TMDB otherwise; everything else is
  TMDB's. Call inside `Roki.Laev.run/2`: the answer depends on the user's own keys.

  `{:mal, mal_id}` or `:tmdb`.
  """
  def rating_target(title, entry \\ nil) do
    mal =
      if title.anime? and Laev.MAL.authenticated?() do
        case title.type do
          _ when is_integer(entry) ->
            entry

          "movie" ->
            Laev.AnimeMap.mal_id("movie", title.id, nil)

          _ ->
            Roki.Watch.Anime.first_entry(title.id)
        end
      end

    if is_integer(mal), do: {:mal, mal}, else: :tmdb
  end

  @doc """
  Your own rating of a title: `{provider, {:ok, 8.5 | nil}}` with `provider` `:tmdb` or `:mal`
  (MyAnimeList scores are whole numbers), or `{:tmdb, :no_account}` when no TMDB account is
  linked in laev (ratings are sent with a TMDB session, which laev holds).
  """
  def my_rating(uuid, title, entry \\ nil) do
    Roki.Laev.run(uuid, fn ->
      case rating_target(title, entry) do
        {:mal, mal} ->
          case Laev.MAL.list_status(mal) do
            %{score: n} when is_integer(n) and n > 0 -> {:mal, {:ok, n * 1.0}}
            _ -> {:mal, {:ok, nil}}
          end

        :tmdb ->
          if Laev.Tmdb.account?() do
            {:tmdb,
             {:ok,
              if(title.type == "movie",
                do: Laev.Tmdb.movie_rating(title.id),
                else: Laev.Tmdb.tv_rating(title.id)
              )}}
          else
            {:tmdb, :no_account}
          end
      end
    end)
  end

  @doc "Rate a title (TMDB: 0.5–10 in half steps; MyAnimeList: 1–10): `{:ok, rating}` or `{:error, why}`."
  def rate(uuid, title, value, entry \\ nil) do
    Roki.Laev.run(uuid, fn ->
      case rating_target(title, entry) do
        {:mal, mal} ->
          score = value |> round() |> max(1) |> min(10)

          case Laev.MAL.rate(mal, score) do
            :ok -> {:ok, score * 1.0}
            other -> {:error, other}
          end

        :tmdb ->
          if title.type == "movie",
            do: Laev.Tmdb.rate_movie(title.id, value),
            else: Laev.Tmdb.rate_tv(title.id, value)
      end
    end)
  end

  @doc "Take your rating back: `:ok` or `{:error, why}`."
  def clear_rating(uuid, title, entry \\ nil) do
    Roki.Laev.run(uuid, fn ->
      case rating_target(title, entry) do
        {:mal, mal} ->
          case Laev.MAL.rate(mal, 0) do
            :ok -> :ok
            other -> {:error, other}
          end

        :tmdb ->
          if title.type == "movie",
            do: Laev.Tmdb.clear_movie_rating(title.id),
            else: Laev.Tmdb.clear_tv_rating(title.id)
      end
    end)
  end
```

Also candidates for a shared module (season/part picker and "continue where you were"): `sections/2`,
`locate_section/3`, `play_for/4`, `next_unseen/4`, `section_counts/3` (roki's `lib/roki/watch.ex`, shown next).
Port them if the CLI has a season picker; otherwise skip.

### `lib/roki/watch.ex` — sections / continue logic

```elixir
  @doc """
  What the season picker lists: one *section* per TMDB season — or, for anime where TMDB has
  merged several cours into one season, one per MyAnimeList entry, numbered the way MAL does.
  `%{key, season, from, count, total, mal, label, short}`: `season` is TMDB's; `from`/`count`
  say which of its episodes the section holds (episode `from + 1` is this section's number 1);
  `short` is the "S2" the buttons use.
  """
  def sections(uuid, title) do
    Roki.Laev.run(uuid, fn -> build_sections(title) end)
  end

  defp build_sections(title) do
    main = Enum.count(title.seasons, &(&1.number > 0))

    Enum.flat_map(title.seasons, fn s ->
      name = s.name || "Season #{s.number}"

      parts =
        if title.anime? and s.number > 0,
          do: Roki.Watch.Anime.parts(title.id, s.number, s.episodes),
          else: []

      case parts do
        [_, _ | _] ->
          last = length(parts)

          {out, _} =
            parts
            |> Enum.with_index(1)
            |> Enum.map_reduce(0, fn {{mal, count}, i}, from ->
              last? = i == last
              n = count || 0

              {%{
                 key: "#{s.number}.#{i}",
                 season: s.number,
                 from: from,
                 count: if(last?, do: nil, else: count),
                 total: if(last?, do: max((s.episodes || 0) - from, n), else: n),
                 mal: mal,
                 label: if(main == 1, do: "Season #{i}", else: "#{name} · Part #{i}"),
                 short: if(main == 1, do: "S#{i}", else: "S#{s.number}P#{i}")
               }, from + n}
            end)

          out

        _ ->
          [
            %{
              key: "#{s.number}",
              season: s.number,
              from: 0,
              count: nil,
              total: s.episodes || 0,
              mal: with([{mal, _}] <- parts, do: mal, else: (_ -> nil)),
              label: name,
              short: "S#{s.number}"
            }
          ]
      end
    end)
  end

  @doc "The section holding a TMDB season's episode, and that episode's number inside it."
  def locate_section(sections, season, tmdb_episode) do
    sec =
      Enum.find(sections, fn x ->
        x.season == season and tmdb_episode > x.from and
          (x.count == nil or tmdb_episode <= x.from + x.count)
      end) || Enum.find(sections, &(&1.season == season))

    if sec, do: {sec, max(tmdb_episode - sec.from, 1)}, else: nil
  end

  @doc """
  What Play should offer for a series, from what is actually watched rather than only from the
  last thing played: an episode left half-way is "Continue"; otherwise "Next" is the first
  unwatched episode after the last one you finished (the next season's first, when a season is
  done); with nothing watched it is "Start", and with everything watched "Watch again".
  Anything skipped earlier is only offered when nothing lies ahead.
  """
  def play_for(uuid, title, sections, resume) do
    base = play_info(sections, resume)

    if sections == [] do
      base
    else
      counts = section_counts(uuid, title, sections)
      started? = Enum.any?(counts, fn {_key, n} -> n > 0 end)

      cond do
        base.continue? and not episode_done?(uuid, title, base.season, base.episode) ->
          base

        not started? and not base.continue? ->
          base

        true ->
          case next_unseen(uuid, title, sections, counts) do
            {sec, tmdb_ep} ->
              %{
                season: sec.season,
                episode: tmdb_ep,
                continue?: true,
                verb: "Next",
                label: "#{sec.short}.E#{tmdb_ep - sec.from}"
              }

            nil ->
              %{play_info(sections, nil) | verb: "Watch again"}
          end
      end
    end
  end

  # The first unwatched, aired episode after the last section with anything watched in it (after
  # its furthest watched episode there); failing that, a gap further back.
  defp next_unseen(uuid, title, sections, counts) do
    real = Enum.filter(sections, &(&1.season > 0))

    last =
      real
      |> Enum.map(&(Map.get(counts, &1.key, 0) > 0))
      |> Enum.reverse()
      |> Enum.find_index(& &1)

    from_idx = if last, do: length(real) - 1 - last, else: 0
    {behind, ahead} = Enum.split(real, from_idx)

    unwatched_in(uuid, title, ahead, counts, true) ||
      unwatched_in(uuid, title, behind, counts, false)
  end

  @doc "How many episodes of each section are marked watched: `%{key => count}`."
  def section_counts(uuid, title, sections) do
    Roki.Laev.run(uuid, fn ->
      if title.anime? do
        marks = Laev.Position.anime_marks()
        Map.new(sections, &{&1.key, (&1.mal && Map.get(marks, &1.mal, 0)) || 0})
      else
        by_season = Map.get(Laev.Position.episode_marks(), {"tv", title.id}, %{})
        Map.new(sections, &{&1.key, Map.get(by_season, &1.season, 0)})
      end
    end)
  end
```

---

## 3. ffmpeg conversion (`Laev.Remux.Worker`) — runaway CPU (BUG)

Incident 2026-10-23: a French Lupin 4K H.265 release was played in the browser. laev re-encodes anything not
h264 with `-c:v libx264 -b:v 6M` — **no speed preset, source resolution** — so a 4K file never reaches real time
and takes every core; four such encodes took the host to load average ~150. Also a worker lives `@ttl_ms = 2h`
whatever happens, and nothing stops it when the page's "ready" wait times out or the viewer leaves.

Do:
* Encode with a fast preset (`-preset veryfast` for libx264; the matching fast setting for nvenc/qsv/vaapi) and cap
  the output height (e.g. `-vf scale=-2:'min(1080,ih)'`), keep `-pix_fmt yuv420p` for 10-bit/HDR sources.
* `Laev.Playback.ready/3` timing out must stop the worker (`Laev.Remux.stop/1`) — roki does this in `ready_or_stop`.
* Stop idle workers: when no segment/playlist has been requested for ~10 minutes. Expose
  `Laev.Remux.touch(id)` (called by whatever serves the files) and an idle sweep. Roki's version is below
  (`touch/1` called from the web app's stream controller; the sweep stops what is idle).
* Offer a guard for callers: `Laev.Playback.heavy?(source)` (video not h264) and an option to refuse a re-encode
  above a height (roki refuses > 1080p in the browser target) and to cap concurrent encoders (roki: 2).

### `lib/roki/watch/reaper.ex` — idle reaper (whole file)

```elixir
defmodule Roki.Watch.Reaper do
  @moduledoc """
  Stops conversions nobody is watching. laev's remux worker keeps ffmpeg running for two hours
  whatever happens to the page, and a re-encode of a 4K release takes every core the whole time:
  a closed tab, or a video that never became ready, left it burning.

  `touch/1` is called each time the stream controller serves a file of a conversion; every minute
  the ones not asked for in ten are stopped (their finished segments stay on disk as a cache).
  """
  use GenServer

  @table __MODULE__
  @every :timer.minutes(1)
  @idle_s 10 * 60

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "A conversion was just asked for."
  def touch(id) do
    :ets.insert(@table, {id, System.monotonic_time(:second)})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set])
    Process.send_after(self(), :sweep, @every)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:second)

    for id <- running() do
      case :ets.lookup(@table, id) do
        # First seen: the clock starts now, so a conversion that just began is never cut short.
        [] -> :ets.insert(@table, {id, now})
        [{_, at}] when now - at > @idle_s -> stop(id)
        _ -> :ok
      end
    end

    Process.send_after(self(), :sweep, @every)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp stop(id) do
    Laev.Remux.stop(id)
    :ets.delete(@table, id)
  end

  defp running do
    Registry.select(Laev.Remux.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  rescue
    _ -> []
  end
end
```

### `lib/roki/watch.ex` — guards

```elixir
  @doc "Whether playing this release means re-encoding it here (its video is not h264)."
  def heavy?({source, _stream}), do: heavy?(source)
  def heavy?(%{codec: codec}) when codec in ["h265", "av1"], do: true
  def heavy?(_), do: false

  @doc """
  Start `stream` for this user and say where to play it from.

  `{:ok, player}` where `player` is `%{url:, hls?:, resume_at:, remux_id:, subtitles:}`:
  a release a browser can read is played directly; anything else is remuxed to HLS by laev
  (ffmpeg) and waited for until the first segments are on disk. Also writes the history entry,
  so the title shows up in the user's History and as the thing to continue.
  """
  def start(uuid, ctx, source, stream) do
    cond do
      # A 4K re-encode on software never keeps up with playing, and takes every core trying.
      heavy?(source) and not Sources.resolution_at_most?(source.resolution, @transcode_cap) ->
        {:error, :too_heavy}

      heavy?(source) and encoders_running() >= @max_encoders ->
        {:error, :busy}

      true ->
        do_start(uuid, ctx, source, stream)
    end
  end

  defp do_start(uuid, ctx, source, stream) do
    Roki.Laev.run(uuid, fn ->
      with {:ok, src} <- Laev.Playback.browser_source(ctx, stream, title: ctx.title),
           true <- src.playable || {:error, src[:reason] || :not_playable},
           :ok <- ready_or_stop(src) do
        save_resume(ctx, source)

        {:ok,
         %{
           url:
             if(src.kind == :remux, do: "/stream/#{src.remux_id}/playlist.m3u8", else: src.url),
           hls?: src.kind == :remux,
           resume_at: src.resume_at,
           remux_id: src[:remux_id],
           filename: src.filename,
           subtitles: embedded_subtitles(src)
         }}
      end
    end)
  end

  # A conversion that did not get going is stopped, not left to run its two hours.
  defp ready_or_stop(src) do
    case ready(src) do
      :ok ->
        :ok

      other ->
        if src.kind == :remux, do: Laev.Remux.stop(src.remux_id)
        other
    end
  end

  defp ready(%{kind: :remux, remux_id: id}), do: Laev.Playback.ready(id, :fast, 180_000)
  defp ready(_), do: :ok
```

---

## 4. Subtitles

Problems and fixes:
* `Laev.SubtitleFetch.fetch/2` returns only the single best OpenSubtitles file, and re-searches on every play.
  Add `Laev.OpenSubtitles.search/1` results as a *list API for UIs* (it exists; make `SubtitleFetch` expose
  `candidates(ctx, lang)`), and a **disk cache by file id** for downloads (the free account has a tiny daily
  download quota, 406 = used up), a cache of the automatic pick per (type, tmdb, season, episode, lang), and a
  **negative cache** (nothing found / service said no → don't ask again for hours). Roki's versions below.
* Downloads need the account login (username + password), searching only the API key. The package never told the
  user: `opensubtitles/3` returns `{:error, :opensubtitles_needs_login}` and callers show nothing. Surface it.
* Login check: OpenSubtitles' `/login` answers **400 "remember to use your username and not your email"** when an
  email is given, 401 for a wrong password, 429 for >1 login/second/IP. Add `Laev.OpenSubtitles.verify_login/2`
  with those messages (roki's `check_os_login`, below).
* `OPENSUBTITLES_USERNAME` / `OPENSUBTITLES_PASSWORD` exist in `Laev.Config.keys/0` but are **not options in
  `Laev.Settings`**, so settings UIs cannot manage them (roki writes them with `Config.write` + `Scope.set`).
  Make them real settings (secret type), validated with `verify_login`.
* Jimaku: `Laev.Jimaku.subtitle_file/3` takes the first file found, which is often a streaming cut ~30 s off a rip.
  Roki offers up to 5 plausible Japanese files, the release's own group first (`jimaku_tracks`, below) — expose
  `Laev.Jimaku.candidates/3` and rank by closeness to the release name.
* `Laev.OpenSubtitles.srt_to_vtt/1` only replaces the millisecond comma; roki's `Roki.Subtitles.to_vtt/2` handles
  more (below) — merge it.

### `lib/roki/watch.ex` — OpenSubtitles list + cached download + automatic pick + negative cache

```elixir
  @doc """
  A subtitle in the user's own language from OpenSubtitles or Jimaku, when they have a key
  for one and the release did not carry it. Written next to the stream as WebVTT.
  `{:ok, %{lang:, label:, url:}}` or `:none` (no provider, nothing found — never an error:
  a subtitle problem must not get in the way of watching).
  """
  def external_subtitle(uuid, ctx, play_id, wanted \\ nil) do
    lang = wanted || Roki.Laev.run(uuid, fn -> Laev.Config.subs_lang() end)
    key = {ctx.type, ctx.tmdb_id, ctx[:season], ctx[:episode], lang}

    cond do
      not (is_binary(lang) and lang != "") ->
        :none

      match?({:ok, _}, Roki.SubCache.get_auto(key)) ->
        {:ok, found} = Roki.SubCache.get_auto(key)
        {:ok, place_auto(play_id, lang, found)}

      # Nothing found (or the service said no) a moment ago: do not ask again for hours.
      Roki.TTLCache.cached?({:os_none, key}) ->
        :none

      true ->
        case fetch_auto(uuid, ctx, lang) do
          {:ok, found} ->
            Roki.SubCache.put_auto(key, found)
            {:ok, place_auto(play_id, lang, found)}

          :none ->
            Roki.TTLCache.fetch({:os_none, key}, 6 * 3_600, fn -> {:ok, :none} end)
            :none
        end
    end
  rescue
    _ -> :none
  end

  defp fetch_auto(uuid, ctx, lang) do
    Roki.Laev.run(uuid, fn ->
      with true <- Laev.OpenSubtitles.configured?() or Laev.Jimaku.configured?(),
           {:ok, path, label} <-
             Laev.SubtitleFetch.fetch(Map.put(ctx, :search_title, ctx.search_title), lang),
           {:ok, body} <- File.read(path) do
        source = if String.starts_with?(label, "Jimaku"), do: "Jimaku", else: "OpenSubtitles"

        {:ok,
         %{
           label: "#{language(lang)} · #{source}",
           vtt: Roki.Subtitles.to_vtt(Path.basename(path), body)
         }}
      else
        _ -> :none
      end
    end)
  end

  defp place_auto(play_id, lang, %{label: label, vtt: vtt}) do
    dir = Laev.Remux.dir(play_id)
    File.mkdir_p!(dir)
    file = "ext-#{String.slice(lang, 0, 2)}.vtt"
    File.write!(Path.join(dir, file), vtt)
    %{lang: lang, label: label, url: "/stream/#{play_id}/#{file}"}
  end

  @doc """
  What the subtitle menu can offer from OpenSubtitles for this user: `:off` (no key), `:search`
  (a key, so the choices can be listed, but downloading needs the account login too) or `:full`.
  """
  def os_state(uuid) do
    Roki.Laev.run(uuid, fn ->
      cond do
        Laev.OpenSubtitles.can_download?() -> :full
        Laev.OpenSubtitles.configured?() -> :search
        true -> :off
      end
    end)
  end

  @doc "The OpenSubtitles files for what is playing, in one language: `{:ok, [%{id, release, downloads}]}`."
  def os_search(uuid, ctx, lang) do
    key = {:os_search, ctx.type, ctx.tmdb_id, ctx[:season], ctx[:episode], lang}

    case Roki.TTLCache.fetch(key, 3_600, fn -> os_search_live(uuid, ctx, lang) end) do
      {:ok, _} = ok -> ok
      other -> other
    end
  end

  defp os_search_live(uuid, ctx, lang) do
    Roki.Laev.run(uuid, fn ->
      query = ctx[:search_title] || ctx.title

      opts =
        case ctx[:type] do
          "tv" ->
            [
              languages: lang,
              query: query,
              season_number: ctx[:season],
              episode_number: ctx[:episode]
            ]

          _ ->
            [languages: lang, query: query, tmdb_id: ctx[:tmdb_id]]
        end

      case Laev.OpenSubtitles.search(opts) do
        {:ok, subs} ->
          {:ok,
           subs
           |> Enum.uniq_by(& &1.file_id)
           |> Enum.take(25)
           |> Enum.map(&%{id: &1.file_id, release: &1.release, downloads: &1.downloads})}

        {:error, _} ->
          {:error, "OpenSubtitles did not answer. Try again in a moment."}
      end
    end)
  rescue
    _ -> {:error, "OpenSubtitles did not answer. Try again in a moment."}
  end

  @doc "Download one OpenSubtitles file for the player: `{:ok, track}` or `{:error, why}`."
  def os_fetch(uuid, play_id, id, lang, release, media \\ nil)

  def os_fetch(uuid, play_id, id, lang, release, media) when is_integer(id) do
    result =
      case Roki.SubCache.get_file(id) do
        {:ok, vtt} -> {:ok, vtt}
        :miss -> os_download(uuid, id)
      end

    case result do
      {:ok, vtt} ->
        track = place_os(play_id, id, lang, release, vtt)
        if media, do: Roki.SubCache.add_pick(uuid, media, %{id: id, lang: lang, release: release})
        {:ok, track}

      error ->
        error
    end
  end

  def os_fetch(_uuid, _play_id, _id, _lang, _release, _media), do: {:error, "bad request"}

  # One download, ever, per file: the converted text is kept for good.
  defp os_download(uuid, id) do
    Roki.Laev.run(uuid, fn ->
      with true <-
             Laev.OpenSubtitles.can_download?() ||
               {:error, "Add your OpenSubtitles username and password in Settings to download."},
           {:ok, srt} <- Laev.OpenSubtitles.download_srt(id) do
        vtt = Roki.Subtitles.to_vtt("#{id}.srt", srt)
        Roki.SubCache.put_file(id, vtt)
        {:ok, vtt}
      else
        {:error, {:opensubtitles_download, 406, _}} ->
          {:error, "Your OpenSubtitles download quota for today is used up."}

        {:error, msg} when is_binary(msg) ->
          {:error, msg}

        _ ->
          {:error, "OpenSubtitles would not give that file. Try another."}
      end
    end)
  rescue
    _ -> {:error, "OpenSubtitles would not give that file. Try another."}
  end

  defp place_os(play_id, id, lang, release, vtt) do
    dir = Laev.Remux.dir(play_id)
    File.mkdir_p!(dir)
    file = "ext-#{String.slice(lang, 0, 3)}-os#{id}.vtt"
    File.write!(Path.join(dir, file), vtt)

    %{
      lang: lang,
      label: "#{language(lang)} · OpenSubtitles · #{String.slice(release || "", 0, 70)}",
      url: "/stream/#{play_id}/#{file}"
    }
  end

  @doc """
  The OpenSubtitles files this user picked for this title before, as tracks again — read from the
  disk cache, never from the service. A file whose copy is gone is left out rather than fetched.
  """
  def os_saved(uuid, media, play_id) do
    for %{id: id, lang: lang, release: release} <- Roki.SubCache.picks(uuid, media),
        {:ok, vtt} <- [Roki.SubCache.get_file(id)] do
      place_os(play_id, id, lang, release, vtt)
    end
  rescue
    _ -> []
  end
```

### `lib/roki/watch.ex` — Jimaku candidates

```elixir
  @doc """
  The Japanese subtitle files Jimaku has for this anime episode, as tracks: the one most likely to
  be timed like the release first. Jimaku holds several per episode — the broadcast, Netflix's and
  Amazon's cuts, fansub groups' — and they do not all start at the same second; laev's own fetch
  takes the first it finds, which is often a streaming cut that runs half a minute off a rip. So
  the plausible ones are all offered, each named by where it came from (the sync buttons cover
  the rest). `source_name` is the release being played: a file from the same group comes first.
  """
  def jimaku_tracks(uuid, ctx, play_id, source_name) do
    Roki.Laev.run(uuid, fn ->
      query = ctx[:search_title] || ctx.title

      with true <- Laev.Jimaku.configured?(),
           {:ok, [_ | _] = entries} <- Laev.Jimaku.search(query),
           entry = jimaku_entry(entries, query),
           {:ok, files} <- Laev.Jimaku.files(entry["id"], ctx[:episode]) do
        tracks =
          files
          |> Enum.filter(&jimaku_japanese?/1)
          |> Enum.sort_by(&{jimaku_rank(&1["name"], source_name), &1["name"]})
          |> Enum.uniq_by(&jimaku_base/1)
          |> Enum.take(5)
          |> Enum.with_index()
          |> Enum.flat_map(fn {file, i} -> jimaku_track(file, i, play_id) end)

        if tracks == [], do: :none, else: {:ok, tracks}
      else
        _ -> :none
      end
    end)
  rescue
    _ -> :none
  end

  # The entry named exactly what was asked (Jimaku lists a show's seasons as separate entries and
  # puts the first season first, whichever was searched for).
  defp jimaku_entry(entries, query) do
    q = String.downcase(query)
    Enum.find(entries, &(String.downcase(&1["name"] || "") == q)) || hd(entries)
  end

  defp jimaku_japanese?(%{"name" => name}) do
    subtitle_file?(name) and not String.contains?(name, ["CHS", "CHT", ".zh", ".en", ".eng"]) and
      (String.contains?(name, [".ja", "JPN", "jpn"]) or
         String.match?(name, ~r/[\x{3040}-\x{30ff}\x{4e00}-\x{9fff}]/u) or
         not String.match?(name, ~r/\.(en|eng|fr|es|pt|de|it|ru|ar|id|vi|th)[\].]/i))
  end

  defp jimaku_japanese?(_), do: false

  defp jimaku_base(%{"name" => name}),
    do: name |> Path.rootname() |> String.replace(~r/\.(jpn|ja)$/i, "")

  # Same group as the release first; then the broadcast and the big fansub groups, whose timing
  # follows the rips; streaming cuts (Netflix, Amazon, [cc]/[sdh] captions) last; srt before ass.
  defp jimaku_rank(name, source_name) do
    n = String.downcase(name)

    group =
      with [_, g] <- Regex.run(~r/^\[([^\]]+)\]/, to_string(source_name)), do: String.downcase(g)

    base =
      cond do
        is_binary(group) and String.contains?(n, group) -> 0
        String.contains?(n, ["nanako", "tbs", "subsplease", "erai", "judas"]) -> 1
        String.contains?(n, ["netflix", "amazon", "[cc]", "[sdh]", "crunchyroll"]) -> 3
        true -> 2
      end

    base * 2 + if(String.ends_with?(n, ".srt"), do: 0, else: 1)
  end

  defp jimaku_track(%{"name" => name, "url" => url}, i, play_id) do
    with {:ok, %{status: 200, body: body}} when is_binary(body) <-
           Req.get(url, receive_timeout: 15_000, retry: :transient, max_retries: 1),
         vtt when is_binary(vtt) <- Roki.Subtitles.to_vtt(name, body) do
      dir = Laev.Remux.dir(play_id)
      File.mkdir_p!(dir)
      file = if i == 0, do: "ext-ja.vtt", else: "ext-ja-#{i + 1}.vtt"
      File.write!(Path.join(dir, file), vtt)

      [
        %{
          lang: "ja",
          label: "Japanese · #{jimaku_label(name)}",
          url: "/stream/#{play_id}/#{file}"
        }
      ]
    else
      _ -> []
    end
  end
```

### `lib/roki/sub_cache.ex` — disk cache (whole file)

```elixir
defmodule Roki.SubCache do
  @moduledoc """
  Subtitle files that cost a download from OpenSubtitles (a small daily quota on a free account),
  kept on disk so the same file is never fetched twice: by file id for the ones picked from the
  list, by title/episode/language for the one fetched automatically, and, per user, which files
  were picked for which title, so a reload puts them back without asking the service anything.

  Lives under the laev users directory (`_subs/`), which is in `data/`. A file's text is the same
  for everyone, so the file cache is shared; the picks are per user.
  """

  def dir, do: Path.join(Roki.Laev.base_dir(), "_subs")

  @doc "The WebVTT text of a downloaded OpenSubtitles file, if kept."
  def get_file(id) when is_integer(id) do
    case File.read(Path.join([dir(), "files", "#{id}.vtt"])) do
      {:ok, vtt} -> {:ok, vtt}
      _ -> :miss
    end
  end

  def put_file(id, vtt) when is_integer(id) do
    path = Path.join([dir(), "files", "#{id}.vtt"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, vtt)
  end

  @doc "What the automatic fetch found for a title, episode and language: `%{label, vtt}`."
  def get_auto(key) do
    with {:ok, body} <- File.read(auto_path(key)),
         {:ok, %{"label" => label, "vtt" => vtt}} <- Jason.decode(body) do
      {:ok, %{label: label, vtt: vtt}}
    else
      _ -> :miss
    end
  end

  def put_auto(key, %{label: label, vtt: vtt}) do
    path = auto_path(key)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(%{label: label, vtt: vtt}))
  end

  defp auto_path(key) do
    name = :sha256 |> :crypto.hash(:erlang.term_to_binary(key)) |> Base.encode16(case: :lower)
    Path.join([dir(), "auto", binary_part(name, 0, 24) <> ".json"])
  end

  @doc "The files this user picked for a title: `[%{id, lang, release}]`."
  def picks(uuid, media) do
    with {:ok, body} <- File.read(picks_path(uuid)),
         {:ok, %{} = all} <- Jason.decode(body),
         list when is_list(list) <- all[media] do
      for %{"id" => id, "lang" => lang} = p <- list, is_integer(id) do
        %{id: id, lang: lang, release: p["release"]}
      end
    else
      _ -> []
    end
  end

  def add_pick(uuid, media, %{id: id} = pick) do
    all =
      with {:ok, body} <- File.read(picks_path(uuid)), {:ok, %{} = m} <- Jason.decode(body) do
        m
      else
        _ -> %{}
      end

    list = Enum.reject(all[media] || [], &(&1["id"] == id))
    entry = %{"id" => id, "lang" => pick.lang, "release" => pick.release}
    File.mkdir_p!(Path.dirname(picks_path(uuid)))
    File.write!(picks_path(uuid), Jason.encode!(Map.put(all, media, list ++ [entry])))
  end

  defp picks_path(uuid), do: Path.join(Roki.Laev.dir(uuid), "os-picks.json")
end
```

### `lib/roki/subtitles.ex` — to_vtt (whole file)

```elixir
defmodule Roki.Subtitles do
  @moduledoc """
  A subtitle file, from whatever the user has, as WebVTT — the one format the study
  sidebar reads.

  The conversions themselves are laev's (`Laev.Subtitles`: SubRip and ASS/SSA to
  WebVTT). This adds the part a file upload needs first: working out the text
  encoding. Subtitle files in the wild are UTF-8 (usually), UTF-8 with a byte-order
  mark, UTF-16, or Latin-1/Windows-1252 for French and other Western languages; a
  file that is none of the Unicode ones is read as Latin-1, which is right for French
  and wrong for, say, Shift-JIS Japanese (those need a proper encoding detector).
  """

  @doc "Convert an uploaded subtitle file to WebVTT, by its content and then its name."
  def to_vtt(name, content) when is_binary(name) and is_binary(content) do
    text = to_utf8(content)

    cond do
      String.starts_with?(text, "WEBVTT") -> text
      ass?(name) -> Laev.Subtitles.ass_to_vtt(text)
      true -> Laev.Subtitles.srt_to_vtt(text)
    end
  end

  defp ass?(name), do: name |> String.downcase() |> String.ends_with?([".ass", ".ssa"])

  # UTF-8 as is, a BOM dropped; UTF-16 by its BOM; else Latin-1.
  defp to_utf8(<<0xFF, 0xFE, rest::binary>>), do: utf16(rest, :little)
  defp to_utf8(<<0xFE, 0xFF, rest::binary>>), do: utf16(rest, :big)
  defp to_utf8(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: to_utf8(rest)

  defp to_utf8(content) do
    if String.valid?(content),
      do: content,
      else: :unicode.characters_to_binary(content, :latin1, :utf8)
  end

  defp utf16(bytes, endianness) do
    case :unicode.characters_to_binary(bytes, {:utf16, endianness}, :utf8) do
      text when is_binary(text) -> text
      _ -> ""
    end
  end
end
```

### `lib/roki/laev.ex` — login check

```elixir
  @doc """
  The OpenSubtitles account: searching needs only the API key, but downloading a file is done
  as a logged-in user. `%{key?: bool, user: name | nil, login?: bool}` (the password is never read back).
  """
  def os_login(uuid) do
    run(uuid, fn ->
      user = Laev.Scope.get(:opensubtitles_username)

      %{
        key?: Laev.OpenSubtitles.configured?(),
        user: if(user in [nil, ""], do: nil, else: user),
        login?: Laev.OpenSubtitles.can_download?()
      }
    end)
  end

  @doc "Save the OpenSubtitles login once the service accepts it. `:ok` or `{:error, why}`."
  def put_os_login(uuid, user, pass) do
    user = String.trim(user || "")
    pass = String.trim(pass || "")

    run(uuid, fn ->
      with true <-
             (user != "" and pass != "") || {:error, "enter both the username and the password"},
           true <-
             Laev.OpenSubtitles.configured?() || {:error, "add the OpenSubtitles API key first"},
           true <-
             not String.contains?(user, "@") or
               {:error, "OpenSubtitles wants your username, not your email address"},
           :ok <- check_os_login(user, pass) do
        Laev.Config.write([{"OPENSUBTITLES_USERNAME", user}, {"OPENSUBTITLES_PASSWORD", pass}])
        Laev.Scope.set(:opensubtitles_username, user)
        Laev.Scope.set(:opensubtitles_password, pass)
        Roki.Stats.forget(uuid)
        :ok
      end
    end)
  end

  defp check_os_login(user, pass) do
    headers = [
      {"api-key", Laev.Scope.get(:opensubtitles_api_key)},
      {"user-agent", Laev.Scope.get(:opensubtitles_user_agent) || "laev v1.0"},
      {"accept", "application/json"}
    ]

    case Req.post("https://api.opensubtitles.com/api/v1/login",
           headers: headers,
           json: %{username: user, password: pass},
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: 400}} ->
        {:error, "OpenSubtitles wants your username, not your email address"}

      {:ok, %{status: 429}} ->
        {:error, "OpenSubtitles says too many login attempts — wait a minute and try again"}

      {:ok, %{status: s}} when s in [401, 403] ->
        {:error, "OpenSubtitles did not accept that username and password"}

      {:ok, %{status: s, body: %{"message" => m}}} when is_binary(m) ->
        {:error, "OpenSubtitles answered #{s}: #{String.trim(m)}"}

      {:ok, %{status: s}} ->
        {:error, "OpenSubtitles answered #{s}"}

      {:error, _} ->
        {:error, "could not reach OpenSubtitles"}
    end
  end
```

---

## 5. First-run setup, as a library function

The CLI wizard generates its laev key in a private `gen_sync_token/0` (`cli.ex`); roki needed the same thing for a
web "set up in one step" and wrote `Roki.Laev.setup/2`. Make one public function used by both
(`Laev.Setup.first_run(keys)`):

1. require TMDB + at least one of Real-Debrid / TorBox; 2. **validate each key with its service before saving**
(`Laev.Settings.validate/2` exists); 3. generate `laev_<32 random bytes b64url>.<32 random bytes b64url>`;
4. `Laev.Sync.connect/2` with `LAEV_SYNC_KEYS=on` so the keys travel; 5. save the keys, sync once; 6. on any
failure leave nothing behind (disconnect / remove the config). Also `replace_key/3`: "save a key only if the
service accepts it".

### `lib/roki/laev.ex` — setup / rollback

```elixir
  @doc """
  First-time setup from the site: check the keys, make a laev key, connect with it (the server
  provisions any well-formed key), keep the keys carried so the terminal app gets them too.
  `keys` is `%{"RD_TOKEN" => …, "TORBOX_API_KEY" => …, "TMDB_API_KEY" => …}`; blanks are skipped.
  Nothing is left behind on failure.
  """
  def setup(uuid, keys) do
    keys = for {k, v} <- keys, (v = String.trim(v || "")) != "", into: %{}, do: {k, v}

    cond do
      not Map.has_key?(keys, "TMDB_API_KEY") ->
        {:error, "A TMDB key is needed to find titles."}

      not (Map.has_key?(keys, "RD_TOKEN") or Map.has_key?(keys, "TORBOX_API_KEY")) ->
        {:error, "Add a Real-Debrid or TorBox key — one of them is needed to play anything."}

      true ->
        case check_all(uuid, keys) do
          :ok -> create_account(uuid, keys)
          error -> error
        end
    end
  end

  defp check_all(uuid, keys) do
    run(uuid, fn ->
      Enum.find_value(keys, :ok, fn {key, value} ->
        case Settings.validate(key, value) do
          {:ok, _} -> nil
          {:error, why} -> {:error, "#{key_name(key)}: #{explain(why)}"}
        end
      end)
    end)
  end

  defp key_name("RD_TOKEN"), do: "Real-Debrid"
  defp key_name("TORBOX_API_KEY"), do: "TorBox"
  defp key_name("TMDB_API_KEY"), do: "TMDB"

  defp create_account(uuid, keys) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    result =
      with {:ok, _} <- connect(uuid, "laev_#{token}.#{secret}", carry_keys?: true),
           :ok <- run(uuid, fn -> put_all(keys) end) do
        sync(uuid)
        :ok
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        disconnect(uuid)
        {:error, "Could not set up: " <> explain(reason)}
    end
  end

  defp put_all(keys) do
    Enum.reduce_while(keys, :ok, fn {k, v}, :ok ->
      case Settings.put(k, v) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @doc """
  Save a key only if the service accepts it. `{:ok, detail}` with what the service
  said about the account (plan, days left), or `{:error, why}` with nothing saved.
  """
  def replace_key(uuid, key, value) do
    value = String.trim(value)

    run(uuid, fn ->
      with true <- value != "" or {:error, "paste the key first"},
           {:ok, detail} <- Settings.validate(key, value),
           :ok <- Settings.put(key, value) do
        Roki.Stats.forget(uuid)
        {:ok, detail}
      else
        {:error, reason} -> {:error, reason}
        other -> other
      end
    end)
  end
```

---

## 6. A reusable sync server (`Laev.SyncServer`)

The hosted sync store used to live in a blog app and now lives in roki; two copies of the same merge code exist.
Ship one implementation in laev so any host can serve the API with a storage adapter (Ecto/ETS/file), and the
blog's copy can be deleted. The API (unchanged, byte-for-byte; clients depend on it):

* `GET|PUT|PATCH <base>/<key>/<doc>`; `<key>` = the part of the laev key before the dot, format
  `^laev_[A-Za-z0-9_-]{30,64}$` (else 401); only `sha256(key)` is stored.
* GET: 200 + exact stored bytes + `ETag` (sha256 of bytes), or 404 (never invent content).
* PUT: stores the body **byte for byte** (so the web layer must keep the raw body — see the reader below);
  `If-Match` stale → 412; body must be a JSON object with one of `version|watchlist|resume|positions|tracks` else
  422; > 5 MB → 413.
* PATCH: merge a partial bundle: per collection (`watchlist resume positions tracks`) per record last-write-wins on
  `updated_at`, ties go to the incoming, tombstones (`deleted: true`) are stored; unknown top-level keys copied;
  serialized per (key, doc) with an advisory lock.
* The key is the credential: keep it out of logs (roki rewrites `request_path` to `/api/laev/[key]/<doc>` and
  filters the `token` param).

Roki's working implementation (store, controller, raw-body reader):

### `lib/roki/sync_store.ex` — store (whole file)

```elixir
defmodule Roki.SyncStore do
  @moduledoc """
  Dumb blob sync store for the Laev CLI (movie watching).

  One opaque JSON document per `(token, doc)` — stored byte-for-byte,
  never parsed or reshaped; the client does all merging. The server's
  whole job is durability, tenancy isolation, and optimistic concurrency
  via ETags (sha256 of the content, so identical bytes → identical ETag).

  Open registration: ANY well-formed token is a tenant — no allowlist.
  The two gates against junk landing on the server are the token FORMAT
  (`laev_` + ≥30 chars of URL-safe randomness — nothing a scanner emits
  by accident) and `plausible_document?/1` (the body must be a JSON
  object carrying at least one Laev key). If abuse ever shows up, an
  allowlist can return in `valid_token?/1` without touching anything
  else. Only the token's sha256 lands in the database.
  """

  import Ecto.Query

  alias Roki.Repo

  @max_bytes 5 * 1024 * 1024
  @token_format ~r/^laev_[A-Za-z0-9_-]{30,64}$/
  # Reference shape: {"version":1,"watchlist":{…},"resume":{…},…}. Any
  # one of these marks the payload as Laev data; extra keys are fine.
  @laev_keys ~w(version watchlist resume positions tracks)

  def max_bytes, do: @max_bytes

  @doc "Does this look like a Laev token? (format check, not an allowlist)"
  def valid_token?(token) when is_binary(token), do: Regex.match?(@token_format, token)
  def valid_token?(_), do: false

  @doc """
  Is this body plausibly Laev data? Validation ONLY — the stored bytes
  are always the raw body, never a re-encoding of this parse.
  """
  def plausible_document?(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = map} -> Enum.any?(@laev_keys, &Map.has_key?(map, &1))
      _ -> false
    end
  end

  def plausible_document?(_), do: false

  @doc "Fetch a document. `{:ok, body, etag}` or `:not_found`."
  def get(token, doc) do
    from(k in "laev_documents",
      where: k.token_hash == ^hash(token) and k.doc == ^doc,
      select: {k.body, k.etag}
    )
    |> Repo.one()
    |> case do
      nil -> :not_found
      {body, etag} -> {:ok, body, etag}
    end
  end

  @doc """
  Store a document verbatim. Returns `{:ok, etag}`.

  With `if_match`, the write happens only when the stored ETag still
  matches — a single conditional UPDATE, so Postgres's row lock
  serializes concurrent writers and a lost race is `:precondition_failed`
  (→ 412), never a silent overwrite. An `if_match` against a missing
  document is also stale by definition.
  """
  def put(token, doc, body, if_match \\ nil)

  def put(token, doc, body, nil) do
    etag = etag_for(body)

    Repo.insert_all(
      "laev_documents",
      [
        %{
          token_hash: hash(token),
          doc: doc,
          body: body,
          etag: etag,
          updated_at: DateTime.utc_now()
        }
      ],
      on_conflict: {:replace, [:body, :etag, :updated_at]},
      conflict_target: [:token_hash, :doc]
    )

    {:ok, etag}
  end

  def put(token, doc, body, if_match) do
    etag = etag_for(body)

    {updated, _} =
      from(k in "laev_documents",
        where: k.token_hash == ^hash(token) and k.doc == ^doc and k.etag == ^if_match
      )
      |> Repo.update_all(set: [body: body, etag: etag, updated_at: DateTime.utc_now()])

    if updated == 1, do: {:ok, etag}, else: :precondition_failed
  end

  @doc """
  Merge a partial bundle into the stored document — the ONE place the
  server understands the record shape (GET/PUT stay opaque).

  The patch carries only changed records:

      {"version":1,"watchlist":{"tv:99":{"data":{…},"updated_at":1730000000,"deleted":false}}}

  Per (collection, key): last-write-wins on `updated_at`, incoming wins
  ties; `deleted: true` records are tombstones and are STORED as-is so
  deletions propagate to other devices. Anything the patch doesn't
  mention is untouched. Unknown top-level keys are copied over
  wholesale (client evolution). Returns `{:ok, etag}` of the merged
  document, or `{:error, :invalid}` when a named collection isn't a
  map of records.

  Concurrency: the whole read-merge-write runs in a transaction under a
  per-(token, doc) advisory lock, so concurrent merges serialize — no
  If-Match needed, and no lost updates from read-modify-write races.
  """
  def merge(token, doc, patch) when is_map(patch) do
    if collections_valid?(patch) do
      Repo.transaction(fn ->
        lock_doc(token, doc)

        stored =
          case get(token, doc) do
            {:ok, body, _etag} -> safe_decode(body)
            :not_found -> %{}
          end

        merged = merge_docs(stored, patch)
        body = Jason.encode!(merged)
        {:ok, etag} = put(token, doc, body)
        etag
      end)
    else
      {:error, :invalid}
    end
  end

  @collections ~w(watchlist resume positions tracks)

  defp collections_valid?(patch) do
    Enum.all?(@collections, fn coll ->
      case patch[coll] do
        nil -> true
        %{} -> true
        _ -> false
      end
    end)
  end

  defp merge_docs(stored, patch) do
    Enum.reduce(patch, stored, fn
      {coll, incoming}, acc when coll in @collections and is_map(incoming) ->
        Map.update(acc, coll, incoming, fn existing ->
          merge_collection(existing, incoming)
        end)

      {"version", v}, acc ->
        Map.update(acc, "version", v, fn old ->
          if is_number(old) and is_number(v), do: max(old, v), else: v
        end)

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end

  defp merge_collection(existing, incoming) when is_map(existing) do
    Enum.reduce(incoming, existing, fn {key, rec}, acc ->
      case acc do
        %{^key => current} ->
          if record_ts(rec) >= record_ts(current), do: Map.put(acc, key, rec), else: acc

        _ ->
          Map.put(acc, key, rec)
      end
    end)
  end

  # A stored collection that isn't a map (client wrote something odd via
  # PUT) is replaced by the incoming records rather than crashed on.
  defp merge_collection(_existing, incoming), do: incoming

  defp record_ts(%{"updated_at" => ts}) when is_number(ts), do: ts
  defp record_ts(_), do: 0

  defp safe_decode(body) do
    case Jason.decode(body) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  # Serializes merges per (token, doc) for the transaction's lifetime.
  # hashtext is a stable 32-bit hash; collisions merely over-serialize.
  defp lock_doc(token, doc) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [hash(token) <> "/" <> doc])
  end

  defp hash(token), do: Base.encode16(:crypto.hash(:sha256, token), case: :lower)

  defp etag_for(body), do: Base.encode16(:crypto.hash(:sha256, body), case: :lower)
end
```

### `lib/roki_web/controllers/sync_api_controller.ex` — controller (whole file)

```elixir
defmodule RokiWeb.SyncApiController do
  @moduledoc """
  Laev CLI sync API — a dumb blob store, two routes on one path:

      GET   /laev/:token/:doc → 200 + stored bytes + ETag, or 404
      PUT   /laev/:token/:doc → store body verbatim, 200 + new ETag
                                If-Match stale     → 412, no overwrite
      PATCH /laev/:token/:doc → merge a partial bundle (LWW per record,
                                tombstones kept), 200 + merged ETag; no
                                If-Match — merges serialize server-side
      all                     : malformed token    → 401
                                not Laev-shaped    → 422
                                > 5 MB             → 413

  Open registration: any token matching the Laev format is a tenant
  (see `Roki.SyncStore.valid_token?/1`); the PUT body must sniff as
  Laev data so bots can't park junk here. The token rides in the path
  (the CLI bakes it into its base URL: `https://…/laev/<token>/watchlist`).
  The body is opaque JSON stored byte-for-byte —
  `RokiWeb.RawBodyReader` preserves the raw bytes past the
  endpoint's JSON parser; never read the parsed params.
  """
  use RokiWeb, :controller

  alias Roki.SyncStore, as: Store

  plug :check_token

  def show(conn, %{"doc" => doc}) do
    case Store.get(conn.assigns.laev_token, doc) do
      {:ok, body, etag} ->
        conn
        |> put_resp_header("etag", quote_etag(etag))
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      :not_found ->
        # Never invent content — an empty store is a 404, not "{}".
        send_resp(conn, 404, "")
    end
  end

  def put(conn, %{"doc" => doc}) do
    body = raw_body(conn)

    cond do
      body == nil ->
        send_resp(conn, 400, "")

      byte_size(body) > Store.max_bytes() ->
        send_resp(conn, 413, "")

      not Store.plausible_document?(body) ->
        send_resp(conn, 422, "")

      true ->
        case Store.put(conn.assigns.laev_token, doc, body, if_match(conn)) do
          {:ok, etag} ->
            conn
            |> put_resp_header("etag", quote_etag(etag))
            |> send_resp(200, "")

          :precondition_failed ->
            send_resp(conn, 412, "")
        end
    end
  end

  def merge(conn, %{"doc" => doc}) do
    body = raw_body(conn)

    cond do
      body == nil ->
        send_resp(conn, 400, "")

      byte_size(body) > Store.max_bytes() ->
        send_resp(conn, 413, "")

      not Store.plausible_document?(body) ->
        send_resp(conn, 422, "")

      true ->
        # plausible_document? guarantees this decodes to a map.
        {:ok, patch} = Jason.decode(body)

        case Store.merge(conn.assigns.laev_token, doc, patch) do
          {:ok, etag} ->
            conn
            |> put_resp_header("etag", quote_etag(etag))
            |> send_resp(200, "")

          {:error, :invalid} ->
            send_resp(conn, 422, "")
        end
    end
  end

  # Raw bytes stashed by RawBodyReader when a parser consumed the body
  # (application/json); for pass-through content types (octet-stream)
  # the body is still unread and we read it here.
  defp raw_body(conn) do
    case conn.private[:laev_raw_body] do
      nil ->
        case Plug.Conn.read_body(conn, length: Store.max_bytes() + 1) do
          {:ok, body, _conn} -> body
          _ -> nil
        end

      iodata ->
        IO.iodata_to_binary(iodata)
    end
  end

  defp if_match(conn) do
    case get_req_header(conn, "if-match") do
      [value | _] ->
        value
        |> String.trim()
        |> String.replace_prefix("W/", "")
        |> String.trim("\"")

      [] ->
        nil
    end
  end

  defp quote_etag(etag), do: ~s("#{etag}")

  defp check_token(conn, _opts) do
    token = conn.path_params["token"]

    if Store.valid_token?(token) do
      assign(conn, :laev_token, token)
    else
      conn |> send_resp(401, "") |> halt()
    end
  end
end
```

### `lib/roki_web/raw_body_reader.ex` — raw body reader (whole file)

```elixir
defmodule RokiWeb.RawBodyReader do
  @moduledoc """
  Body reader for `Plug.Parsers` that stashes the RAW request bytes for
  `/api/laev/*` requests before the JSON parser consumes them.

  The Laev sync store's contract is byte-for-byte fidelity: what the CLI
  PUTs is exactly what a later GET returns. Phoenix's JSON parser decodes
  the body into params and the original bytes are gone — re-encoding is
  not the same document (key order, whitespace, number formatting). This
  reader is a no-op for every other path.
  """

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, chunk, conn} -> {:ok, chunk, stash(conn, chunk)}
      {:more, chunk, conn} -> {:more, chunk, stash(conn, chunk)}
      other -> other
    end
  end

  defp stash(%Plug.Conn{path_info: ["api", "laev" | _]} = conn, chunk) do
    acc = Map.get(conn.private, :laev_raw_body, [])
    Plug.Conn.put_private(conn, :laev_raw_body, [acc | chunk])
  end

  defp stash(conn, _chunk), do: conn
end
```

Roki's tests for this are the acceptance checklist: empty GET → 404; PUT then GET returns identical bytes and the
same ETag even for non-canonical JSON (odd key order, whitespace, unicode); stale If-Match → 412 with no overwrite;
two keys never see each other; malformed key → 401; non-laev body → 422; > 5 MB → 413; PATCH merge keeps the newer
record and tombstones; concurrent PATCHes do not lose updates.

---

## Do not change

* The sync address: default is `https://roki.ee/api/laev` (0.1.41). `https://sasha.don.ee/laev` is forwarded to it
  and must keep working for old installs.
* UI code (LiveView pages, the web player), per-user directories, the per-user source cache, and the external
  player hand-off links (VLC / m3u) stay in roki.

## When done

Bump the version, CHANGELOG entry per item, run the full suite, `mix hex.publish`, and tell the owner the new
version number plus which items were implemented and which were skipped and why. Roki will then update the
dependency and remove its workarounds.
