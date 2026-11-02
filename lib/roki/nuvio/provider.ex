defmodule Roki.Nuvio.Provider do
  @moduledoc """
  One scraper listed by the All-in-One-Nuvio manifest.

  A provider is metadata only: the manifest says where its JavaScript lives, which media
  types it claims, and whether it has options. Whether Roki will actually run it is decided
  separately — `Roki.Nuvio.Validator` reads the source, and `Roki.Nuvio.Sandbox` runs it in
  an isolated Node process. Nothing here trusts the manifest's claims.
  """

  @enforce_keys [:id, :name, :filename]
  defstruct [
    :id,
    :name,
    :description,
    :version,
    :author,
    :supported_types,
    :filename,
    :enabled,
    :has_settings,
    :limited,
    :formats,
    :logo,
    :content_language,
    :source_url,
    :manifest_url,
    :sha256,
    :verification,
    :eligibility
  ]

  @type t :: %__MODULE__{}

  @valid_id ~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/

  @doc """
  Build a provider from one manifest entry, relative to the manifest's own address.
  `{:ok, provider}` or `{:error, reason}`; one bad entry never discards the whole manifest.
  """
  def from_manifest(%{} = m, manifest_url) when is_binary(manifest_url) do
    with {:ok, id} <- id(m),
         {:ok, name} <- name(m),
         {:ok, filename} <- filename(m),
         {:ok, source_url} <- source_url(manifest_url, filename) do
      {:ok,
       %__MODULE__{
         id: id,
         name: name,
         description: string(m["description"]),
         version: string(m["version"]),
         author: string(m["author"]),
         supported_types: list(m["supportedTypes"]),
         filename: filename,
         enabled: m["enabled"] != false,
         has_settings: m["hasSettings"] == true,
         limited: m["limited"] == true,
         formats: list(m["formats"]),
         logo: string(m["logo"]),
         content_language: list(m["contentLanguage"]),
         source_url: source_url,
         manifest_url: manifest_url,
         verification: :unchecked,
         eligibility: :unchecked
       }}
    end
  end

  def from_manifest(_entry, _manifest_url), do: {:error, :not_an_object}

  defp id(%{"id" => id}) when is_binary(id) do
    id = String.trim(id)
    if Regex.match?(@valid_id, id), do: {:ok, id}, else: {:error, {:bad_id, id}}
  end

  defp id(_), do: {:error, :missing_id}

  defp name(%{"name" => name}) when is_binary(name) do
    name = String.trim(name)
    if name == "", do: {:error, :missing_name}, else: {:ok, name}
  end

  defp name(_), do: {:error, :missing_name}

  # Only a relative `providers/<name>.js` path. No absolute URLs, no traversal, no other
  # extensions: the manifest may not point the runner at anything but a JavaScript file
  # beside itself in the provider directory.
  defp filename(%{"filename" => filename}) when is_binary(filename) do
    filename = String.trim(filename)

    cond do
      not String.starts_with?(filename, "providers/") ->
        {:error, {:bad_filename, filename}}

      String.contains?(filename, ["..", "\\", "\0", "%", "?", "#"]) ->
        {:error, {:bad_filename, filename}}

      not String.ends_with?(filename, ".js") ->
        {:error, {:bad_filename, filename}}

      String.length(filename) > 160 ->
        {:error, {:bad_filename, filename}}

      true ->
        {:ok, filename}
    end
  end

  defp filename(_), do: {:error, :missing_filename}

  @doc "Where the provider's source is fetched from: the manifest's directory plus its relative name."
  def source_url(manifest_url, filename) do
    base = manifest_url |> URI.parse() |> Map.put(:query, nil) |> Map.put(:fragment, nil)

    with %URI{scheme: "https", host: host} when is_binary(host) <- base,
         true <- trusted_host?(host),
         %URI{scheme: "https", host: ^host} = url <- URI.merge(base, filename),
         true <- String.starts_with?(url.path || "", "/") do
      {:ok, URI.to_string(url)}
    else
      _ -> {:error, {:untrusted_source, filename}}
    end
  rescue
    _ -> {:error, {:untrusted_source, filename}}
  end

  @doc "Only the manifest's own GitHub raw host is trusted for provider source."
  def trusted_host?(host), do: host == "raw.githubusercontent.com"

  @doc "Whether this provider claims it handles `movie` or `tv`."
  def supports?(%__MODULE__{supported_types: types}, type) when type in ["movie", "tv"] do
    types == [] or type in types or (type == "tv" and "series" in types)
  end

  def supports?(_provider, _type), do: false

  @doc "The manifest's platform badge: providers flagged `limited` are shown as such."
  def badge(%__MODULE__{limited: true}), do: "limited"
  def badge(%__MODULE__{has_settings: true}), do: "options"
  def badge(_), do: nil

  defp string(v) when is_binary(v), do: v
  defp string(_), do: nil

  defp list(v) when is_list(v), do: Enum.filter(v, &is_binary/1)
  defp list(_), do: []
end
