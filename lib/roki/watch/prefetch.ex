defmodule Roki.Watch.Prefetch do
  @moduledoc """
  Getting a release ready before it is asked for. Finding what plays takes seconds — searching,
  then checking releases one against the debrid account — and none of it depends on the person
  having pressed Play yet. So when someone opens a title (or is a little way into an episode),
  the next thing they are likely to play is resolved in the background; pressing Play then finds
  the answer already in their source cache (`Roki.Watch.SourceCache`) and goes straight to
  starting it.

  Once per title per few minutes, only for accounts that are set up and keep a source cache, and
  never anything that would show on screen.
  """

  alias Roki.TTLCache
  alias Roki.Watch.{Resolver, SourceCache}

  @every_s 300

  @doc "Resolve `title` (a film, or `season`/`episode` of a series) for this account in the background."
  def warm(uuid, title, season \\ nil, episode \\ nil)

  def warm(uuid, %{} = title, season, episode) when is_binary(uuid) do
    if Roki.Laev.connected?(uuid) and SourceCache.hours(Roki.Laev.web_settings(uuid)) > 0 do
      key = {:warm, uuid, title.type, title.id, season, episode}

      TTLCache.fetch(key, @every_s, fn ->
        Task.start(fn -> run(uuid, title, season, episode) end)
        {:ok, true}
      end)
    end

    :ok
  rescue
    _ -> :ok
  end

  def warm(_uuid, _title, _season, _episode), do: :ok

  # The resolver reports progress to a process; nobody is watching, so it is told to a sink.
  defp run(uuid, title, season, episode) do
    sink = spawn(fn -> sink() end)

    try do
      Resolver.run(sink, make_ref(), uuid, title, season, episode, false, :browser)
    after
      Process.exit(sink, :kill)
    end
  end

  defp sink do
    receive do
      _ -> sink()
    end
  end
end
