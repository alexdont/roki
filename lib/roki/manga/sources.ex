defmodule Roki.Manga.Sources do
  @moduledoc """
  Where a series can be read from. Each source answers the same three functions — `search/1`,
  `get_manga/1`, `get_chapter_images/2` — and is named by the key its slugs were saved under in
  the old reader, so imported rows keep working.

  Each site's parsing came over from the old reader untouched: it is tuned to that site's markup
  and would only break by being tidied.
  """
  alias Roki.Manga.Sources

  # The keys are the ones slugs were saved under in the old reader, so an imported row opens at
  # the address it always had. `kotatsu` is not a site but every extension the sidecar carries,
  # with the extension named inside the slug.
  @sources %{
    "kotatsu" => %{module: Sources.Kotatsu, label: "Extensions", lang: :en},
    "mangahere" => %{module: Sources.MangaHere, label: "MangaHere", lang: :en},
    "mangafreak" => %{module: Sources.MangaFreak, label: "MangaFreak", lang: :en},
    "mangafire" => %{module: Sources.MangaFire, label: "MangaFire", lang: :en},
    "atsumaru" => %{module: Sources.Atsumaru, label: "Atsumaru", lang: :en},
    "weebcentral" => %{module: Sources.WeebCentral, label: "Weeb Central", lang: :en},
    "mangakatana" => %{module: Sources.MangaKatana, label: "MangaKatana", lang: :en},
    "mangalib" => %{module: Sources.MangaLib, label: "MangaLib", lang: :ru},
    "mangabuff" => %{module: Sources.MangaBuff, label: "MangaBuff", lang: :ru},
    "remanga" => %{module: Sources.Remanga, label: "Remanga", lang: :ru},
    "comx" => %{module: Sources.ComX, label: "Com-X", lang: :ru}
  }

  @doc "Every source that can be read."
  def all, do: @sources

  @doc "What language a source reads in, for grouping a search."
  def lang(source) do
    case @sources[source] do
      %{lang: l} -> l
      _ -> :en
    end
  end

  @doc "Whether this source is one we can read."
  def known?(source), do: Map.has_key?(@sources, source)

  @doc "The module for a source, or nil."
  def module(source) do
    case @sources[source] do
      %{module: m} -> m
      _ -> nil
    end
  end

  @doc "What to call a source on screen."
  def label(source) do
    case @sources[source] do
      %{label: l} -> l
      _ -> source
    end
  end

  # Which site each image host belongs to. A page's CDN refuses a request that does not look like
  # it came from the site it serves, so this table is what makes an image load at all — carried
  # over from the old reader whole, since every entry in it was learned from a broken page.
  @referers %{
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

  @doc "Which site a page image belongs to, for the referer it will not load without."
  def image_referer(host) when is_binary(host) do
    case Map.get(@referers, host) do
      nil -> pattern_referer(host)
      referer -> referer
    end
  end

  def image_referer(_), do: nil

  # Some sites number their CDNs, so the host cannot be listed once and for all.
  defp pattern_referer(host) do
    cond do
      String.match?(host, ~r/\.mfcdn\d*\.\w+$/) -> "https://mangafire.to/"
      String.match?(host, ~r/\.?reimg\d*\.org$/) -> "https://remanga.org/"
      String.match?(host, ~r/\.mangakatana\.com$/) -> "https://mangakatana.com/"
      String.ends_with?(host, "mangahere.cc") -> "https://www.mangahere.cc/"
      true -> nil
    end
  end
end
