defmodule Roki.Pengu do
  @moduledoc """
  PenguPlay as a Stremio addon: the install URL (`PENGU_ADDON_URL`, its path carries the owner's
  provider and quality settings and an auth token, so it is a secret) answers
  `<base>/stream/{movie|series}/{imdb}[:season:episode].json` with the releases its providers
  found. Nothing here scrapes — the addon does; this asks, tidies the answer and groups it.

  A stream is `%{provider:, quality:, language:, size:, label:, url:, kind:, headers:, subtitles:}`
  where `kind` is `:hls` or `:file`. Entries with no `url` (the donate banner, magnets) are dropped.
  """

  alias Roki.TTLCache

  @ttl 600
  @timeout 45_000
  @qualities ~w(4K 2160P 1440P 1080P 720P 480P 360P)

  @doc "Whether an addon URL is configured."
  def configured?, do: base() != nil

  @doc "`{:ok, [stream]}` for a film (`season`/`episode` nil) or an episode, or `{:error, reason}`."
  def streams(imdb_id, season \\ nil, episode \\ nil)

  def streams(imdb_id, season, episode) when is_binary(imdb_id) do
    case base() do
      nil ->
        {:error, :not_configured}

      base ->
        TTLCache.fetch({:pengu, imdb_id, season, episode}, @ttl, fn ->
          fetch(base, imdb_id, season, episode)
        end)
    end
  end

  def streams(_, _, _), do: {:error, :no_imdb_id}

  defp fetch(base, imdb_id, season, episode) do
    {type, id} =
      if season && episode,
        do: {"series", "#{imdb_id}:#{season}:#{episode}"},
        else: {"movie", imdb_id}

    case Req.get("#{base}/stream/#{type}/#{id}.json", receive_timeout: @timeout, retry: false) do
      {:ok, %{status: 200, body: %{"streams" => list}}} when is_list(list) -> {:ok, parse(list)}
      {:ok, %{status: 200}} -> {:error, :bad_answer}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, e} -> {:error, e}
    end
  end

  @doc "Normalise the addon's `streams` array: playable entries only, duplicates by URL dropped."
  def parse(list) when is_list(list) do
    list
    |> Enum.filter(&match?(%{"url" => "https://" <> _}, &1))
    |> Enum.map(&stream/1)
    |> Enum.uniq_by(& &1.url)
  end

  defp stream(%{"url" => url} = s) do
    hints = s["behaviorHints"] || %{}
    desc = s["description"] || ""
    name = s["name"] || ""

    %{
      id: id(url),
      name: name(hints["filename"], desc),
      provider: provider(desc, name),
      quality: quality(desc, name),
      language: desc |> line("🎧") |> String.replace(~r/^Audio:\s*/, ""),
      size: line(desc, "💾"),
      codec: codec(desc <> " " <> to_string(hints["filename"])),
      label:
        desc
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.join(" · "),
      url: url,
      kind: kind(url),
      headers: get_in(hints, ["proxyHeaders", "request"]) || %{},
      filename: hints["filename"],
      subtitles: for(%{"url" => u} = sub <- s["subtitles"] || [], do: %{url: u, lang: sub["lang"]})
    }
  end

  # A short name for a stream that outlives its signature: the address without its query string
  # (the `psig` changes with every request; the path does not).
  defp id(url) do
    uri = URI.parse(url)

    :crypto.hash(:sha256, "#{uri.host}#{uri.path}") |> Base.url_encode64(padding: false) |> binary_part(0, 16)
  end

  # What to call a stream in a list: the release's file name when it has one, else the description's
  # format line (`4K • HLS • HEVC`) — the addon's own filename hint for a playlist is a tag, not a name.
  defp name(filename, desc) do
    file = filename |> to_string() |> String.split("|^|") |> hd()

    if Regex.match?(~r/\.(mkv|mp4|avi|webm|m4v)$/i, file),
      do: file,
      else: line(desc, "🎞️")
  end

  defp codec(text) do
    cond do
      Regex.match?(~r/hevc|x265|h\.?265/i, text) -> :hevc
      Regex.match?(~r/\bav1\b/i, text) -> :av1
      true -> :other
    end
  end

  @doc """
  The stream to start without asking, or nil: what a browser can play first, then the language,
  then the sharpest picture up to 1080p (4K only when nothing else is left), then the providers
  whose streams have played best here. `caps` is what the browser said it decodes (`Roki.Direct.caps/1`);
  HEVC and AV1 are left out unless it did. `skip` is ids that already failed.
  """
  def best(streams, caps \\ %{}, skip \\ []) do
    streams
    |> Enum.reject(&(&1.id in skip or not decodable?(&1, caps)))
    |> Enum.min_by(&score/1, fn -> nil end)
  end

  defp decodable?(%{codec: :hevc}, caps), do: caps[:hevc] == true
  defp decodable?(%{codec: :av1}, caps), do: caps[:av1] == true
  defp decodable?(_, _caps), do: true

  # Lower is better. Providers are listed in the order their streams actually played when tried on
  # The Matrix (2026-10-31); the rest follow, untried ones before the ones that stalled.
  @providers ~w(Arctic HDHub4u VegaMovies LaMovie Moflix Vidy MovieBox VidFast Cinejoy VidLink 2Peckle VAPlayer)
  @tiers %{"1080P" => 0, "720P" => 1, "1440P" => 2, "480P" => 3, "360P" => 4, "4K" => 5, "2160P" => 5}

  defp score(s) do
    {language_rank(s.language), Map.get(@tiers, s.quality, 6),
     Enum.find_index(@providers, &(&1 == s.provider)) || 6, size_gb(s.size)}
  end

  defp language_rank(""), do: 0
  defp language_rank(lang), do: if(String.contains?(lang, "English"), do: 0, else: 1)

  defp size_gb(size) do
    case Regex.run(~r/([\d.]+)\s*(GB|MB)/i, size) do
      [_, n, unit] ->
        {v, _} = Float.parse(n)
        if String.upcase(unit) == "MB", do: v / 1024, else: v

      _ ->
        0.0
    end
  end

  @doc "The stream called `id` among `streams`, or nil."
  def find(streams, id), do: Enum.find(streams, &(&1.id == id))

  defp provider(desc, name) do
    case line(desc, "🛰️") do
      "" -> name
      l -> l |> String.replace(~r/^Source:\s*/, "") |> String.split(" · ") |> hd()
    end
  end

  defp quality(desc, name) do
    case Regex.run(~r/\b(4K|2160p|1440p|1080p|720p|480p|360p)\b/i, line(desc, "🎞️") <> " " <> name) do
      [_, q] -> String.upcase(q)
      _ -> ""
    end
  end

  # The text after a marker emoji on its own line of the description.
  defp line(desc, marker) do
    desc
    |> String.split("\n")
    |> Enum.find_value("", fn l ->
      case String.trim(l) do
        ^marker <> rest -> String.trim(rest)
        _ -> nil
      end
    end)
  end

  defp kind(url), do: if(String.contains?(URI.parse(url).path || "", "m3u8"), do: :hls, else: :file)

  @doc "Streams grouped by provider, best quality first: `[{provider, [stream]}]`."
  def group(streams) do
    streams
    |> Enum.group_by(& &1.provider)
    |> Enum.map(fn {p, l} -> {p, Enum.sort_by(l, &rank/1)} end)
    |> Enum.sort_by(fn {p, [best | _]} -> {rank(best), p} end)
  end

  defp rank(%{quality: q}), do: Enum.find_index(@qualities, &(&1 == q)) || 9

  @doc "What to tell the viewer when a search failed."
  def message(:not_configured), do: "PenguPlay is not set up on this server."
  def message(:no_imdb_id), do: "This title has no IMDb id, which PenguPlay looks titles up by."
  def message({:http, status}), do: "PenguPlay answered #{status}."
  def message(:timeout), do: "PenguPlay did not answer in time."
  def message(_), do: "PenguPlay could not be reached."

  defp base do
    case Application.get_env(:roki, :pengu_addon_url) do
      url when is_binary(url) and url != "" ->
        url |> String.trim_trailing("/manifest.json") |> String.trim_trailing("/")

      _ ->
        nil
    end
  end
end
