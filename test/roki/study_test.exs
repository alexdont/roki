defmodule Roki.StudyTest do
  use ExUnit.Case, async: true

  @uuid "01a16fe0-eda3-735c-9f24-055a0d6980f9"

  setup do
    dir = Path.join(System.tmp_dir!(), "roki-study-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:roki, :laev_dir)
    Application.put_env(:roki, :laev_dir, dir)

    on_exit(fn ->
      File.rm_rf!(dir)

      if previous,
        do: Application.put_env(:roki, :laev_dir, previous),
        else: Application.delete_env(:roki, :laev_dir)
    end)
  end

  test "a choice is remembered per title" do
    assert Roki.Study.get(@uuid, "tv", 96677) == nil
    :ok = Roki.Study.put(@uuid, "tv", 96677, "FR", " fr ")
    assert Roki.Study.get(@uuid, "tv", 96677) == %{"lang" => "fr", "subs" => "fr"}
    assert Roki.Study.get(@uuid, "tv", 1) == nil
    assert Roki.Study.get(@uuid, "movie", 96677) == nil
  end

  test "overrides replace the account's languages inside its scope only" do
    ov = Roki.Study.overrides(%{"lang" => "fr", "subs" => "off"})
    assert ov == %{lang: "fr", subs_lang: "off"}
    assert Roki.Study.overrides(nil) == %{}

    Roki.Study.bind(ov)
    assert Roki.Study.active?()

    assert Roki.Laev.run(@uuid, fn -> {Laev.Config.lang(), Laev.Config.subs_lang()} end) ==
             {"fr", nil}

    # Another process does not inherit it, unless it is wrapped.
    assert Task.async(fn -> Roki.Study.active?() end) |> Task.await() == false
    assert Task.async(Roki.Study.wrap(fn -> Roki.Study.active?() end)) |> Task.await() == true

    Roki.Study.bind(%{})
    refute Roki.Study.active?()
  end
end
