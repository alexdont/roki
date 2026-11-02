defmodule Roki.ForgetProgressTest do
  use Roki.DataCase, async: false

  alias Roki.Watch

  @uuid "01a16aef-0000-7000-8000-0000000000f1"

  setup do
    dir = Path.join(System.tmp_dir!(), "roki-forget-test-#{System.unique_integer([:positive])}")
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

  defp play(type, id, position, finished?) do
    Roki.Laev.run(@uuid, fn ->
      ctx = %{type: type, tmdb_id: id, season: nil, episode: nil, mal_id: nil}

      Laev.Resume.put(type, id, %{
        "type" => type,
        "tmdb_id" => id,
        "title" => "T#{id}",
        "updated_at" => 1
      })

      Laev.Position.record(ctx, %{
        position: position,
        duration: 7000,
        watched: position,
        skipped: 0,
        finished: finished?,
        log_seconds: 0,
        reported: position
      })
    end)
  end

  defp state(type, id) do
    Roki.Laev.run(@uuid, fn ->
      ctx = %{type: type, tmdb_id: id}
      {Laev.Resume.get(type, id), Laev.Position.saved_position(ctx), Laev.Position.finished?(ctx)}
    end)
  end

  test "a film that was only started loses its place and its saved spot" do
    play("movie", 9001, 1500, false)
    assert {%{}, 1500, false} = state("movie", 9001)

    assert :ok = Watch.forget_progress(@uuid, "movie", 9001)
    assert {nil, nil, false} = state("movie", 9001)
  end

  test "a film watched to the end keeps its mark: only its place in History goes" do
    play("movie", 9002, 6900, true)
    assert {%{}, _, true} = state("movie", 9002)

    assert :ok = Watch.forget_progress(@uuid, "movie", 9002)
    assert {nil, _, true} = state("movie", 9002)
  end

  test "another title's progress is not touched" do
    play("movie", 15, 1000, false)
    play("movie", 150, 2000, false)

    assert :ok = Watch.forget_progress(@uuid, "movie", 15)
    assert {nil, nil, false} = state("movie", 15)
    assert {%{}, 2000, false} = state("movie", 150)
  end

  test "the library says whether a title has progress to remove" do
    title = %{
      type: "movie",
      id: 9003,
      anime?: false,
      title: "T9003",
      year: "2020",
      poster_path: nil,
      search: nil
    }

    assert %{progress?: false} = Watch.library(@uuid, title)

    play("movie", 9003, 1200, false)
    assert %{progress?: true} = Watch.library(@uuid, title)

    Watch.forget_progress(@uuid, "movie", 9003)
    assert %{progress?: false} = Watch.library(@uuid, title)
  end
end
