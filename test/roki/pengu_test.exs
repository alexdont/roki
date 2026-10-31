defmodule Roki.PenguTest do
  use ExUnit.Case, async: false

  alias Roki.Pengu

  @streams [
    %{"name" => "✨ | support the project!", "externalUrl" => "https://pengu.uk/donate"},
    %{
      "url" => "https://pengu.uk/direct/external/a/movie.mkv?psig=1",
      "name" => "🐧 PenguPlay ❄️ 4K • 2Peckle",
      "description" => "🍿 The Matrix (1999)\n🎞️ 4K • MKV • BluRay\n🛰️ Source: 2Peckle\n💾 35.09 GB",
      "behaviorHints" => %{"filename" => "x.mkv"}
    },
    %{
      "url" => "https://pengu.uk/hls/cinejoy/playlist/g/index.m3u8?psig=1",
      "name" => "🐧 PenguPlay 1080p • Cinejoy · secret",
      "description" => "🎞️ 1080p • HLS\n🛰️ Source: Cinejoy · secret\n🎧 Audio: English, Portuguese",
      "behaviorHints" => %{"proxyHeaders" => %{"request" => %{"Referer" => "https://cinejoy.pk/"}}},
      "subtitles" => [%{"url" => "https://x/s.vtt", "lang" => "eng"}]
    },
    %{
      "url" => "https://pengu.uk/direct/external/a/movie.mkv?psig=1",
      "name" => "dupe",
      "description" => "🛰️ Source: 2Peckle"
    }
  ]

  test "parse drops entries without a url and duplicates" do
    assert [%{provider: "2Peckle"}, %{provider: "Cinejoy"}] = Pengu.parse(@streams)
  end

  test "parse reads quality, language, size, kind, headers and subtitles" do
    [file, hls] = Pengu.parse(@streams)
    assert %{quality: "4K", size: "35.09 GB", kind: :file, language: ""} = file
    assert %{quality: "1080P", language: "English, Portuguese", kind: :hls} = hls
    assert hls.headers == %{"Referer" => "https://cinejoy.pk/"}
    assert hls.subtitles == [%{url: "https://x/s.vtt", lang: "eng"}]
  end

  test "parse names a stream by its file, else by its format line" do
    [file, hls] = Pengu.parse(@streams)
    assert file.name == "x.mkv"
    assert hls.name == "1080p • HLS"
  end

  describe "best/3" do
    defp st(attrs), do: Map.merge(%{id: "x", provider: "Z", quality: "1080P", language: "", size: "2 GB", codec: :other}, attrs)

    test "prefers 1080p over 4K, and a player-friendly provider on a tie" do
      streams = [
        st(%{id: "a", quality: "4K"}),
        st(%{id: "b", provider: "VidLink"}),
        st(%{id: "c", provider: "Arctic"})
      ]

      assert Pengu.best(streams).id == "c"
    end

    test "leaves out HEVC unless the browser decodes it, and anything already tried" do
      streams = [st(%{id: "h", codec: :hevc, provider: "Arctic"}), st(%{id: "o", provider: "VidLink"})]
      assert Pengu.best(streams).id == "o"
      assert Pengu.best(streams, %{hevc: true}).id == "h"
      assert Pengu.best(streams, %{}, ["o"]) == nil
    end

    test "English (or unlabelled) audio beats another language" do
      streams = [st(%{id: "es", language: "Spanish", provider: "Arctic"}), st(%{id: "en", language: "English, Hindi"})]
      assert Pengu.best(streams).id == "en"
    end
  end

  test "a stream's subtitles live under an id the stream controller accepts" do
    assert Laev.Remux.valid_id?(Roki.Watch.pengu_play_id("M2gdgS143b8H8Kk-"))
    refute Roki.Watch.pengu_play_id("a") == Roki.Watch.pengu_play_id("b")
  end

  test "group puts the provider with the best quality first" do
    assert [{"2Peckle", _}, {"Cinejoy", _}] = @streams |> Pengu.parse() |> Pengu.group()
  end

  test "streams without a title id or a configured addon say why" do
    old = Application.get_env(:roki, :pengu_addon_url)
    Application.delete_env(:roki, :pengu_addon_url)
    on_exit(fn -> if old, do: Application.put_env(:roki, :pengu_addon_url, old) end)

    assert {:error, :no_imdb_id} = Pengu.streams(nil)
    assert {:error, :not_configured} = Pengu.streams("tt0133093")
  end
end
