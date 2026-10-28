defmodule Roki.Manga.Sources do
  @sources %{
    "mangafreak" => %{
      module: Roki.Manga.MangaFreak,
      label: "MangaFreak",
      url_fn: :mangafreak_url,
      lang: :en
    },
    "mangahere" => %{
      module: Roki.Manga.MangaHere,
      label: "MangaHere",
      url_fn: :mangahere_url,
      lang: :en
    },
    "mangafire" => %{
      module: Roki.Manga.MangaFire,
      label: "MangaFire",
      url_fn: :mangafire_url,
      lang: :en
    },
    "mangalib" => %{
      module: Roki.Manga.MangaLib,
      label: "MangaLib",
      url_fn: :mangalib_url,
      lang: :ru
    },
    "mangabuff" => %{
      module: Roki.Manga.MangaBuff,
      label: "MangaBuff",
      url_fn: :mangabuff_url,
      lang: :ru
    },
    "remanga" => %{
      module: Roki.Manga.Remanga,
      label: "Remanga",
      url_fn: :remanga_url,
      lang: :ru
    },
    "atsumaru" => %{
      module: Roki.Manga.Atsumaru,
      label: "Atsumaru",
      url_fn: :atsumaru_url,
      lang: :en
    },
    "weebcentral" => %{
      module: Roki.Manga.WeebCentral,
      label: "Weeb Central",
      url_fn: :weebcentral_url,
      lang: :en
    },
    "mangakatana" => %{
      module: Roki.Manga.MangaKatana,
      label: "MangaKatana",
      url_fn: :mangakatana_url,
      lang: :en
    },
    "comx" => %{
      module: Roki.Manga.ComX,
      label: "Com-X",
      url_fn: :comx_url,
      lang: :ru
    }
  }

  @lang_labels %{en: "English", ru: "Russian"}
  @lang_order [:en, :ru]

  @allowed_hosts %{
    "images.mangafreak.me" => "https://ww2.mangafreak.me/",
    "zjcdn.mangahere.org" => "https://www.mangahere.cc/",
    "zjcdn.org" => "https://www.mangahere.cc/",
    "fmcdn.mangahere.com" => "https://www.mangahere.cc/",
    "img3.mixlib.me" => "https://mangalib.me/",
    "cover.imglib.info" => "https://mangalib.me/",
    "static.mfcdn.cc" => "https://mangafire.to/",
    "mangabuff.ru" => "https://mangabuff.ru/",
    "c3.mangabuff.ru" => "https://mangabuff.ru/",
    "c2.mangabuff.ru" => "https://mangabuff.ru/",
    "img.mangabuff.ru" => "https://mangabuff.ru/",
    "img.reimg2.org" => "https://remanga.org/",
    "remanga.org" => "https://remanga.org/",
    "atsu.moe" => "https://atsu.moe/",
    "temp.compsci88.com" => "https://weebcentral.com/",
    "scans.lastation.us" => "https://weebcentral.com/",
    "official.lowee.us" => "https://weebcentral.com/",
    "mangakatana.com" => "https://mangakatana.com/",
    "img.com-x.life" => "https://com-x.life/",
    "com-x.life" => "https://com-x.life/"
  }

  # "kotatsu" is a virtual aggregate source: the slug carries the
  # actual extension + manga identity (see Roki.Manga.KotatsuSource).
  # It resolves through get/module/label/valid? like any source, but
  # is deliberately NOT in @sources so all()/grouped() (the native
  # search fan-out) skip it — extensions have their own fan-out.
  @kotatsu_entry %{
    module: Roki.Manga.KotatsuSource,
    label: "Extension",
    url_fn: nil,
    lang: :en
  }

  def get("kotatsu"), do: @kotatsu_entry
  def get(key), do: Map.get(@sources, key)

  def module("kotatsu"), do: Roki.Manga.KotatsuSource

  def module(key) do
    case Map.get(@sources, key) do
      %{module: mod} -> mod
      nil -> nil
    end
  end

  def label("kotatsu"), do: "Extension"

  def label(key) do
    case Map.get(@sources, key) do
      %{label: lbl} -> lbl
      nil -> nil
    end
  end

  def source_url(key, slug) do
    case key do
      "mangafreak" -> "https://ww2.mangafreak.me/Manga/#{slug}"
      "mangahere" -> "https://www.mangahere.cc/manga/#{slug}/"
      "mangalib" -> "https://mangalib.me/ru/manga/#{slug}"
      "mangafire" -> "https://mangafire.to/manga/#{slug}"
      "mangabuff" -> "https://mangabuff.ru/manga/#{slug}"
      "remanga" -> "https://remanga.org/manga/#{slug}"
      "atsumaru" -> "https://atsu.moe/manga/#{slug}"
      "weebcentral" -> "https://weebcentral.com/series/#{slug}"
      "mangakatana" -> "https://mangakatana.com/manga/#{slug}"
      "comx" -> "https://com-x.life/#{slug}.html"
      _ -> nil
    end
  end

  # Sources temporarily disabled from search (e.g. due to Cloudflare blocking)
  @disabled_sources ["mangafire"]

  def all do
    @sources
    |> Enum.reject(fn {key, _} -> key in @disabled_sources end)
    |> Enum.map(fn {key, %{label: label}} -> {key, label} end)
  end

  def grouped do
    by_lang =
      @sources
      |> Enum.reject(fn {key, _} -> key in @disabled_sources end)
      |> Enum.group_by(fn {_key, %{lang: lang}} -> lang end)
      |> Map.new(fn {lang, entries} ->
        {lang, Enum.map(entries, fn {key, %{label: label}} -> {key, label} end)}
      end)

    Enum.map(@lang_order, fn lang ->
      {Map.get(@lang_labels, lang, to_string(lang)), Map.get(by_lang, lang, [])}
    end)
  end

  def valid?("kotatsu"), do: true
  def valid?(key), do: Map.has_key?(@sources, key)

  def allowed_hosts, do: @allowed_hosts

  @doc "Returns the referer for a given image host, supporting both exact and pattern matches."
  def image_referer(host) do
    case Map.get(@allowed_hosts, host) do
      nil -> pattern_referer(host)
      referer -> referer
    end
  end

  defp pattern_referer(host) do
    cond do
      String.match?(host, ~r/\.mfcdn\d*\.\w+$/) -> "https://mangafire.to/"
      String.match?(host, ~r/\.?reimg\d*\.org$/) -> "https://remanga.org/"
      String.match?(host, ~r/\.mangakatana\.com$/) -> "https://mangakatana.com/"
      true -> nil
    end
  end
end
