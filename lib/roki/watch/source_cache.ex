defmodule Roki.Watch.SourceCache do
  @moduledoc """
  The releases found, checked and ranked for a film or an episode, kept for hours so the next
  Play does not search and probe again. Per user (the playable links belong to their debrid
  account), on disk beside their laev state so it survives a restart and goes when they
  disconnect.

  An entry is `%{at:, playable: [{source, stream}], rest: [source], good: hash | nil}`:
  `good` is the release that last actually started, which the next Play goes straight to.
  Entries older than the user's setting (`Roki.Laev.web_settings/1` → `sources_cache`, 12 hours
  by default, 0 = off) are not served and are deleted when seen.
  """

  # Bumped when what is stored changes meaning; older entries are not served. (2: a pack is only
  # playable if the file picked in it really is the episode — earlier lists could hold the wrong one.)
  @version 2

  def hours(web) do
    # A study session finds releases for its own languages: neither read from nor saved in the
    # list kept for the account's settings.
    if Roki.Study.active?(), do: 0, else: configured_hours(web)
  end

  defp configured_hours(web) do
    case web["sources_cache"] do
      "off" -> 0
      h when is_binary(h) -> String.to_integer(h)
      _ -> 12
    end
  end

  @doc "The entry for `key` (`{type, id, season, episode}`) if it is younger than `hours`."
  def get(uuid, key, hours) when hours > 0 do
    with {:ok, bin} <- File.read(path(uuid, key)),
         %{at: at} = entry <- :erlang.binary_to_term(bin, [:safe]),
         @version <- Map.get(entry, :v),
         true <- now() - at < hours * 3600 do
      entry
    else
      _ ->
        File.rm(path(uuid, key))
        nil
    end
  rescue
    _ -> nil
  end

  def get(_uuid, _key, _hours), do: nil

  def put(uuid, key, playable, rest) do
    write(uuid, key, %{at: now(), v: @version, playable: playable, rest: rest, good: nil})
  end

  @doc "Remember which release started, so the next Play goes straight to it."
  def mark_good(uuid, key, hash) do
    with {:ok, bin} <- File.read(path(uuid, key)),
         %{} = entry <- :erlang.binary_to_term(bin, [:safe]) do
      write(uuid, key, %{entry | good: hash})
    end

    :ok
  rescue
    _ -> :ok
  end

  def delete(uuid, key), do: File.rm(path(uuid, key)) && :ok

  @doc "Everything cached and still fresh: a `MapSet` of `{type, id, season, episode}`."
  def keys(uuid, hours) when hours > 0 do
    dir = dir(uuid)
    cutoff = now() - hours * 3600

    case File.ls(dir) do
      {:ok, names} ->
        for name <- names,
            {:ok, %{mtime: m}} <- [File.stat(Path.join(dir, name), time: :posix)],
            m >= cutoff,
            key = parse(name),
            key != nil,
            into: MapSet.new(),
            do: key

      _ ->
        MapSet.new()
    end
  end

  def keys(_uuid, _hours), do: MapSet.new()

  # ── files ──────────────────────────────────────────────────────────

  defp dir(uuid), do: Path.join(Roki.Laev.dir(uuid), "roki-sources")

  defp path(uuid, {type, id, season, episode}),
    do: Path.join(dir(uuid), "#{type}-#{id}-#{season || 0}-#{episode || 0}.etf")

  defp write(uuid, key, entry) do
    File.mkdir_p!(dir(uuid))
    File.write!(path(uuid, key), :erlang.term_to_binary(entry))
    :ok
  end

  defp parse(name) do
    case Regex.run(~r/^(movie|tv)-(\d+)-(\d+)-(\d+)\.etf$/, name) do
      [_, type, id, s, e] ->
        {type, String.to_integer(id), nilify(s), nilify(e)}

      _ ->
        nil
    end
  end

  defp nilify("0"), do: nil
  defp nilify(n), do: String.to_integer(n)

  defp now, do: System.os_time(:second)
end
