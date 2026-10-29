defmodule Manhwa.GifProvider do
  @moduledoc """
  Optional adapter backing the annotation composer's GIF picker.
  When unconfigured the GIF button doesn't render.

      config :manhwa, gif_provider: MyApp.ReaderGifs

  Results are returned to the client as `%{data: gifs}` — shape them
  however your picker JS expects (the built-in composer expects
  Giphy-style entries with `images.fixed_width.url` etc.).
  """

  @callback search(query :: String.t(), opts :: keyword) :: {:ok, list} | {:error, term}
  @callback trending(opts :: keyword) :: {:ok, list} | {:error, term}
end
