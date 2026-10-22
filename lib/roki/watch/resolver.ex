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
  def run(parent, token, uuid, title, season, episode, force?, mode) do
    key = key(title.type, title.id, season, episode)
    web = Roki.Laev.web_settings(uuid)
    hours = SourceCache.hours(web)
    cached = if force?, do: nil, else: SourceCache.get(uuid, key, hours)

    with :ok <- Watch.subscription(uuid),
         ctx = Watch.ctx(uuid, title, season, episode),
         cap = Watch.ceiling(uuid, ctx, mode, web),
         {:ok, res} <-
           from_cache(token, ctx, cap, key, cached)
           |> fresh_if_none(fn ->
             search(parent, token, uuid, title, season, episode, ctx, cap, key, hours, force?)
           end) do
      {:ok, res}
    else
      {:error, reason} -> {:error, token, reason}
    end
  end

  @doc "Check the next page of unchecked releases: `{:ok, token, playable, rest}`."
  def more(parent, token, uuid, ctx, rest, have, key, hours) do
    {page, rest} = Watch.probe_page(rest)
    playable = probe_page(parent, token, uuid, ctx, page)
    all = Watch.attach_and_rank(uuid, have ++ playable)
    if hours > 0, do: SourceCache.put(uuid, key, all, rest)
    {:ok, token, all, rest}
  end

  defp from_cache(_token, _ctx, _cap, _key, nil), do: nil

  defp from_cache(token, ctx, cap, key, entry) do
    {:ok,
     %{
       token: token,
       ctx: ctx,
       playable: entry.playable,
       rest: entry.rest,
       cap: cap,
       key: key,
       cached_at: entry.at,
       good: entry.good
     }}
  end

  defp fresh_if_none(nil, fun), do: fun.()
  defp fresh_if_none(hit, _fun), do: hit

  defp search(parent, token, uuid, title, season, episode, ctx, cap, key, hours, force?) do
    send(parent, {:status, token, "Searching for releases…"})

    with {:ok, %{query: query, sources: found}} <-
           Watch.sources(title, season, episode, uuid, force?),
         sources = Watch.with_library(uuid, query, found),
         {:ok, sources} <- within_ceiling(uuid, sources, cap),
         {:ok, playable, rest} <- probe_until_playable(parent, token, uuid, ctx, sources, []) do
      if hours > 0, do: SourceCache.put(uuid, key, playable, rest)

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

  defp probe_until_playable(_parent, _token, _uuid, _ctx, [], []), do: {:error, :none_playable}

  defp probe_until_playable(parent, token, uuid, ctx, sources, acc) do
    {page, rest} = Watch.probe_page(sources)
    playable = probe_page(parent, token, uuid, ctx, page)
    ranked = Watch.attach_and_rank(uuid, acc ++ playable)

    cond do
      ranked != [] -> {:ok, ranked, rest}
      rest == [] -> {:error, :none_playable}
      true -> probe_until_playable(parent, token, uuid, ctx, rest, [])
    end
  end

  # One round of probing, 8 releases two at a time. Each answer is counted on the page as it
  # arrives; the task keeps the ones that play.
  defp probe_page(parent, token, uuid, ctx, page) do
    {:ok, agent} = Agent.start_link(fn -> %{done: 0, ok: []} end)
    total = length(page)
    send(parent, {:probe, token, 0, 0, total})

    notify = fn {:result, idx, source, result} ->
      {done, ok} =
        Agent.get_and_update(agent, fn st ->
          ok =
            if match?({:ok, _}, result), do: [{idx, source, elem(result, 1)} | st.ok], else: st.ok

          st = %{st | done: st.done + 1, ok: ok}
          {{st.done, length(st.ok)}, st}
        end)

      send(parent, {:probe, token, done, ok, total})
    end

    opts =
      [notify: notify, episode: ctx.episode] ++ if(ctx.anime, do: [], else: [season: ctx.season])

    Roki.Laev.run(uuid, fn -> Laev.Providers.probe_sources(Enum.with_index(page), opts) end)

    ok = Agent.get(agent, & &1.ok)
    Agent.stop(agent)

    ok |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(fn {_i, source, stream} -> {source, stream} end)
  end

  @doc "What to choose with nobody asked: the release that started last time, else the best."
  def pick(playable, cap, good, mode) do
    case Enum.find(playable, fn {source, _} -> good && source.hash == good end) do
      nil when mode == :external -> Watch.auto_choice_external(playable, cap)
      nil -> Watch.auto_choice(playable, cap)
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

  def failure(:none_playable),
    do: "None of the releases found can be played right now. Try again later, or another episode."

  def failure({:above_ceiling, n, cap}),
    do:
      "Nothing at #{label(cap)} or below — #{n} found above it. (Settings → only list sources within the ceiling.)"

  def failure(:busy),
    do:
      "The server is re-encoding other videos right now. Try again in a minute, or pick an h264 release."

  def failure(:timeout),
    do: "Preparing the video took too long. Try again, or pick another release."

  def failure(other) when is_binary(other), do: other

  def failure(other),
    do: "Couldn't start that (#{inspect(other, limit: 3, printable_limit: 80)})."

  def label("2160p"), do: "4K"
  def label(r), do: r
end
