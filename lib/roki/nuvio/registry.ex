defmodule Roki.Nuvio.Registry do
  @moduledoc """
  The All-in-One-Nuvio manifest, as Roki knows it.

  The live manifest is fetched from the repository named in the task and cached for an hour.
  A snapshot committed under `priv/nuvio/manifest.json` is used only when the live fetch
  fails, and the result says which one was used. Provider source is fetched separately,
  validated, hashed and cached; a manifest entry is never enough on its own to run anything.
  """

  alias Roki.Nuvio.{Provider, Validator}
  alias Roki.TTLCache

  @default_url "https://raw.githubusercontent.com/D3adlyRocket/All-in-One-Nuvio/refs/heads/main/manifest.json"
  @manifest_ttl 3_600
  @source_ttl 3_600

  @doc "The manifest URL; `NUVIO_MANIFEST_URL` or application config may override it."
  def manifest_url do
    System.get_env("NUVIO_MANIFEST_URL") ||
      Application.get_env(:roki, :nuvio_manifest_url, @default_url)
  end

  @doc """
  `{:ok, %{url:, origin: :live | :snapshot, fetched_at:, providers:, errors:}}`.
  Never raises on a malformed entry; valid providers are kept and malformed ones reported.
  """
  def manifest(force \\ false) do
    if force, do: forget()

    TTLCache.fetch({:nuvio_manifest, manifest_url()}, @manifest_ttl, fn ->
      fetch_manifest(manifest_url())
    end)
  end

  defp fetch_manifest(url) do
    case Req.get(url, receive_timeout: 20_000, retry: false, redirect: true) do
      {:ok, %{status: 200, body: body}} ->
        case decode_body(body) do
          {:ok, decoded} ->
            case parse_manifest(decoded, url) do
              {:ok, result} -> {:ok, result}
              {:error, _} -> snapshot(url, "the live manifest was not a valid Nuvio manifest")
            end

          _ ->
            snapshot(url, "the live manifest was not JSON")
        end

      {:ok, %{status: status}} ->
        snapshot(url, "the live manifest answered #{status}")

      {:error, reason} ->
        snapshot(url, "the live manifest could not be reached (#{inspect(reason, limit: 2)})")
    end
  end

  defp decode_body(body) when is_map(body), do: {:ok, body}
  defp decode_body(body) when is_binary(body), do: Jason.decode(body)
  defp decode_body(_), do: {:error, :not_json}

  @doc false
  def parse_manifest(%{"scrapers" => scrapers} = body, url) when is_list(scrapers) do
    {providers, errors} =
      scrapers
      |> Enum.reduce({[], []}, fn entry, {ok, bad} ->
        case Provider.from_manifest(entry, url) do
          {:ok, provider} -> {[provider | ok], bad}
          {:error, reason} -> {ok, [{entry_id(entry), reason} | bad]}
        end
      end)

    providers =
      providers
      |> Enum.reverse()
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(&String.downcase(&1.name))

    {:ok,
     %{
       url: url,
       origin: if(body["_snapshot"] == true, do: :snapshot, else: :live),
       name: body["name"] || "All-in-One-Nuvio",
       version: body["version"],
       fetched_at: System.system_time(:second),
       providers: providers,
       errors: Enum.reverse(errors)
     }}
  end

  def parse_manifest(_body, _url), do: {:error, :bad_manifest}

  defp entry_id(%{"id" => id}) when is_binary(id), do: id
  defp entry_id(_), do: "?"

  defp snapshot(url, why) do
    path = :code.priv_dir(:roki) |> to_string() |> Path.join("nuvio/manifest.json")

    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         true <- is_map(decoded),
         {:ok, result} <- parse_manifest(Map.put(decoded, "_snapshot", true), url) do
      {:ok, Map.put(result, :warning, why)}
    else
      _ -> {:error, {:manifest_unavailable, why}}
    end
  end

  @doc "Every provider in the manifest (best effort), or `{:error, reason}`."
  def providers do
    case manifest() do
      {:ok, %{providers: providers}} -> {:ok, providers}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "One provider by manifest id."
  def provider(id) when is_binary(id) do
    with {:ok, providers} <- providers() do
      case Enum.find(providers, &(&1.id == id)) do
        nil -> {:error, :unknown_provider}
        provider -> {:ok, provider}
      end
    end
  end

  def provider(_), do: {:error, :unknown_provider}

  @doc """
  Fetched, validated source for a provider: `{:ok, %{source:, sha256:, verification:, url:}}`
  or `{:error, reasons}`. Only source that passed `Roki.Nuvio.Validator` is returned.
  """
  def source(%Provider{} = provider) do
    key = {:nuvio_source, provider.id, provider.source_url, provider.version}

    TTLCache.fetch(key, @source_ttl, fn ->
      fetch_source(provider)
    end)
  end

  def source(id) when is_binary(id) do
    with {:ok, provider} <- provider(id), do: source(provider)
  end

  defp fetch_source(%Provider{} = provider) do
    case Req.get(provider.source_url,
           receive_timeout: 20_000,
           retry: false,
           redirect: true,
           decode_body: false
         ) do
      {:ok, %{status: 200, body: source}} when is_binary(source) ->
        case Validator.check(source) do
          :ok ->
            {:ok,
             %{
               source: source,
               sha256: :crypto.hash(:sha256, source) |> Base.encode16(case: :lower),
               verification: Validator.verification(source),
               url: provider.source_url
             }}

          {:error, reasons} ->
            {:error, {:rejected, reasons}}
        end

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Whether this provider’s source is present, uses only allowlisted modules, and is safe to sandbox."
  def eligible?(%Provider{} = provider) do
    case source(provider) do
      {:ok, %{verification: verification}} -> {:ok, %{eligible: true, verification: verification}}
      {:error, reason} -> {:ok, %{eligible: false, reason: reason}}
    end
  end

  @doc "Forget the manifest and every provider source; the next call fetches again."
  def forget do
    key = {:nuvio_manifest, manifest_url()}

    case TTLCache.peek(key) do
      {:ok, %{providers: providers}} ->
        Enum.each(providers, fn p ->
          TTLCache.delete({:nuvio_source, p.id, p.source_url, p.version})
        end)

      _ ->
        :ok
    end

    TTLCache.delete(key)
    :ok
  end
end
