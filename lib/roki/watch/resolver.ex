defmodule Roki.Watch.Resolver do
  @moduledoc """
  Finding what to play for a film or an episode: the user's checked releases for it, from the
  source cache when they are still fresh, else a search and a probe of each release against their
  debrid account until some play. Used by the sources page (to list and choose) and the player
  page (to start the one it was asked for).

  `run/8` is for a task: everything slow happens inside it, and progress is sent to the process
  that asked as `{:status, token, text}` and `{:probe, token, done, playing, total}` messages.
  """

  alias Roki.Watch
  alias Roki.Watch.SourceCache

  @doc "The cache key for a film (`season`/`episode` nil) or an episode."
  def key(type, id, season, episode), do: {type, id, season, episode}

  @doc """
  `{:ok, result}` or `{:error, token, reason}`. `result` has `:ctx :playable :rest :cap :key
  :cached_at :good` (`cached_at`/`good` are nil for a fresh search). `force?` (Retry) ignores the
  cached releases and the shared search list.
  """
  def run(
        parent,
        token,
        uuid,
        title,
        season,
        episode,
        force?,
        mode,
        quick? \\ false,
        heavy_ok? \\ false,
        caps \\ %{}
      ) do
    key = key(title.type, title.id, season, episode)
    web = Roki.Laev.web_settings(uuid)
    hours = SourceCache.hours(web)

    # Re-encoding a video for the browser is what costs the server, so the browser only looks at what
    # needs none (H.264). An account that is allowed heavy encoding gets the rest only when it asked
    # for it for this search (`heavy_ok?`); everyone else is sent to an external player.
    light? = light?(mode, uuid, heavy_ok?)
    cached = if force?, do: nil, else: SourceCache.get(uuid, key, hours) |> lighten(light?, caps)

    size_cap = if mode == :browser, do: Watch.size_cap(web)

    with :ok <- Watch.subscription(uuid),
         ctx = Watch.ctx(uuid, title, season, episode),
         cap = Watch.ceiling(uuid, ctx, mode, web, caps),
         {:ok, res} <-
           from_cache(uuid, token, ctx, cap, key, cached)
           |> fresh_if_none(fn ->
             search(
               parent,
               token,
               uuid,
               title,
               season,
               episode,
               ctx,
               cap,
               key,
               hours,
               force?,
               quick?,
               light?,
               caps,
               size_cap
             )
           end) do
      {:ok, res}
    else
      {:error, reason} when light? and reason in [:only_heavy, :none_playable] ->
        {:error, token, :no_light}

      {:error, reason} ->
        {:error, token, reason}
    end
  end

  @doc "Whether a search for this account looks at light releases only."
  def light?(mode, uuid, heavy_ok?),
    do: mode == :browser and not (heavy_ok? and Roki.Keys.heavy?(uuid))

  @doc "Check the next page of unchecked releases: `{:ok, token, playable, rest}`."
  def more(parent, token, uuid, ctx, rest, have, key, hours, light? \\ false, caps \\ %{}) do
    {page, rest} = Watch.probe_page(rest)
    {playable, late} = probe_page(parent, token, uuid, ctx, page, false, light?, caps)
    rest = late ++ rest
    all = Watch.attach_and_rank(uuid, have ++ playable)
    if hours > 0, do: SourceCache.put(uuid, key, all, rest, light?)
    {:ok, token, all, rest}
  end

  # A saved list made for another player: only its light releases, and none left means search again.
  defp lighten(nil, _light?, _caps), do: nil
  defp lighten(%{light: true}, false, _caps), do: nil
  defp lighten(entry, false, _caps), do: entry

  defp lighten(entry, true, caps) do
    playable = Enum.reject(entry.playable, &Watch.heavy?(&1, caps))

    if playable == [],
      do: nil,
      else: %{entry | playable: playable, rest: Enum.reject(entry.rest, &Watch.heavy?(&1, caps))}
  end

  defp from_cache(_uuid, _token, _ctx, _cap, _key, nil), do: nil

  defp from_cache(uuid, token, ctx, cap, key, entry) do
    {:ok,
     %{
       token: token,
       ctx: ctx,
       # Ranked again as asked: the list was saved in whatever audio and subtitle language was
       # set then, and a changed setting should not wait for the cache to expire.
       playable: Roki.Laev.run(uuid, fn -> Watch.rank_playable(entry.playable) end),
       rest: entry.rest,
       cap: cap,
       key: key,
       cached_at: entry.at,
       good: entry.good
     }}
  end

  defp fresh_if_none(nil, fun), do: fun.()
  defp fresh_if_none(hit, _fun), do: hit

  defp search(
         parent,
         token,
         uuid,
         title,
         season,
         episode,
         ctx,
         cap,
         key,
         hours,
         force?,
         quick?,
         light?,
         caps,
         size_cap
       ) do
    send(parent, {:status, token, "Searching for releases…"})
    Roki.Keys.record(uuid, :search)

    with {:ok, %{query: query, sources: found}} <-
           Watch.sources(title, season, episode, uuid, force?),
         sources =
           Watch.with_library(uuid, query, found) |> in_study_order(uuid) |> prioritise(ctx),
         {:ok, sources} <- within_ceiling(uuid, sources, cap),
         {:ok, sources} <- Watch.within_size(sources, size_cap),
         {:ok, sources} <- only_light(sources, light?, caps),
         {:ok, playable, rest} <-
           probe_until_playable(parent, token, uuid, ctx, sources, [], quick?, light?, caps) do
      # (A list made for a browser that may not re-encode is saved as such: it lacks the heavy releases.)
      if hours > 0, do: SourceCache.put(uuid, key, playable, rest, light?)

      {:ok,
       %{
         token: token,
         ctx: ctx,
         playable: playable,
         rest: rest,
         cap: cap,
         key: key,
         cached_at: nil,
         good: nil
       }}
    end
  end

  defp only_light(sources, false, _caps), do: {:ok, sources}

  defp only_light(sources, true, caps) do
    case Enum.reject(sources, &Watch.heavy?(&1, caps)) do
      [] when sources != [] -> {:error, :only_heavy}
      light -> {:ok, light}
    end
  end

  # The shared list is ranked for no one in particular. A study session ranks it for its language
  # and keeps to what a browser can play: nothing above 1080p, and no release whose audio is known
  # not to have the language — all of it before anything is checked.
  defp in_study_order(sources, uuid) do
    case Roki.Study.current() do
      %{lang: lang} ->
        Roki.Laev.run(uuid, fn ->
          Laev.Sources.rank(sources, strict_audio: lang, max_resolution: "1080p")
        end)

      _ ->
        sources
    end
  end

  # Subtitles in the language but the speech in another is no help to someone learning it. Once
  # the tracks of a release have been read, only those with the language in their audio stay
  # (releases whose tracks could not be read are used only when nothing better is left).
  defp spoken_in_study_language(ranked) do
    case Roki.Study.current() do
      %{lang: lang} ->
        {yes, rest} =
          Enum.split_with(ranked, fn {source, _} ->
            Laev.Sources.audio_in?(source, lang) == true
          end)

        if yes != [],
          do: yes,
          else:
            Enum.filter(rest, fn {source, _} -> Laev.Sources.audio_in?(source, lang) == nil end)

      _ ->
        ranked
    end
  end

  # What is checked first matters: a search for a series returns what the uploaders posted for the
  # whole show, so the first page of releases can be all other episodes (S02E04 for episode 5,
  # "- 15" for episode 3), each rightly turned down once checked, while the releases that name this
  # episode wait their turn. So: releases that name the episode first, then packs that may hold it,
  # then the rest — and a release that names a different episode is not checked at all. Order inside
  # each group is the ranking it already had.
  defp prioritise(sources, %{episode: episode} = ctx) when is_integer(episode) do
    {other, mine} =
      Enum.split_with(sources, fn s ->
        not Laev.Episodes.pack?(s.name) and Laev.Episodes.wrong_numbering?(s.name, ctx)
      end)

    tier = fn s ->
      cond do
        Laev.Episodes.names_episode?(s.name, s.name, ctx) -> 0
        Laev.Episodes.pack?(s.name) -> 1
        true -> 2
      end
    end

    Enum.sort_by(mine, tier) ++ other
  end

  defp prioritise(sources, _ctx), do: sources

  # Strict mode: releases above the ceiling are not even checked.
  defp within_ceiling(uuid, sources, cap) do
    strict? = Roki.Laev.run(uuid, &Laev.Config.strict_resolution?/0)

    if strict? and cap do
      case Laev.Sources.at_most(sources, cap) do
        [] when sources != [] -> {:error, {:above_ceiling, length(sources), cap}}
        kept -> {:ok, kept}
      end
    else
      {:ok, sources}
    end
  end

  defp probe_until_playable(_parent, _token, _uuid, _ctx, [], [], _quick?, _light?, _caps),
    do: {:error, :none_playable}

  defp probe_until_playable(parent, token, uuid, ctx, sources, acc, quick?, light?, caps) do
    {page, rest} = Watch.probe_page(sources, if(quick?, do: 8, else: 12))
    {playable, late} = probe_page(parent, token, uuid, ctx, page, quick?, light?, caps)
    rest = late ++ rest
    # Starting in the browser is what is waited for: what is known from the names ranks it.
    ranked =
      Watch.attach_and_rank(uuid, acc ++ playable, fast: quick?) |> spoken_in_study_language()

    cond do
      ranked != [] -> {:ok, ranked, rest}
      rest == [] -> {:error, :none_playable}
      true -> probe_until_playable(parent, token, uuid, ctx, rest, [], quick?, light?, caps)
    end
  end

  # A release that never answers (a host that hangs) must not hold the page for ever: after this
  # long the round ends with what it has, and the ones still silent are given up on.
  @deadline_ms 45_000
  @quick_deadline_ms 30_000

  # One round of probing, 8 releases two at a time. Each answer is counted on the page as it
  # arrives; the task keeps the ones that play.
  defp probe_page(parent, token, uuid, ctx, page, quick?, light?, caps) do
    {:ok, agent} = Agent.start_link(fn -> %{done: 0, ok: [], seen: []} end)
    total = length(page)
    Roki.Keys.record(uuid, :probe, max(total, 1))
    send(parent, {:probe, token, 0, 0, total})
    send(parent, {:candidates, token, Enum.map(page, &Roki.Watch.Checks.summary/1)})

    notify = fn {:result, idx, source, result} ->
      # For an account that may not have a video re-encoded: a release whose name does not say what
      # the video is gets its real codec read here, and one that would need re-encoding is dropped
      # now rather than offered and refused later.
      result = scene_retry(result, source, idx, ctx)
      result = if light?, do: needs_reencode(source, result, caps), else: result

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

    # A whole page at once (laev's default is two): the first release that plays is what counts,
    # so they all race, and the answer comes with the quickest instead of after the waves.
    opts =
      [notify: notify, ctx: ctx, concurrency: if(quick?, do: 8, else: 4)] ++
        if(ctx.anime, do: [], else: [season: ctx.season])

    # Releases are not all numbered alike, and what plays is not always what was asked for: laev
    # asks each release for the episode number it uses and checks the file that comes back.
    indexed = Enum.with_index(page)

    task =
      Task.async(
        Roki.Study.wrap(fn ->
          Roki.Laev.run(uuid, fn ->
            # A release numbered by the part it belongs to is asked for that number.
            for {ctx, group} <- by_numbering(indexed, ctx) do
              Laev.Providers.probe_sources(group, probe_opts(opts, ctx))
            end
          end)
        end)
      )

    deadline =
      System.monotonic_time(:millisecond) + if(quick?, do: @quick_deadline_ms, else: @deadline_ms)

    late = await_probes(task, agent, page, parent, token, nil, quick?, deadline)

    ok = Agent.get(agent, & &1.ok)
    Agent.stop(agent)

    {ok
     |> Enum.sort_by(&elem(&1, 0))
     |> Enum.map(fn {_i, source, stream} -> {source, stream} end), late}
  end

  # `[{ctx, releases}]`: the releases that name the season in `ctx.scene` (Lupin's "S02E06" or
  # "S02E01" for TMDB's sixth episode of season one) are probed as that season and episode, the one
  # a release names when it names one; the rest as asked.
  defp by_numbering(indexed, %{scene: [{scene_season, _} | _] = numbers} = ctx) do
    {scene, rest} =
      Enum.split_with(indexed, fn {source, _} ->
        names_season?(source.name, scene_season) and not names_season?(source.name, ctx.season)
      end)

    alts =
      scene
      |> Enum.group_by(fn {source, _} ->
        {numbered_like(source.name, numbers), range?(source.name)}
      end)
      |> Enum.map(fn {{{s, e} = number, range?}, group} ->
        # A pack may count again from one (the "S02E01-E05" of a second part), so either number
        # is taken from it. A single episode of the second part is the carried-on number ("S02E06");
        # an "S02E01" is more likely the first episode of the show than this one.
        other = Enum.find_value(numbers, fn {_, n} -> if {s, n} != number, do: n end)
        {%{ctx | season: s, episode: e, tmdb_episode: (range? && other) || e}, group}
      end)

    Enum.reject([{ctx, rest} | alts], fn {_, group} -> group == [] end)
  end

  defp by_numbering(indexed, ctx), do: [{ctx, indexed}]

  defp numbered_like(name, numbers) do
    if range?(name) do
      Enum.find(numbers, fn {s, e} ->
        Regex.match?(~r/\bS0?#{s}[ ._-]?E0?#{e}(?!\d)/i, name)
      end) || hd(numbers)
    else
      hd(numbers)
    end
  end

  # A pack named for one numbering can hold its files under another ("Lupin S01 Part 1-2" has the
  # sixth episode as S02E01): when the file that came back names a different episode, or there is no
  # file for it, the pack is asked again as the numbering of the part, and the first that fits wins.
  defp scene_retry({:error, why} = result, source, index, %{scene: [_ | _] = numbers} = ctx)
       when why in [:another_episode, :no_file_for_episode] do
    if range?(source.name) do
      me = self()

      Enum.find_value(numbers, result, fn {s, e} ->
        other = Enum.find_value(numbers, fn {_, n} -> if n != e, do: n end)
        alt = %{ctx | season: s, episode: e, tmdb_episode: other || e}

        notify = fn
          {:result, _, _, r} -> send(me, {:scene_retry, r})
          _ -> :ok
        end

        Laev.Providers.probe_sources(
          [{source, index}],
          probe_opts([notify: notify, concurrency: 1], alt)
        )

        receive do
          {:scene_retry, {:ok, _} = ok} -> ok
          {:scene_retry, _} -> nil
        after
          60_000 -> nil
        end
      end)
    else
      result
    end
  end

  defp scene_retry(result, _source, _index, _ctx), do: result

  # A pack or a range of episodes, not a single one.
  defp range?(name) when is_binary(name) do
    Laev.Episodes.pack?(name) or Regex.match?(~r/\bS\d+[ ._-]?E\d+\s*[-–~]\s*E?\d+/i, name)
  end

  defp range?(_name), do: false

  defp names_season?(name, season) when is_binary(name) and is_integer(season),
    do:
      Regex.match?(
        ~r/(?<![A-Za-z0-9])S0?#{season}(?!\d)|\bseason[ ._]?0?#{season}(?!\d)/i,
        name
      )

  defp names_season?(_name, _season), do: false

  defp probe_opts(opts, %{anime: true} = ctx), do: Keyword.put(opts, :ctx, ctx)

  defp probe_opts(opts, ctx),
    do: opts |> Keyword.put(:ctx, ctx) |> Keyword.put(:season, ctx.season)

  defp needs_reencode(source, {:ok, stream} = result, caps) do
    cond do
      source.codec != nil ->
        result

      String.ends_with?(String.downcase(stream.filename || ""), [".mp4", ".m4v", ".webm"]) ->
        result

      true ->
        if Watch.light_video?(stream, caps) == false, do: {:error, :needs_reencode}, else: result
    end
  end

  defp needs_reencode(_source, result, _caps), do: result

  # Once enough releases play — five, or at least one for three seconds — the slowest ones are not
  # waited for: they go back to the unchecked list ("Load more"), and the answer comes at once.
  # (Eight releases used to take as long as the slowest of them, often twice the rest.)
  @enough 8
  @grace_ms 6_000
  # Starting to play wants one release that works, not a list: it stops sooner.
  @quick_enough 4
  @quick_grace_ms 1_000

  defp ideal?(source), do: source.resolution == "1080p" and not Roki.Watch.heavy?(source)

  defp await_probes(task, agent, page, parent, token, first_ok_at, quick?, deadline) do
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

        # Four that play, or one that is already what would be picked (a 1080p release a browser
        # reads as it is) — no point waiting for more — or one that played a moment ago.
        ideal? = quick? and Enum.any?(st.ok, fn {_i, source, _stream} -> ideal?(source) end)
        enough = if quick?, do: @quick_enough, else: @enough
        grace = if quick?, do: @quick_grace_ms, else: @grace_ms

        if now >= deadline do
          Task.shutdown(task, :brutal_kill)
          seen = MapSet.new(st.seen)

          for s <- page,
              not MapSet.member?(seen, s.hash),
              do: send(parent, {:checked, token, s.hash, {:bad, "no answer in time"}})

          []
        else
          check_enough(
            task,
            agent,
            page,
            parent,
            token,
            first,
            quick?,
            deadline,
            st,
            ok,
            now,
            enough,
            grace,
            ideal?
          )
        end
    end
  end

  defp check_enough(
         task,
         agent,
         page,
         parent,
         token,
         first,
         quick?,
         deadline,
         st,
         ok,
         now,
         enough,
         grace,
         ideal?
       ) do
    if ok >= enough or ideal? or (first && now - first >= grace) do
      Task.shutdown(task, :brutal_kill)
      seen = MapSet.new(st.seen)
      late = Enum.reject(page, &MapSet.member?(seen, &1.hash))
      for s <- late, do: send(parent, {:checked, token, s.hash, {:later, "not waited for"}})
      late
    else
      await_probes(task, agent, page, parent, token, first, quick?, deadline)
    end
  end

  @doc "What to choose with nobody asked: the release that started last time, else the best."
  def pick(playable, cap, good, mode, caps \\ %{}) do
    # The release that worked last time goes first — unless it is above what this player takes:
    # a 4K one opened in an external player is not what the browser should be handed.
    known =
      Enum.find(playable, fn {source, _} ->
        good && source.hash == good && Laev.Sources.resolution_at_most?(source.resolution, cap)
      end)

    case known do
      nil when mode == :external -> Watch.auto_choice_external(playable, cap)
      nil -> Watch.auto_choice(playable, cap, caps)
      pair -> {:play, pair}
    end
  end

  @doc "The release with this info hash, if it is among those that play."
  def find(playable, hash) when is_binary(hash),
    do: Enum.find(playable, fn {source, _} -> source.hash == hash end)

  def find(_playable, _hash), do: nil

  # What to tell the user when it did not work.
  def failure(:no_provider),
    do: "No debrid account is connected. Add a Real-Debrid or TorBox key in Settings."

  def failure({:expired, detail}),
    do: "Your debrid subscription isn't active — #{detail}. Renew it, then try again."

  def failure(:no_sources), do: "No releases were found for this."

  def failure(:none_playable) do
    if Roki.Study.active?(),
      do:
        "No 1080p release with the audio in the language you chose was found for this one. Try another episode, or another language.",
      else:
        "None of the releases found can be played right now. Try again later, or another episode."
  end

  def failure({:above_ceiling, n, cap}),
    do:
      "Nothing at #{label(cap)} or below — #{n} found above it. (Settings → only list sources within the ceiling.)"

  def failure({:too_big, n, gb}),
    do:
      "Every release found (#{n}) is above the #{gb} GB limit for the browser player. (Settings → size limit, or use the external player.)"

  def failure({:too_big_one, size, gb}),
    do: "That release is #{size} GB — above the #{gb} GB limit for the browser player. (Settings → size limit, or use the external player.)"

  def failure(:too_heavy),
    do:
      "That release is 4K H.265 — this browser doesn't decode it, and converting it here is too slow. Pick a 1080p or H.264 release, or switch to the external player."

  def failure(:busy),
    do:
      "The server is re-encoding other videos right now. Try again in a minute, or pick an h264 release."

  def failure({:busy, holders}) when is_list(holders) and holders != [] do
    who =
      Enum.map_join(holders, "; ", fn h ->
        "#{h.username}: #{h.title}#{if h.release, do: " (#{String.slice(h.release, 0, 70)})"}"
      end)

    "The server is re-encoding other videos right now — #{who}. Try again in a minute, or pick an h264 release."
  end

  def failure({:busy, _}), do: failure(:busy)

  def failure(:search_failed),
    do: "The sites that list releases did not answer in time. Try again in a moment."

  def failure(:no_light),
    do:
      "No release was found that the browser can play without the server re-encoding it. Use an external player (VLC, mpv)."

  def failure(:only_heavy),
    do:
      "Every release found needs the server to re-encode the video (HEVC and similar), which isn't switched on for this account. Use an external player (VLC, mpv)."

  def failure(:needs_heavy),
    do:
      "That release needs the server to re-encode the video, which isn't switched on for this account. Pick an H.264 release, or use an external player (VLC, mpv)."

  def failure(:unreachable),
    do:
      "That release's download server isn't answering right now. Pick another release, or try again in a minute."

  def failure(:over_limit),
    do: "You have used today's plays. Try again tomorrow."

  def failure(:timeout),
    do: "Preparing the video took too long. Try again, or pick another release."

  def failure(other) when is_binary(other), do: other

  def failure(other),
    do: "Couldn't start that (#{inspect(other, limit: 3, printable_limit: 80)})."

  def label("2160p"), do: "4K"
  def label(r), do: r
end
