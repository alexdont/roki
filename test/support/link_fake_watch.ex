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
