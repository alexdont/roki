defmodule Manhwa.ReaderHTML do
  @moduledoc """
  View module for the strip reader page, plus the source-building
  helpers shared with the template's inline engine.
  """

  use Phoenix.Component

  embed_templates "reader_html/*"

  @doc """
  Build a `FrescoStrip.viewer` `:sources` list. Each entry is
  `%{url:, width:, height:}` where width/height are in source pixels —
  the component uses them to set `aspect-ratio` on each `<img>` so the
  layout doesn't collapse when memory-windowing evicts off-screen srcs.

  Falls back to a 720×1080 placeholder (1:1.5 portrait) when an image
  lacks natural dimensions.
  """
  def strip_sources(images, proxy_url) do
    Enum.map(images, fn img ->
      {w, h} = strip_dims(img)
      %{url: proxied_url(img.url, proxy_url), width: w, height: h}
    end)
  end

  defp strip_dims(%{width: w, height: h})
       when is_integer(w) and is_integer(h) and w > 0 and h > 0,
       do: {w, h}

  defp strip_dims(%{width: w, height: h}) when is_number(w) and is_number(h) and w > 0 and h > 0,
    do: {trunc(w), trunc(h)}

  defp strip_dims(_), do: {720, 1080}

  @doc """
  Same-origin proxied URL for an external image. Synthetic images
  (data: URLs) pass through untouched.
  """
  def proxied_url("data:" <> _ = url, _proxy_url), do: url

  def proxied_url(url, proxy_url) do
    proxy_url <> "?" <> URI.encode_query(%{url: clean_image_url(url)})
  end

  @doc "Strip reader-internal URL fragments (e.g. `#scrambled_N`) before proxying."
  def clean_image_url(url), do: String.replace(url, ~r/#scrambled_\d+$/, "")

  @doc "Join a URL base with one path segment, encoding the segment."
  def url_join(base, segment),
    do: base <> "/" <> URI.encode(to_string(segment), &URI.char_unreserved?/1)

  @doc "Series key for client-side storage namespacing (`source:slug` or the slug)."
  def series_key(series), do: Enum.join(series, ":")

  @doc "Last series segment — the slug used in per-series localStorage keys."
  def series_slug(series), do: List.last(series)
end
