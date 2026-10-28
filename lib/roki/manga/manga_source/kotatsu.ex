defmodule Roki.Manga.MangaSource.Kotatsu do
  @moduledoc """
  `Roki.Manga.MangaSource` implementation backed by the
  kotatsu-parsers sidecar (`kotatsu_sidecar/` — a Kotlin HTTP service
  wrapping 1,000+ community-maintained site parsers).

  Configuration:

      config :roki, :kotatsu_url, "http://127.0.0.1:8420"
      # test-only escape hatch, merged into every request:
      config :roki, :kotatsu_req_options, plug: {Req.Test, __MODULE__}

  Sidecar error JSON is translated to value errors (`:not_found`,
  `:auth_required`, `:rate_limited`, `{:cloudflare, source}`,
  `{:upstream, detail}`); transport failures become
  `{:transport, reason}`. Nothing raises — sources flake constantly
  and callers degrade per-source.
  """

  @behaviour Roki.Manga.MangaSource

  # Scraper sources are slow — a cold chapter fetch can take tens of
  # seconds upstream.
  @receive_timeout 30_000

  @known_states %{
    "ONGOING" => :ongoing,
    "FINISHED" => :finished,
    "ABANDONED" => :abandoned,
    "PAUSED" => :paused,
    "UPCOMING" => :upcoming,
    "RESTRICTED" => :restricted
  }

  @impl true
  def list_sources do
    case get("/sources", []) do
      {:ok, %{status: 200, body: sources}} when is_list(sources) ->
        {:ok,
         Enum.map(sources, fn s ->
           %{
             id: s["name"],
             title: s["title"],
             locale: s["locale"] || "",
             broken: s["broken"] == true,
             search_supported: s["searchSupported"] != false,
             content_type: s["contentType"] || "MANGA"
           }
         end)}

      other ->
        translate_error(other, nil)
    end
  end

  @impl true
  def search(source_id, query, page \\ 1) do
    case get("/sources/#{encode(source_id)}/search", q: query, page: page) do
      {:ok, %{status: 200, body: %{"items" => items}}} ->
        {:ok, Enum.map(items, &to_manga(&1, source_id))}

      other ->
        translate_error(other, source_id)
    end
  end

  @impl true
  def catalog(source_id, page \\ 1) do
    case get("/sources/#{encode(source_id)}/list", page: page) do
      {:ok, %{status: 200, body: %{"items" => items}}} ->
        {:ok, Enum.map(items, &to_manga(&1, source_id))}

      other ->
        translate_error(other, source_id)
    end
  end

  @impl true
  def details(%{source: source_id, url: url}) do
    case get("/sources/#{encode(source_id)}/manga", url: url) do
      {:ok, %{status: 200, body: body}} ->
        manga = to_manga(body, source_id)
        chapters = Enum.map(body["chapters"] || [], &to_chapter/1)
        {:ok, manga, chapters}

      other ->
        translate_error(other, source_id)
    end
  end

  @impl true
  def pages(source_id, chapter_url) do
    case get("/sources/#{encode(source_id)}/pages", chapterUrl: chapter_url) do
      {:ok, %{status: 200, body: %{"pages" => pages}}} ->
        {:ok,
         Enum.map(pages, fn p ->
           %{index: p["index"], image_url: p["imageUrl"], proxy_path: p["proxyPath"]}
         end)}

      other ->
        translate_error(other, source_id)
    end
  end

  @doc "Sidecar liveness — `{:ok, parsers_version}` when it responds."
  def health do
    case get("/health", []) do
      {:ok, %{status: 200, body: %{"status" => "ok"} = body}} -> {:ok, body["parsersVersion"]}
      other -> translate_error(other, nil)
    end
  end

  @doc """
  The `Req` request used for every sidecar call — the image-proxy
  controller reuses it to stream `/sources/:name/image`.
  """
  def base_request do
    Req.new(
      base_url: base_url(),
      receive_timeout: @receive_timeout,
      retry: false
    )
    |> Req.merge(Application.get_env(:roki, :kotatsu_req_options, []))
  end

  defp base_url do
    Application.get_env(:roki, :kotatsu_url, "http://127.0.0.1:8420")
  end

  defp get(path, params) do
    Req.get(base_request(), url: path, params: params)
  end

  defp encode(source_id), do: URI.encode(source_id)

  defp to_manga(m, source_id) do
    %{
      ref: %{source: source_id, url: m["url"]},
      title: m["title"] || "",
      cover_url: m["coverUrl"],
      public_url: m["publicUrl"],
      description: m["description"],
      state: @known_states[m["state"]],
      authors: m["authors"] || [],
      tags: m["tags"] || []
    }
  end

  defp to_chapter(c) do
    %{
      url: c["url"],
      title: c["title"],
      number: (c["number"] || 0) / 1,
      volume: c["volume"] || 0,
      branch: c["branch"],
      scanlator: c["scanlator"],
      uploaded_at: to_datetime(c["uploadDate"])
    }
  end

  defp to_datetime(ms) when is_integer(ms) and ms > 0 do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp to_datetime(_), do: nil

  # ── Error translation ─────────────────────────────────────────────

  defp translate_error({:ok, %{status: status, body: body}}, source_id) do
    kind = if is_map(body), do: body["kind"]
    detail = if is_map(body), do: body["error"], else: body

    reason =
      cond do
        kind == "cloudflare" -> {:cloudflare, source_id}
        status == 404 -> :not_found
        status == 401 -> :auth_required
        status == 429 -> :rate_limited
        true -> {:upstream, %{status: status, detail: detail, source: source_id}}
      end

    {:error, reason}
  end

  defp translate_error({:error, exception}, _source_id) do
    {:error, {:transport, exception}}
  end
end
