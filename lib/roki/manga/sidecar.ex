defmodule Roki.Manga.Sidecar do
  @moduledoc """
  The kotatsu sidecar over HTTP: a Kotlin service beside this one wrapping a thousand-odd
  community parsers (`kotatsu_sidecar/`, and its README for the API). It is reachable only on
  this stack's private network, has no authentication, and answers JSON.

  Images are the part that matters most: a page's own CDN refuses a request without the site's
  referer and cookies, so every page URL handed on is the sidecar's `/image` address and the
  sidecar adds those headers on the way out.
  """
  require Logger

  @doc "Where the sidecar is. `config :roki, kotatsu_url:`, set in the stack's compose."
  def base_url, do: Application.get_env(:roki, :kotatsu_url, "http://kotatsu:8420")

  @doc "Whether the sidecar is up: `{:ok, parsers_version}` or `{:error, reason}`."
  def health do
    case get("/health", []) do
      {:ok, %{"parsersVersion" => v}} -> {:ok, v}
      other -> normalise(other)
    end
  end

  @doc "Every parser it carries."
  def sources do
    case get("/sources", []) do
      {:ok, list} when is_list(list) -> {:ok, list}
      other -> normalise(other)
    end
  end

  @doc "A series' details and chapter list, by the parser's own url for it."
  def manga(name, url) do
    case get("/sources/#{URI.encode(name)}/manga", url: url) do
      {:ok, %{} = m} -> {:ok, m}
      other -> normalise(other)
    end
  end

  @doc "A chapter's pages, by the parser's own url for the chapter."
  def pages(name, chapter_url) do
    case get("/sources/#{URI.encode(name)}/pages", chapterUrl: chapter_url) do
      {:ok, list} when is_list(list) -> {:ok, list}
      other -> normalise(other)
    end
  end

  @doc "The address to read a page image at — never the site's own, which would be refused."
  def image_url(_name, nil), do: nil
  def image_url(_name, ""), do: nil

  def image_url(name, url) do
    base_url() <> "/sources/" <> URI.encode(name) <> "/image?" <> URI.encode_query(url: url)
  end

  @doc """
  The sidecar's address, corrected. A series saved by the old reader carries that machine's own
  sidecar in its cover url (`http://127.0.0.1:8420/...`), which here is nothing at all — so any
  address that is plainly a sidecar's is re-pointed at the one we have.
  """
  def rehost(url) when is_binary(url) do
    case Regex.run(~r{^https?://[^/]+(/sources/.*)$}, url) do
      [_, path] -> base_url() <> path
      _ -> url
    end
  end

  def rehost(url), do: url

  @doc "Whether this is one of ours, and so needs no headers of its own."
  def image_url?(url) when is_binary(url),
    do:
      String.starts_with?(url, base_url() <> "/sources/") or
        Regex.match?(~r{^https?://[^/]+:8420/sources/}, url)

  def image_url?(_), do: false

  defp get(path, params) do
    case Req.get(base_url() <> path, params: params, receive_timeout: 30_000, retry: false) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {status, reason(body)}}
      {:error, e} -> {:error, Exception.message(e)}
    end
  end

  defp reason(%{"error" => e}), do: e
  defp reason(other), do: inspect(other)

  defp normalise({:ok, body}), do: {:error, "unexpected answer: #{inspect(body)}"}
  defp normalise({:error, reason}), do: {:error, reason}
end
