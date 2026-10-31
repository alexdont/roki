defmodule Roki.Pengu do
  @moduledoc """
  PenguPlay as a Stremio addon: an account's install link (copied from pengu.uk — its path carries
  the provider and quality settings and an auth token, so it is a secret) answers
  `<base>/stream/{movie|series}/{imdb}[:season:episode].json` with the releases its providers
  found. Nothing here scrapes — the addon does; this asks, tidies the answer and groups it.

  Whose link is used: the account's own (saved in Settings, in its `custom_fields`); failing that,
  the key owner's, when the owner has lent it to the account (`Roki.Keys.pengu_lent?/1`) — then
  every real search counts against the account's daily cap. Neither: PenguPlay is not offered.

  A stream is `%{provider:, quality:, language:, size:, label:, url:, kind:, headers:, subtitles:}`
  where `kind` is `:hls` or `:file`. Entries with no `url` (the donate banner, magnets) are dropped.
  """

  alias Roki.{Keys, TTLCache}

  @ttl 600
  @timeout 45_000
  @qualities ~w(4K 2160P 1440P 1080P 720P 480P 360P)
  @field "pengu_addon_url"

  # ── whose link ─────────────────────────────────────────────────────

  @doc "`{:own, base}`, `{:lent, base}` or nil: which link this account searches with."
  def account(uuid) when is_binary(uuid) do
    case own_base(uuid) do
      nil -> if Keys.pengu_lent?(uuid), do: lent(), else: nil
      base -> {:own, base}
    end
  end

  def account(_), do: nil

  # The key owner's own link, as what a lent account searches with.
  defp lent do
    case own_base(Keys.config().owner_uuid) do
      nil -> nil
      base -> {:lent, base}
    end
  end

  @doc "Whether PenguPlay can be used by this account at all."
  def configured?(uuid), do: account(uuid) != nil

  # The link this account saved, as a base (without `/manifest.json`), or nil.
  defp own_base(uuid) when is_binary(uuid) do
    case TTLCache.fetch({:pengu_own, uuid}, 15, fn -> {:ok, read_own(uuid)} end) do
      {:ok, base} -> base
      _ -> nil
    end
  end

  defp own_base(_), do: nil

  defp read_own(uuid) do
    case PhoenixKit.Users.Auth.get_user(uuid) do
      %{custom_fields: %{@field => url}} when is_binary(url) and url != "" -> base_of(url)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp base_of(url), do: url |> String.trim() |> String.trim_trailing("/manifest.json") |> String.trim_trailing("/")

  @doc """
  Save the link pasted in Settings. It must be a `https://pengu.uk/…/manifest.json` address whose
  manifest answers as PenguPlay. `{:ok, user}` or `{:error, text}`.
  """
  def save_url(user, pasted) when is_binary(pasted) do
    url = String.trim(pasted)

    with :ok <- valid_url(url),
         :ok <- check_manifest(url),
         {:ok, user} <-
           PhoenixKit.Users.Auth.update_user_custom_fields(
             user,
             Map.put(user.custom_fields || %{}, @field, url)
           ) do
      TTLCache.delete({:pengu_own, user.uuid})
      Roki.Sources.forget(user.uuid)
      {:ok, user}
    else
      {:error, text} when is_binary(text) -> {:error, text}
      _ -> {:error, "Could not save that link."}
    end
  end

  @doc "Forget the link this account saved."
  def remove_url(user) do
    result =
      PhoenixKit.Users.Auth.update_user_custom_fields(user, Map.delete(user.custom_fields || %{}, @field))

    TTLCache.delete({:pengu_own, user.uuid})
    Roki.Sources.forget(user.uuid)
    result
  end

  defp valid_url(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: "pengu.uk", path: "/" <> _ = path} ->
        if String.ends_with?(path, "/manifest.json"),
          do: :ok,
          else: {:error, "That is not the manifest link — it should end in /manifest.json."}

      _ ->
        {:error, "Paste the install link from pengu.uk (https://pengu.uk/…/manifest.json)."}
    end
  end

  defp check_manifest(url) do
    case Req.get(url, receive_timeout: 15_000, retry: false) do
      {:ok, %{status: 200, body: %{"id" => "com.penguplay"}}} -> :ok
      {:ok, %{status: 200}} -> {:error, "That link is not a PenguPlay manifest."}
      {:ok, %{status: s}} -> {:error, "PenguPlay answered #{s} for that link."}
      {:error, _} -> {:error, "PenguPlay could not be reached to check the link."}
    end
  end

  @doc "`%{kind: :own | :lent | nil, used:, cap:}` — what Settings says about this account's PenguPlay."
  def status(uuid) do
    case account(uuid) do
      {:lent, _} -> %{kind: :lent, used: Keys.pengu_today(uuid), cap: Keys.pengu_cap(uuid)}
      {:own, _} -> %{kind: :own, used: nil, cap: nil}
      nil -> %{kind: nil, used: nil, cap: nil}
    end
  end

  # ── searching ──────────────────────────────────────────────────────

  @doc "`{:ok, [stream]}` for a film (`season`/`episode` nil) or an episode, or `{:error, reason}`."
  def streams(uuid, imdb_id, season \\ nil, episode \\ nil)

  def streams(uuid, imdb_id, season, episode) when is_binary(imdb_id) do
    case account(uuid) do
      nil ->
        {:error, :not_configured}

      {kind, base} ->
        # Kept per link, so accounts on the same one share a search and nobody sees another's.
        TTLCache.fetch({:pengu, :erlang.phash2(base), imdb_id, season, episode}, @ttl, fn ->
          cond do
            kind == :lent and not Keys.pengu_allowed?(uuid) ->
              {:error, :cap}

            true ->
              if kind == :lent, do: Keys.record_pengu(uuid)
              fetch(base, imdb_id, season, episode)
          end
        end)
    end
  end

  def streams(_, _, _, _), do: {:error, :no_imdb_id}

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
  def message(:not_configured), do: "PenguPlay is not set up for this account — add your link in Settings."
  def message(:cap), do: "Today's PenguPlay searches on the shared link are used up. Add your own PenguPlay link in Settings for no limit."
  def message(:no_imdb_id), do: "This title has no IMDb id, which PenguPlay looks titles up by."
  def message({:http, status}), do: "PenguPlay answered #{status}."
  def message(:timeout), do: "PenguPlay did not answer in time."
  def message(_), do: "PenguPlay could not be reached."
end
