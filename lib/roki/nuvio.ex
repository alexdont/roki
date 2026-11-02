defmodule Roki.Nuvio do
  @moduledoc """
  The Nuvio source collection: providers discovered from the All-in-One-Nuvio manifest, run
  one call at a time in `Roki.Nuvio.Sandbox`, and normalised into the stream shape the rest of
  Roki already plays (`Roki.Pengu` uses the same fields).

  Providers are **not** interchangeable, and the manifest is not an endorsement. A provider
  runs only when the account enabled it, acknowledged that it will use it only for media it
  may access, and its source passed `Roki.Nuvio.Validator`. Results from one provider are
  reported under that provider, with its own error or timeout, so a broken site never hides
  the other collections.

  Playback stays where it was: a Nuvio stream becomes either a proxied file (`/relay/nuvio`)
  or a rewritten HLS playlist (`/nuvio/hls`), both signed by this server and streamed through
  the existing player. No DRM is removed and no access control is bypassed.
  """

  require Logger

  alias Roki.Nuvio.{Provider, Registry, Sandbox, Settings}
  alias Roki.TTLCache

  @ttl 600
  @timeout 45_000
  @max_providers 12
  @max_streams 40
  @qualities %{"1080P" => 0, "720P" => 1, "1440P" => 2, "480P" => 3, "360P" => 4, "4K" => 5}
  @format_chars ~r/[\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2060}-\x{206F}\x{FEFF}]/u

  # ── what the account may search ────────────────────────────────────

  @doc "The account's enabled and acknowledged providers, with the rest of the catalog."
  def catalog(uuid) do
    settings = Settings.get(uuid)

    case Registry.providers() do
      {:ok, providers} ->
        {:ok,
         Enum.map(providers, fn provider ->
           %{
             provider: provider,
             enabled: provider.id in settings["enabled"],
             accepted: settings["accepted"][provider.id] == true
           }
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Whether Nuvio can be offered to this account at all."
  def configured?(uuid), do: Settings.configured?(uuid)

  @doc "The providers a search will actually run, in manifest order."
  def eligible_providers(uuid, type) do
    ids = Settings.enabled_ids(uuid)

    with {:ok, providers} <- Registry.providers() do
      by_id = Map.new(providers, &{&1.id, &1})

      {:ok,
       ids
       |> Enum.map(&by_id[&1])
       |> Enum.reject(&is_nil/1)
       |> Enum.filter(&(&1.enabled and Provider.supports?(&1, type)))
       |> Enum.take(@max_providers)}
    end
  end

  # ── search ─────────────────────────────────────────────────────────

  @doc """
  Search every eligible provider for a title: `{:ok, [provider_result]}` or
  `{:error, reason}`. Each provider result is independent:

      %{
        provider: %Provider{},
        status: :ok | :empty | :timeout | :error | :blocked,
        streams: [stream],
        error: nil | String.t(),
        ms: integer
      }
  """
  def search(uuid, tmdb_id, type, season \\ nil, episode \\ nil, opts \\ [])

  def search(uuid, tmdb_id, type, season, episode, opts)
      when is_integer(tmdb_id) and type in ["movie", "tv"] do
    with true <- configured?(uuid),
         {:ok, providers} <- eligible_providers(uuid, type),
         true <- providers != [] do
      run_search(uuid, providers, tmdb_id, type, season, episode, opts)
    else
      false -> {:error, :not_configured}
      {:error, _} = error -> error
    end
  end

  def search(_uuid, nil, _type, _season, _episode, _opts), do: {:error, :no_tmdb_id}
  def search(_uuid, _id, _type, _season, _episode, _opts), do: {:error, :bad_request}

  defp run_search(uuid, providers, tmdb_id, type, season, episode, opts) do
    settings = Settings.get(uuid)

    key =
      {:nuvio, uuid, tmdb_id, type, season, episode,
       :erlang.phash2({Enum.map(providers, & &1.id), settings["options"]})}

    if Keyword.get(opts, :force, false), do: TTLCache.delete(key)

    TTLCache.fetch(key, @ttl, fn ->
      {:ok, run_providers(providers, settings, tmdb_id, type, season, episode)}
    end)
  end

  defp run_providers(providers, settings, tmdb_id, type, season, episode) do
    args = if type == "tv", do: [tmdb_id, type, season || 1, episode || 1], else: [tmdb_id, type]

    providers
    |> Task.async_stream(
      fn provider ->
        started = System.monotonic_time(:millisecond)
        options = settings["options"][provider.id] || %{}
        result = run_provider(provider, args, options)
        Map.put(result, :ms, System.monotonic_time(:millisecond) - started)
      end,
      max_concurrency: 6,
      timeout: @timeout + 30_000,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(providers)
    |> Enum.map(fn
      {{:ok, result}, _provider} ->
        result

      {{:exit, :timeout}, provider} ->
        %{
          provider: provider,
          status: :timeout,
          streams: [],
          error: "did not finish in time",
          ms: @timeout
        }

      {{:exit, reason}, provider} ->
        %{provider: provider, status: :error, streams: [], error: explain_exit(reason), ms: 0}

      {:timeout, provider} ->
        %{
          provider: provider,
          status: :timeout,
          streams: [],
          error: "did not finish in time",
          ms: @timeout
        }
    end)
  end

  defp run_provider(provider, args, options) do
    case Registry.source(provider) do
      {:ok, %{source: source, verification: verification, sha256: sha256}} ->
        case Sandbox.run(source, args, options, timeout: @timeout) do
          {:ok, %{"streams" => raw}} ->
            streams =
              raw
              |> Enum.map(&normalize(provider.id, &1))
              |> Enum.reject(&is_nil/1)
              |> Enum.uniq_by(& &1.url)
              |> Enum.take(@max_streams)

            %{
              provider: Map.merge(provider, %{verification: verification, sha256: sha256}),
              status: if(streams == [], do: :empty, else: :ok),
              streams: streams,
              error: nil,
              ms: 0
            }

          {:error, :timeout} ->
            %{
              provider: provider,
              status: :timeout,
              streams: [],
              error: "did not finish in time",
              ms: @timeout
            }

          {:error, {:provider, error}} ->
            %{provider: provider, status: :error, streams: [], error: clean(error), ms: 0}

          {:error, reason} ->
            %{provider: provider, status: :error, streams: [], error: explain(reason), ms: 0}
        end

      {:error, {:rejected, reasons}} ->
        %{
          provider: provider,
          status: :blocked,
          streams: [],
          error: "rejected by the validator: " <> Enum.join(reasons, "; "),
          ms: 0
        }

      {:error, reason} ->
        %{provider: provider, status: :blocked, streams: [], error: explain(reason), ms: 0}
    end
  end

  defp explain_exit(:normal), do: "stopped without an answer"
  defp explain_exit(:killed), do: "was stopped at the time limit"
  defp explain_exit(reason), do: "stopped (#{inspect(reason, limit: 2)})"

  defp explain({:http, status}), do: "the provider file answered #{status}"
  defp explain(:runtime_missing), do: "Node.js is not installed on the server"
  defp explain(:timeout), do: "did not finish in time"
  defp explain({:exit, status, _}), do: "the sandbox exited with status #{status}"
  defp explain(:output_too_large), do: "returned too much data"
  defp explain({:provider, text}), do: clean(text)
  defp explain(_), do: "could not be run"

  @doc "Every stream from every successful provider, flattened."
  def streams(results) when is_list(results), do: Enum.flat_map(results, & &1.streams)

  @doc "The provider result for `id`, or nil."
  def result(results, id) when is_list(results), do: Enum.find(results, &(&1.provider.id == id))

  @doc "Find the stream `stream_id` of provider `provider_id`."
  def find(results, provider_id, stream_id) do
    with %{streams: streams} <- result(results, provider_id) do
      Enum.find(streams, &(&1.id == stream_id))
    else
      _ -> nil
    end
  end

  @doc "Total streams found across providers."
  def count(results), do: results |> streams() |> length()

  # ── normalising a provider answer ──────────────────────────────────

  @doc """
  Turn one provider row into Roki's stream shape, or nil when it cannot be played
  directly. Only public `https://` URLs are accepted; magnets, `data:` URLs and private
  addresses are dropped rather than handed to a player or the relay.
  """
  def normalize(provider_id, %{} = raw) do
    url = raw["url"] || raw["externalUrl"]

    with true <- playable_url?(url) do
      hints =
        case raw["behaviorHints"] do
          %{} = hints -> hints
          _ -> %{}
        end

      title = clean(raw["title"])
      name = clean(raw["name"])
      description = clean(raw["description"])
      label = collapse([name, title, description])
      filename = clean(hints["filename"] || raw["filename"])

      %{
        id: stream_id(provider_id, url),
        provider_id: provider_id,
        name: stream_name(name, title, filename, label),
        provider: provider_id,
        quality: quality(presence(clean(raw["quality"])) || name || title || label),
        language: presence(clean(raw["language"])) || language_hint(label),
        size: presence(clean(raw["size"])) || size_hint(label),
        codec: codec([label, name, title, to_string(hints["filename"] || "")] |> Enum.join(" ")),
        label: label,
        url: url,
        kind: kind(url),
        headers: headers(raw, hints),
        filename: filename,
        subtitles: subtitles(raw["subtitles"])
      }
    else
      _ -> nil
    end
  end

  def normalize(_provider_id, _raw), do: nil

  @doc "Whether a URL may leave this server for a provider stream."
  def playable_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        not private_host?(host)

      _ ->
        false
    end
  end

  def playable_url?(_), do: false

  @doc "Block literal private, loopback and link-local hosts before a relay fetches them."
  def private_host?(host) do
    h = String.downcase(host)

    h in ["localhost", "0.0.0.0", "::1"] or String.ends_with?(h, [".local", ".internal"]) or
      Regex.match?(~r/^127\./, h) or Regex.match?(~r/^10\./, h) or
      Regex.match?(~r/^192\.168\./, h) or Regex.match?(~r/^169\.254\./, h) or
      Regex.match?(~r/^172\.(1[6-9]|2\d|3[01])\./, h) or
      Regex.match?(~r/^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./, h) or
      String.starts_with?(h, "fc") or String.starts_with?(h, "fd") or
      String.starts_with?(h, "fe80")
  end

  defp headers(raw, hints) do
    raw
    |> Map.get("headers", %{})
    |> merge_headers(get_in(hints, ["proxyHeaders", "request"]))
    |> merge_headers(hints["headers"])
    |> sanitize_headers()
  end

  defp merge_headers(%{} = a, %{} = b), do: Map.merge(a, b)
  defp merge_headers(%{} = a, _), do: a
  defp merge_headers(_, %{} = b), do: b
  defp merge_headers(_, _), do: %{}

  @forbidden_headers ~w(host content-length connection transfer-encoding upgrade keep-alive cookie authorization proxy-authorization)

  defp sanitize_headers(headers) do
    headers
    |> Enum.filter(fn {k, v} ->
      is_binary(k) and is_binary(v) and
        String.downcase(k) not in @forbidden_headers and
        not String.contains?(String.downcase(k), ["\n", "\r"]) and
        not String.contains?(v, ["\n", "\r"])
    end)
    |> Enum.take(30)
    |> Map.new()
  end

  defp subtitles(list) when is_list(list) do
    for %{} = sub <- list,
        url = sub["url"],
        playable_url?(url) do
      %{url: url, lang: clean(sub["lang"] || sub["language"] || "und")}
    end
    |> Enum.uniq_by(& &1.url)
    |> Enum.take(20)
  end

  defp subtitles(_), do: []

  defp stream_id(provider_id, url) do
    # The whole URL, not only its path: many Nuvio providers put the rendition in the query.
    hash = :crypto.hash(:sha256, "#{provider_id}:#{url}")
    hash |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  defp kind(url) do
    uri = URI.parse(url)
    if String.contains?(uri.path || "", "m3u8"), do: :hls, else: :file
  end

  defp stream_name(name, title, filename, label) do
    cond do
      name != "" -> name
      filename != "" -> filename
      title != "" -> title |> String.split("\n") |> List.first() |> clean()
      true -> label |> String.split(" · ") |> List.first() |> clean()
    end
  end

  defp quality(raw) when is_binary(raw) do
    case Regex.run(~r/\b(2160p|1440p|1080p|720p|480p|360p|4k)\b/i, raw) do
      [_, q] -> normal_quality(q)
      _ -> clean(raw) |> String.upcase() |> then(&if(&1 in ["HD", "FHD", "SD"], do: &1, else: ""))
    end
  end

  defp quality(_), do: ""

  defp normal_quality(q) do
    case String.downcase(q) do
      "4k" -> "4K"
      "2160p" -> "4K"
      "1440p" -> "1440P"
      "1080p" -> "1080P"
      "720p" -> "720P"
      "480p" -> "480P"
      "360p" -> "360P"
      _ -> ""
    end
  end

  defp language_hint(text) do
    cond do
      Regex.match?(~r/\bdual[- ]?audio\b/i, text) -> "Dual Audio"
      Regex.match?(~r/\bmulti[- ]?audio\b/i, text) -> "Multi Audio"
      true -> ""
    end
  end

  defp size_hint(text) do
    case Regex.run(~r/([\d.]+\s*(?:GB|MB))/i, text) do
      [_, size] -> size
      _ -> ""
    end
  end

  defp codec(text) do
    cond do
      Regex.match?(~r/hevc|x265|h\.?265/i, text) -> :hevc
      Regex.match?(~r/\bav1\b/i, text) -> :av1
      true -> :other
    end
  end

  defp collapse(parts) do
    parts
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map(&String.replace(&1, ~r/\s+/, " "))
    |> Enum.uniq()
    |> Enum.join(" · ")
  end

  @doc "Remove zero-width/bidi sorting tags and trim a provider's display text."
  def clean(value) when is_binary(value) do
    value
    |> String.replace(@format_chars, "")
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F]/, "")
    |> String.trim()
    |> String.slice(0, 500)
  end

  def clean(_), do: ""

  defp presence(""), do: nil
  defp presence(value), do: value

  # ── choosing and grouping ─────────────────────────────────────────

  @doc """
  The stream to start without asking: the browser can decode it, then language, then the
  sharpest picture up to 1080p (4K only when nothing else is left), then size. `skip` is a
  list of stream ids that already failed.
  """
  def best(streams, caps \\ %{}, skip \\ []) do
    streams
    |> Enum.reject(&(&1.id in skip or not decodable?(&1, caps)))
    |> Enum.min_by(&score/1, fn -> nil end)
  end

  defp decodable?(%{codec: :hevc}, caps), do: caps[:hevc] == true
  defp decodable?(%{codec: :av1}, caps), do: caps[:av1] == true
  defp decodable?(_stream, _caps), do: true

  defp score(s) do
    {language_rank(s.language), Map.get(@qualities, s.quality, 6),
     if(s.codec == :other, do: 0, else: 1), size_gb(s.size), s.url}
  end

  defp language_rank(""), do: 0

  defp language_rank(lang),
    do: if(String.contains?(lang, ["English", "Dual", "Multi"]), do: 0, else: 1)

  defp size_gb(size) do
    case Regex.run(~r/([\d.]+)\s*(GB|MB)/i, size) do
      [_, n, unit] ->
        {v, _} = Float.parse(n)
        if String.upcase(unit) == "MB", do: v / 1024, else: v

      _ ->
        0.0
    end
  end

  @doc "Streams grouped by provider, best quality first: `[{provider_name, [stream]}]`."
  def group(streams) do
    streams
    |> Enum.group_by(& &1.provider)
    |> Enum.map(fn {provider, list} ->
      {provider,
       Enum.sort_by(list, fn s -> {Map.get(@qualities, s.quality, 6), size_gb(s.size)} end)}
    end)
    |> Enum.sort_by(fn {provider, [best | _]} ->
      {Map.get(@qualities, best.quality, 6), provider}
    end)
  end

  @doc "What to tell the viewer when a Nuvio search could not start."
  def message(:not_configured),
    do: "Nuvio is not set up for this account — choose providers in Settings."

  def message(:no_tmdb_id),
    do: "Nuvio providers look titles up by TMDB id, and this title has none."

  def message(:runtime_missing), do: "The Nuvio runtime (Node.js) is not available on the server."
  def message(:timeout), do: "The Nuvio providers did not answer in time."
  def message({:manifest_unavailable, why}), do: "The Nuvio manifest is unavailable: #{why}."
  def message({:http, status}), do: "The Nuvio manifest answered #{status}."
  def message(_), do: "Nuvio could not be searched."

  @doc "A short label for a provider result's state."
  def status_text(%{status: :ok, streams: streams}), do: "#{length(streams)} found"
  def status_text(%{status: :empty}), do: "nothing found"
  def status_text(%{status: :timeout}), do: "timed out"
  def status_text(%{status: :blocked}), do: "not runnable"
  def status_text(%{status: :error}), do: "failed"
  def status_text(_), do: "not searched"
end
