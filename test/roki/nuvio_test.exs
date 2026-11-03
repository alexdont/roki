defmodule Roki.NuvioTest do
  use RokiWeb.ConnCase, async: false

  alias Roki.Nuvio
  alias Roki.Nuvio.{Provider, Registry, Settings, Validator}
  alias RokiWeb.{NuvioController, Relay}

  @manifest_url "https://raw.githubusercontent.com/D3adlyRocket/All-in-One-Nuvio/refs/heads/main/manifest.json"

  @entry %{
    "id" => "example",
    "name" => "Example",
    "description" => "an example",
    "version" => "1.0.0",
    "author" => "someone",
    "supportedTypes" => ["movie", "tv"],
    "filename" => "providers/example.js",
    "enabled" => true,
    "hasSettings" => true,
    "formats" => ["m3u8"],
    "contentLanguage" => ["en"]
  }

  test "a manifest entry becomes a provider with a source on the manifest's own host" do
    assert {:ok, provider} = Provider.from_manifest(@entry, @manifest_url)
    assert provider.id == "example"
    assert Provider.supports?(provider, "movie")
    assert Provider.supports?(provider, "tv")

    assert provider.source_url ==
             "https://raw.githubusercontent.com/D3adlyRocket/All-in-One-Nuvio/refs/heads/main/providers/example.js"
  end

  test "a manifest cannot point at traversal, an absolute URL or a non-JS file" do
    for filename <- [
          "../secret.js",
          "/etc/passwd",
          "providers/../../x.js",
          "providers/x.txt",
          "providers\\x.js"
        ] do
      assert {:error, _} =
               Provider.from_manifest(Map.put(@entry, "filename", filename), @manifest_url)
    end
  end

  test "parse_manifest keeps the valid entries and reports the invalid ones" do
    manifest = %{
      "name" => "test",
      "scrapers" => [@entry, Map.merge(@entry, %{"id" => "bad", "filename" => "../bad.js"})]
    }

    assert {:ok, result} = Registry.parse_manifest(manifest, @manifest_url)
    assert [%Provider{id: "example"}] = result.providers
    assert [{"bad", _}] = result.errors
  end

  test "the validator accepts a self-contained getStreams provider" do
    source = "module.exports = { getStreams: function () { return []; } };"
    assert :ok = Validator.check(source)
    assert Validator.verification(source) == :clear
  end

  test "the validator allows only the vendored modules and safe built-ins" do
    source = """
    var cheerio = require("cheerio-without-node-native");
    var CryptoJS = require("crypto-js");
    var crypto = require("node:crypto");
    module.exports = { getStreams: function(){ return []; } };
    """

    assert :ok = Validator.check(source)
  end

  test "the validator rejects raw modules, dynamic requires, eval and host capabilities" do
    for source <- [
          ~s|var fs = require("fs"); module.exports = { getStreams: function(){} };|,
          ~s|var http = require("http"); module.exports = { getStreams: function(){} };|,
          ~s|var name = "cheerio"; var x = require(name); module.exports = { getStreams: function(){} };|,
          ~s|module.exports = { getStreams: function(){ return eval("1") } };|,
          ~s|module.exports = { getStreams: function(){ return process.env } };|,
          ~s|module.exports = { getStreams: function(){ return fetch("http://x") } };|,
          ~s|module.exports = { getStreams: function(){ return document.cookie } };|
        ] do
      assert {:error, reasons} = Validator.check(source)
      assert is_list(reasons) and reasons != []
    end
  end

  test "an obfuscated provider is marked as such" do
    source =
      "var _0xabc1=1,_0xabc2=2,_0xabc3=3,_0xabc4=4,_0xabc5=5,_0xabc6=6,_0xabc7=7,_0xabc8=8;" <>
        "module.exports={getStreams:function(){return []}}"

    assert Validator.verification(source) == :obfuscated
  end

  describe "normalising a provider answer" do
    test "keeps a public https stream and reads its hints" do
      raw = %{
        "name" => "Example 1080p",
        "title" => "Movie\n💾 2.1 GB\n🎧 English",
        "url" => "https://cdn.example.com/a/index.m3u8?token=x",
        "quality" => "1080p",
        "headers" => %{"Referer" => "https://example.com/", "Host" => "bad"},
        "behaviorHints" => %{
          "filename" => "a.m3u8",
          "proxyHeaders" => %{"request" => %{"User-Agent" => "Roki"}}
        },
        "subtitles" => [%{"url" => "https://cdn.example.com/a/en.vtt", "lang" => "en"}]
      }

      assert %{} = stream = Nuvio.normalize("example", raw)
      assert stream.kind == :hls
      assert stream.quality == "1080P"
      assert stream.size == "2.1 GB"
      assert stream.language == ""
      assert stream.headers == %{"Referer" => "https://example.com/", "User-Agent" => "Roki"}
      assert [%{url: "https://cdn.example.com/a/en.vtt", lang: "en"}] = stream.subtitles
      assert String.length(stream.id) == 16
      assert Nuvio.normalize("example", raw).id == stream.id
    end

    test "drops magnets, http, private addresses and blank rows" do
      for url <- [
            "magnet:?xt=urn:btih:abc",
            "http://example.com/a.m3u8",
            "https://127.0.0.1/a.m3u8",
            "https://192.168.1.2/a.m3u8",
            "https://localhost/a.m3u8",
            ""
          ] do
        assert Nuvio.normalize("example", %{"url" => url}) == nil
      end
    end

    test "strips zero-width sorting tags from provider names" do
      raw = %{
        "name" => "﻿​﻿﻿1Shows • 1080p",
        "url" => "https://cdn.example.com/a.mkv"
      }

      assert Nuvio.normalize("1shows", raw).name == "1Shows • 1080p"
    end
  end

  test "best prefers 1080p, English, and leaves out a codec the browser cannot decode" do
    streams = [
      stream("a", "4K", "", :other),
      stream("b", "1080P", "Spanish", :other),
      stream("c", "720P", "English", :other),
      stream("d", "1080P", "English", :hevc)
    ]

    assert Nuvio.best(streams).id == "c"
    assert Nuvio.best(streams, %{hevc: true}).id == "d"
    assert Nuvio.best(streams, %{}, ["c", "a"]).id == "b"
  end

  defp stream(id, quality, language, codec) do
    %{
      id: id,
      provider_id: "p",
      provider: "P",
      name: id,
      label: id,
      quality: quality,
      language: language,
      size: "1 GB",
      codec: codec,
      url: "https://example.com/#{id}",
      kind: :file,
      headers: %{},
      subtitles: []
    }
  end

  test "the sandbox runs a self-contained provider and returns its streams" do
    if Roki.Nuvio.Sandbox.available?() do
      source = """
      module.exports = {
        getStreams: function (id, type, season, episode) {
          return [{ name: "Example", url: "https://cdn.example.com/a.m3u8", quality: "1080p" }];
        }
      };
      """

      assert {:ok, %{"streams" => [stream]}} =
               Roki.Nuvio.Sandbox.run(source, [603, "movie", nil, nil], %{})

      assert stream["url"] == "https://cdn.example.com/a.m3u8"
    end
  end

  test "the sandbox can provide the reviewed cheerio and crypto-js bundles" do
    if Roki.Nuvio.Sandbox.available?() do
      source = """
      var cheerio = require("cheerio-without-node-native");
      var CryptoJS = require("crypto-js");
      module.exports = {
        getStreams: function () {
          var $ = cheerio.load("<div class='x'>hello</div>");
          return [{
            name: $(".x").text() + " " + CryptoJS.MD5("x").toString(),
            url: "https://cdn.example.com/a.mkv"
          }];
        }
      };
      """

      assert {:ok, %{"streams" => [stream]}} =
               Roki.Nuvio.Sandbox.run(source, [603, "movie"], %{})

      assert stream["name"] =~ ~r/^hello [0-9a-f]{32}$/
    end
  end

  test "the sandbox kills a provider that never returns" do
    if Roki.Nuvio.Sandbox.available?() do
      source = "module.exports = { getStreams: function () { while (true) {} } };"
      assert {:error, :timeout} = Roki.Nuvio.Sandbox.run(source, [1, "movie"], %{}, timeout: 300)
    end
  end

  describe "account settings" do
    setup do
      {:ok, user} =
        PhoenixKit.Users.Auth.register_user(%{
          "email" => "nuvio-#{System.unique_integer([:positive])}@example.com",
          "password" => "a-long-enough-password-123",
          "username" => "nuvio#{System.unique_integer([:positive])}"
        })

      {:ok, user: user}
    end

    test "every account starts with the default providers on", %{user: user} do
      assert Settings.enabled_ids(user.uuid) == Settings.defaults()
      assert "moviebox" in Settings.defaults()
      assert Settings.configured?(user.uuid)

      # The third collection is visible to the rest of the app without touching the other two.
      assert %{torrent: false, pengu: false, nuvio: true} = Roki.Sources.available(user.uuid)
    end

    test "a provider is toggled on or off, defaults included", %{user: user} do
      [first | rest] = Settings.defaults()

      {:ok, user} = Settings.set_enabled(user, "purstream", true)
      assert Settings.enabled_ids(user.uuid) == ["purstream" | Settings.defaults()]

      {:ok, user} = Settings.set_enabled(user, first, false)
      assert Settings.enabled_ids(user.uuid) == ["purstream" | rest]

      {:ok, user} = Settings.set_enabled(user, "purstream", false)
      assert Settings.enabled_ids(user.uuid) == rest

      {:ok, _user} = Settings.set_enabled(user, first, true)
      assert Settings.enabled_ids(user.uuid) == Settings.defaults()
    end

    test "switching every provider off leaves the collection unavailable", %{user: user} do
      user =
        Enum.reduce(Settings.defaults(), user, fn id, user ->
          {:ok, user} = Settings.set_enabled(user, id, false)
          user
        end)

      assert Settings.enabled_ids(user.uuid) == []
      refute Settings.configured?(user.uuid)
      assert %{nuvio: false} = Roki.Sources.available(user.uuid)
    end

    test "settings saved before the defaults keep their choices and gain the defaults", %{
      user: user
    } do
      fields =
        Map.put(user.custom_fields || %{}, "nuvio", %{
          "enabled" => ["vidlink", "purstream"],
          "accepted" => %{"vidlink" => true}
        })

      {:ok, _} = PhoenixKit.Users.Auth.update_user_custom_fields(user, fields)
      assert Settings.enabled_ids(user.uuid) == ["vidlink", "purstream" | Settings.defaults()]
    end

    test "the Nuvio collection can be the active source when it is the only one available" do
      assert Roki.Sources.current(nil, %{torrent: false, pengu: false, nuvio: true}) == :nuvio
      assert Roki.Sources.current(nil, %{torrent: true, pengu: false, nuvio: true}) == :torrent
    end

    test "an account that chose nothing starts on Nuvio rather than PenguPlay, after debrid" do
      all = %{torrent: true, pengu: true, nuvio: true}
      assert Roki.Sources.current(nil, all) == :torrent
      assert Roki.Sources.current(nil, %{all | torrent: false}) == :nuvio
      assert Roki.Sources.current(nil, %{all | torrent: false, nuvio: false}) == :pengu
      # An explicit choice, or a link that names one, still wins.
      assert Roki.Sources.pick(:pengu, %{all | torrent: false}) == :pengu
    end

    test "a saved Play from of PenguPlay is kept", %{user: user} do
      dir = Roki.Laev.dir(user.uuid)
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      :ok = Roki.Laev.put_web_setting(user.uuid, "play_from", "pengu")

      assert Roki.Sources.current(user.uuid, %{torrent: false, pengu: true, nuvio: true}) ==
               :pengu
    end

    test "provider option descriptions are normalised for the settings form" do
      fields =
        Settings.normalize_fields([
          %{"type" => "header", "label" => "Source"},
          %{
            "type" => "select",
            "key" => "preferred",
            "label" => "Preferred",
            "defaultValue" => "all",
            "options" => [%{"label" => "All", "value" => "all"}]
          },
          %{"type" => "toggle", "key" => "hd", "label" => "HD", "default" => true},
          %{"type" => "text", "key" => "token", "label" => "Token", "isPassword" => true},
          %{"type" => "text", "key" => "../bad", "label" => "Bad"}
        ])

      assert [
               %{type: :header, label: "Source"},
               %{type: :select, key: "preferred", default: "all", options: [%{value: "all"}]},
               %{type: :toggle, key: "hd", default: true},
               %{type: :text, key: "token", secret: true}
             ] = fields
    end

    test "options are kept per provider", %{user: user} do
      {:ok, user} = Settings.set_options(user, "netmirror", %{"forceHd" => "true"})
      assert Settings.options(user.uuid, "netmirror") == %{"forceHd" => "true"}
      assert Settings.options(user.uuid, "other") == %{}
    end
  end

  describe "playback links" do
    test "a Nuvio token binds the URL and its headers" do
      token =
        Relay.nuvio_sign("https://cdn.example.com/a.mkv", %{"Referer" => "https://example.com/"})

      assert {:ok,
              %{
                url: "https://cdn.example.com/a.mkv",
                headers: %{"Referer" => "https://example.com/"}
              }} =
               Relay.nuvio_verify(token)
    end

    test "the HLS bridge rewrites playlists, keys and segments to signed URLs" do
      body = """
      #EXTM3U
      #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
      #EXT-X-MAP:URI="init.mp4"
      #EXTINF:6,
      seg1.ts
      #EXT-X-STREAM-INF:BANDWIDTH=800000
      child/index.m3u8
      """

      rewritten =
        NuvioController.rewrite(body, "https://cdn.example.com/a/master.m3u8", %{
          "Referer" => "https://example.com/"
        })

      assert rewritten =~
               "#EXT-X-KEY:METHOD=AES-128,URI=\"/relay/nuvio?u=https%3A%2F%2Fcdn.example.com%2Fa%2Fkey.bin"

      assert rewritten =~ "/relay/nuvio?u=https%3A%2F%2Fcdn.example.com%2Fa%2Fseg1.ts"
      assert rewritten =~ "/nuvio/hls?u=https%3A%2F%2Fcdn.example.com%2Fa%2Fchild%2Findex.m3u8"
    end
  end
end
