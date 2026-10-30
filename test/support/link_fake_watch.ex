# Stands in for Roki.Watch: episodes watched per account live in an Agent, so the rules
# in Roki.Link can be tried without TMDB or laev files.
defmodule Roki.LinkFakeWatch do
  def start, do: Agent.start_link(fn -> %{} end, name: __MODULE__)
  def stop, do: if(Process.whereis(__MODULE__), do: Agent.stop(__MODULE__))
  def put(uuid, pairs), do: Agent.update(__MODULE__, &Map.put(&1, uuid, MapSet.new(pairs)))
  def get(uuid), do: Agent.get(__MODULE__, &Map.get(&1, uuid, MapSet.new()))

  def title(_type, id, _uuid), do: {:ok, %{type: "tv", id: id, title: "Frieren"}}
  def watched_pairs(uuid, _title), do: get(uuid)

  # Seasons of 10 episodes; the show ends after season 2.
  def finale_facts(_uuid, _title, season), do: %{last: 10, series_end?: season == 2}

  def rate(uuid, _title, value, _entry) do
    Agent.update(
      __MODULE__,
      &Map.update(&1, :rated, %{uuid => value}, fn r -> Map.put(r, uuid, value) end)
    )
  end

  def episode_minutes(_uuid, _title, pairs), do: for({s, e} <- pairs, do: {s, e, 24})

  # Seasons of 10 episodes: the next one after the highest watched.
  def next_unwatched(uuid, _title) do
    case get(uuid) |> MapSet.to_list() |> Enum.max(fn -> nil end) do
      nil -> %{season: 1, episode: 1, name: "Episode 1"}
      {s, 10} -> %{season: s + 1, episode: 1, name: "Episode 1"}
      {s, e} -> %{season: s, episode: e + 1, name: "Episode #{e + 1}"}
    end
  end

  # Like Roki.Watch.set_watched/6: mark it, then carry it to the link.
  def set_watched(uuid, title, season, episode, true, opts \\ []) do
    Agent.update(__MODULE__, fn m ->
      Map.update(m, uuid, MapSet.new([{season, episode}]), &MapSet.put(&1, {season, episode}))
    end)

    Roki.Link.mirror(uuid, title.id, [{season, episode}], opts)
  end

  def rated(uuid), do: Agent.get(__MODULE__, &(Map.get(&1, :rated, %{}) |> Map.get(uuid)))

  def set_many_watched(uuid, _title, pairs, watched?, opts) do
    true = opts[:mirrored]

    Agent.update(__MODULE__, fn m ->
      cur = Map.get(m, uuid, MapSet.new())
      set = MapSet.new(pairs)

      Map.put(
        m,
        uuid,
        if(watched?, do: MapSet.union(cur, set), else: MapSet.difference(cur, set))
      )
    end)
  end
end
