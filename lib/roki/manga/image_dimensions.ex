defmodule Roki.Manga.ImageDimensions do
  @moduledoc """
  Thin wrapper over the `dims` hex package (extracted from this
  module) — remote image dimension probing via HTTP Range fetches.

  What stays app-side is the per-source glue: chapter image CDNs
  reject requests without the right `Referer`, so every probe goes out
  with the header `Sources.image_referer/1` resolves for the URL's
  host. Caching moved into dims' own ETS cache (same 30-day semantics
  the old `Roki.Manga.Cache` keying had).

  The reader-specific probe strategies keep their names:

    * `probe_paged/1` — full probe for pageable chapter lengths (exact
      per-page dims drive double-page spread pairing), sampled beyond
      80 images (strip-sized lists).
    * `probe_sampled/1` — ~20-sample + median-fill for enormous
      manhwa chapters.
  """

  alias Roki.Manga.Sources

  @doc "Probe a single URL. Returns `%{width:, height:}` or `nil`."
  def probe(url, opts \\ []) when is_binary(url) do
    Dims.probe(url, Keyword.merge(default_opts(), opts))
  end

  @doc "Probe all URLs in parallel; failures backfilled with sibling medians."
  def probe_all(urls) when is_list(urls) do
    Dims.probe_all(urls, default_opts())
  end

  @doc "Full probe up to `full_threshold` images, sampled beyond (paged reader)."
  def probe_paged(urls, full_threshold \\ 80) when is_list(urls) do
    Dims.probe_auto(urls, Keyword.put(default_opts(), :full_threshold, full_threshold))
  end

  @doc "Sampled probe with median fill (strip reader / huge lists)."
  def probe_sampled(urls, sample_size \\ 20) when is_list(urls) do
    Dims.probe_sampled(urls, Keyword.put(default_opts(), :sample_size, sample_size))
  end

  defp default_opts do
    [headers_fun: &referer_headers/1]
  end

  defp referer_headers(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        case Sources.image_referer(host) do
          nil -> []
          referer -> [{"referer", referer}]
        end

      _ ->
        []
    end
  end
end
