defmodule RokiWeb.WatchFlowTest do
  use RokiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Roki.Watch
  alias Roki.Watch.Resolver

  @uuid "01a163a7-a312-7691-8440-db7feaca900f"

  describe "the pages" do
    test "a film's sources page and player page ask a visitor to log in", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/sources/movie/603")
      assert html =~ "Log in"
      assert html =~ "Sources"

      {:ok, _view, html} = live(conn, "/watch/movie/603?h=abc")
      assert html =~ "Log in"
    end

    test "an episode has its own sources and player address", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/sources/tv/1396/2/5")
      assert html =~ "S2E5"

      {:ok, _view, html} = live(conn, "/watch/tv/1396/2/5")
      assert html =~ "Log in"
    end

    test "nonsense in the address goes home", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/sources/movie/abc")
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/watch/movie/x")
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/sources/tv/1/a/b")
    end

    test "a series has an episodes page of its own", %{conn: conn} do
      assert {:ok, _view, _html} = live(conn, "/title/tv/1396/episodes")
      assert {:ok, _view, _html} = live(conn, "/title/movie/603")
    end
  end

  describe "choosing" do
    defp pair(hash, resolution),
      do:
        {%{
           name: hash,
           hash: hash,
           resolution: resolution,
           codec: "h264",
           size: 1,
           cached: true,
           seeders: 1,
           langs: ["en"],
           subs: [],
           lang: "en",
           source: "BluRay"
         }, %{filename: hash <> ".mkv"}}

    test "a release is found by its info hash, and only if it plays" do
      playable = [pair("aaa", "1080p"), pair("bbb", "720p")]
      assert {%{hash: "bbb"}, _} = Resolver.find(playable, "bbb")
      assert Resolver.find(playable, "ccc") == nil
      assert Resolver.find(playable, nil) == nil
    end

    test "with nobody asked, the release that started last time goes first" do
      playable = [pair("aaa", "1080p"), pair("bbb", "720p")]
      assert {:play, {%{hash: "bbb"}, _}} = Resolver.pick(playable, "1080p", "bbb", :browser)
      assert {:play, {%{hash: "aaa"}, _}} = Resolver.pick(playable, "1080p", nil, :browser)
    end

    test "the release that worked last time is not handed to a player that cannot take it" do
      uhd = pair("uhd", "2160p")
      hd = pair("hd", "1080p")

      assert {:play, {%{hash: "uhd"}, _}} = Resolver.pick([uhd, hd], "2160p", "uhd", :external)
      assert {:play, {%{hash: "hd"}, _}} = Resolver.pick([uhd, hd], "1080p", "uhd", :browser)
    end

    test "failures are said in words, resolutions as people say them" do
      assert Resolver.failure(:none_playable) =~ "None of the releases"
      assert Resolver.failure({:above_ceiling, 3, "2160p"}) =~ "4K"
      assert Resolver.label("1080p") == "1080p"
    end
  end

  describe "starting by itself" do
    setup do
      dir = Path.join(System.tmp_dir!(), "roki-flow-test-#{System.unique_integer([:positive])}")
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

    test "on unless laev's auto-pick is set to off" do
      assert Watch.auto_start?(@uuid)
      File.write!(Path.join(Roki.Laev.dir(@uuid), "config"), "LAEV_AUTO_SOURCE=off\n")
      refute Watch.auto_start?(@uuid)
      File.write!(Path.join(Roki.Laev.dir(@uuid), "config"), "LAEV_AUTO_SOURCE=on\n")
      assert Watch.auto_start?(@uuid)
    end
  end
end
