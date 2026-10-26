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

  test "a browser that decodes HEVC at 4K is handed the 4K release" do
    hevc4k = pair("4k hevc", "2160p", "h265", 50_000_000_000)
    h264 = pair("1080 x264", "1080p", "h264", 9_000_000_000)
    caps = %{hevc: true, av1: false, vp9: false, uhd: true}

    assert {:play, ^hevc4k} = Watch.auto_choice([hevc4k, h264], "2160p", caps)
    # Held to the account's own cap all the same.
    assert {:play, ^h264} = Watch.auto_choice([hevc4k, h264], "1080p", caps)
  end

  test "the browser ceiling is 4K only on a device that decodes it, and never above the setting" do
    assert Watch.browser_limit(%{}, %{uhd: true}) == "2160p"
    assert Watch.browser_limit(%{}, %{hevc: true}) == "1080p"
    assert Watch.browser_limit(%{}, %{}) == "1080p"
    assert Watch.browser_limit(%{"browser_max_resolution" => "720p"}, %{uhd: true}) == "720p"
    assert Watch.browser_limit(%{"browser_max_resolution" => "1080p"}, %{uhd: true}) == "1080p"
  end

  test "the browser size limit leaves out what is above it, and says so when nothing is left" do
    small = pair("small", "1080p", "h264", 9_000_000_000)
    big = pair("remux", "2160p", "h265", 70_000_000_000)
    unknown = {%{elem(small, 0) | name: "unknown", size: nil}, elem(small, 1)}
    {small_s, _} = small
    {big_s, _} = big
    {unknown_s, _} = unknown

    cap = Watch.size_cap(%{})
    assert cap == 40 * 1_073_741_824
    assert Watch.size_cap(%{"browser_max_size" => "off"}) == nil
    assert {:ok, [^small_s, ^unknown_s]} = Watch.within_size([small_s, big_s, unknown_s], cap)
    assert {:error, {:too_big, 1, 40}} = Watch.within_size([big_s], cap)
    assert {:ok, [^big_s]} = Watch.within_size([big_s], nil)
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

  test "a cap is the lower of a ceiling and a limit" do
    assert Watch.cap_to("2160p", "1080p") == "1080p"
    assert Watch.cap_to("720p", "1080p") == "720p"
    assert Watch.cap_to(nil, "1080p") == "1080p"
    assert Watch.cap_to("1080p", "1080p") == "1080p"
  end
end
