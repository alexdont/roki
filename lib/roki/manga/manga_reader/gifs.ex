defmodule Roki.Manga.MangaReader.Gifs do
  @moduledoc """
  `Manhwa.GifProvider` implementation over GiphyApi, keyed/rated by
  the same PhoenixKit settings the comments GIF picker uses.
  """

  @behaviour Manhwa.GifProvider

  @impl true
  def search(query, opts) do
    GiphyApi.search(query,
      api_key: api_key(),
      limit: Keyword.get(opts, :limit, 20),
      offset: Keyword.get(opts, :offset, 0),
      rating: rating()
    )
  end

  @impl true
  def trending(opts) do
    GiphyApi.trending(
      api_key: api_key(),
      limit: Keyword.get(opts, :limit, 20),
      rating: rating()
    )
  end

  defp api_key do
    PhoenixKit.Settings.get_setting("comments_giphy_api_key") ||
      Application.get_env(:giphy_api, :api_key)
  end

  defp rating do
    PhoenixKit.Settings.get_setting("comments_giphy_rating") || "pg-13"
  end
end
