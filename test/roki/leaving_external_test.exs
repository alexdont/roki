defmodule Roki.LeavingExternalTest do
  @moduledoc "What Next does after an external player: mark the episode once, and only if a player was opened for it."
  use Roki.DataCase, async: false

  alias Roki.Watch

  @uuid "01a16aef-0000-7000-8000-0000000000f2"

  setup do
    dir = Path.join(System.tmp_dir!(), "roki-leaving-#{System.unique_integer([:positive])}")
    prior = Application.get_env(:roki, :laev_dir)
    Application.put_env(:roki, :laev_dir, dir)
    File.mkdir_p!(Roki.Laev.dir(@uuid))

    on_exit(fn ->
      if prior,
        do: Application.put_env(:roki, :laev_dir, prior),
        else: Application.delete_env(:roki, :laev_dir)

      File.rm_rf(dir)
    end)

    :ok
  end

  defp ctx(episode),
    do: %{type: "tv", tmdb_id: 4242, season: 1, episode: episode, mal_id: nil}

  defp opened(episode) do
    Roki.Laev.run(@uuid, fn ->
      Laev.Resume.put("tv", 4242, %{
        "type" => "tv",
        "tmdb_id" => 4242,
        "season" => 1,
        "episode" => episode,
        "title" => "Show",
        "updated_at" => 1,
        "source" => %{
          "name" => "Show.S01.1080p",
          "magnet" => "magnet:?xt=urn:btih:abc",
          "hash" => "abc"
        }
      })
    end)
  end

  test "a player was opened for the episode the resume entry points at" do
    assert Watch.opened_externally?(@uuid, ctx(3)) == false
    opened(3)
    assert Watch.opened_externally?(@uuid, ctx(3))
    refute Watch.opened_externally?(@uuid, ctx(4))
  end

  test "marking once: the first press marks, a second finds it already marked" do
    refute Roki.Laev.run(@uuid, fn -> Laev.Position.finished?(ctx(3)) end)
    assert :already != Watch.mark_watched_once(@uuid, ctx(3))
    assert Roki.Laev.run(@uuid, fn -> Laev.Position.finished?(ctx(3)) end)
    assert :already = Watch.mark_watched_once(@uuid, ctx(3))
  end
end
