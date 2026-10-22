defmodule Roki.WatchTest do
  use ExUnit.Case, async: true

  alias Roki.Watch

  defp pair(name, resolution, codec, size \\ 4_000_000_000) do
    {%{
       name: name,
       resolution: resolution,
       codec: codec,
       size: size,
       cached: true,
       seeders: 10,
       langs: ["en"],
       subs: [],
       audio: nil,
       lang: "en",
       provider: nil,
       source: "BluRay"
     }, %{filename: name <> ".mkv", provider: :real_debrid}}
  end

  test "only h265 and av1 are re-encoded; h264 and unlabelled releases are copied" do
    assert Watch.heavy?(pair("a", "1080p", "h265"))
    assert Watch.heavy?(pair("a", "1080p", "av1"))
    refute Watch.heavy?(pair("a", "1080p", "h264"))
    refute Watch.heavy?(pair("a", "1080p", nil))
  end

  test "the automatic pick is the best release that needs no re-encoding" do
    hevc4k = pair("4k hevc", "2160p", "h265", 50_000_000_000)
    h264 = pair("1080 x264", "1080p", "h264", 9_000_000_000)

    assert {:play, ^h264} = Watch.auto_choice([hevc4k, h264], "2160p")
  end

  test "with nothing to copy, a re-encode is held to 1080p" do
    hevc4k = pair("4k hevc", "2160p", "h265", 50_000_000_000)
    hevc1080 = pair("1080 hevc", "1080p", "h265", 5_000_000_000)

    assert {:play, ^hevc1080} = Watch.auto_choice([hevc4k, hevc1080], "2160p")
  end

  test "language codes become names, unknown ones are shown upper-case" do
    assert Watch.language("fre") == "French"
    assert Watch.language("tlh") == "TLH"
    assert Watch.language(nil) == "Unknown"
  end

  test "the browser is capped at its own resolution, an external player is not" do
    web = %{"browser_max_resolution" => "1080p"}

    assert Watch.device_cap("2160p", :browser, web) == "1080p"
    assert Watch.device_cap("2160p", :external, web) == "2160p"
    assert Watch.device_cap("720p", :browser, web) == "720p"
    assert Watch.device_cap(nil, :browser, web) == "1080p"
    assert Watch.device_cap("2160p", :browser, %{"browser_max_resolution" => "720p"}) == "720p"
  end
end
