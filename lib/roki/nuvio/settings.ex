defmodule Roki.Nuvio.Settings do
  @moduledoc """
  Per-account Nuvio configuration, kept in the user's `custom_fields` the same way the
  PenguPlay link is kept.

      %{
        "enabled"  => ["vidlink", "purstream"],
        "accepted" => %{"vidlink" => true},
        "options"  => %{"vidlink" => %{"someOption" => "value"}}
      }

  `accepted` is the account's explicit statement that it will use a provider only for
  media it is authorised to access. A provider without it is never searched, even when it
  is enabled in the source list. Options are provider-defined (`onSettings`), read inside
  the sandbox and never from the manifest's claims.
  """

  alias Roki.Nuvio.{Provider, Registry, Sandbox}
  alias Roki.TTLCache

  @field "nuvio"
  @ttl 15

  @doc "The account's Nuvio settings, defaults filled in."
  def get(uuid) when is_binary(uuid) do
    case PhoenixKit.Users.Auth.get_user(uuid) do
      %{custom_fields: fields} -> normalize(fields[@field])
      _ -> normalize(nil)
    end
  rescue
    _ -> normalize(nil)
  end

  def get(_), do: normalize(nil)

  defp normalize(nil), do: %{"enabled" => [], "accepted" => %{}, "options" => %{}}

  defp normalize(%{} = raw) do
    enabled =
      raw["enabled"]
      |> List.wrap()
      |> Enum.filter(&(is_binary(&1) and Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/, &1)))
      |> Enum.uniq()

    accepted =
      case raw["accepted"] do
        %{} = map -> Map.new(map, fn {k, v} -> {k, v == true} end)
        _ -> %{}
      end

    options =
      case raw["options"] do
        %{} = map ->
          Map.new(map, fn {k, v} -> {k, if(is_map(v), do: stringify(v), else: %{})} end)

        _ ->
          %{}
      end

    %{"enabled" => enabled, "accepted" => accepted, "options" => options}
  end

  defp normalize(_), do: normalize(nil)

  defp stringify(map) do
    map
    |> Enum.flat_map(fn
      {k, v} when is_binary(k) and is_binary(v) -> [{k, String.slice(v, 0, 2_000)}]
      {k, v} when is_binary(k) and is_boolean(v) -> [{k, v}]
      {k, v} when is_binary(k) and is_number(v) -> [{k, to_string(v)}]
      _ -> []
    end)
    |> Enum.take(50)
    |> Map.new()
  end

  @doc "The enabled provider ids that the account has also acknowledged."
  def enabled_ids(uuid) do
    settings = get(uuid)

    settings["enabled"]
    |> Enum.filter(&(settings["accepted"][&1] == true))
  end

  @doc "Whether at least one provider is enabled and acknowledged."
  def configured?(uuid) when is_binary(uuid) do
    case TTLCache.fetch({:nuvio_configured, uuid}, @ttl, fn ->
           {:ok, enabled_ids(uuid) != []}
         end) do
      {:ok, value} -> value
      _ -> false
    end
  end

  def configured?(_), do: false

  @doc "Save the account's Nuvio settings. `{:ok, user}` or `{:error, reason}`."
  def save(user, settings) when is_map(settings) do
    merged = normalize(settings)

    case PhoenixKit.Users.Auth.update_user_custom_fields(
           user,
           Map.put(user.custom_fields || %{}, @field, merged)
         ) do
      {:ok, user} ->
        TTLCache.delete({:nuvio_configured, user.uuid})
        Roki.Sources.forget(user.uuid)
        {:ok, user}

      other ->
        other
    end
  end

  @doc "Turn one provider on or off, keeping its acknowledgement and options."
  def set_enabled(user, provider_id, enabled?, accepted?) do
    settings = get(user.uuid)

    enabled =
      if enabled?,
        do: Enum.uniq([provider_id | settings["enabled"]]),
        else: List.delete(settings["enabled"], provider_id)

    accepted = Map.put(settings["accepted"], provider_id, accepted? == true)
    save(user, %{settings | "enabled" => enabled, "accepted" => accepted})
  end

  @doc "Set one provider's options from a form map."
  def set_options(user, provider_id, options) when is_map(options) do
    settings = get(user.uuid)
    options = stringify(options)
    save(user, %{settings | "options" => Map.put(settings["options"], provider_id, options)})
  end

  @doc "A provider's saved options, or `%{}`."
  def options(uuid, provider_id) do
    get(uuid)["options"][provider_id] || %{}
  end

  @doc """
  The fields a provider's `onSettings` returns, normalised for the settings page.
  `{:ok, fields}` (possibly `[]`) or `{:error, reason}`. Cached per provider/version/hash.
  """
  def schema(%Provider{} = provider) do
    if provider.has_settings do
      key = {:nuvio_schema, provider.id, provider.version}

      TTLCache.fetch(key, 3_600, fn -> load_schema(provider) end)
    else
      {:ok, []}
    end
  end

  def schema(id) when is_binary(id) do
    with {:ok, provider} <- Registry.provider(id), do: schema(provider)
  end

  defp load_schema(provider) do
    with {:ok, %{source: source}} <- Registry.source(provider) do
      case Sandbox.settings(source) do
        {:ok, result} -> {:ok, normalize_fields(result["settings"])}
        # The manifest's `hasSettings` flag is not always backed by an `onSettings` export.
        {:error, {:provider, "onSettings is not exported"}} -> {:ok, []}
        {:error, _} = error -> error
      end
    end
  end

  @doc false
  def normalize_fields(fields) when is_list(fields) do
    fields
    |> Enum.map(&normalize_field/1)
    |> Enum.reject(&is_nil/1)
  end

  def normalize_fields(_), do: []

  defp normalize_field(%{"type" => "header", "label" => label} = f) when is_binary(label) do
    %{type: :header, label: label, description: text(f["description"])}
  end

  defp normalize_field(%{} = f) do
    key = f["key"]
    type = f["type"]

    if is_binary(key) and Regex.match?(~r/^[A-Za-z0-9_.-]{1,64}$/, key) do
      type =
        if type in ["select", "toggle", "password", "number"],
          do: String.to_atom(type),
          else: :text

      %{
        type: type,
        key: key,
        label: text(f["label"]) || key,
        description: text(f["description"]),
        placeholder: text(f["placeholder"]),
        secret: f["isPassword"] == true,
        default: default_value(f),
        options: normalize_options(f["options"])
      }
    end
  end

  defp normalize_field(_), do: nil

  defp default_value(f), do: f["defaultValue"] || f["default"]

  defp normalize_options(options) when is_list(options) do
    for %{} = o <- options,
        is_binary(o["label"]),
        is_binary(o["value"]) or is_number(o["value"]) do
      %{label: o["label"], value: to_string(o["value"])}
    end
  end

  defp normalize_options(_), do: []

  defp text(v) when is_binary(v), do: v
  defp text(_), do: nil

  @doc "The acknowledgement every provider requires in the interface."
  def authorization_notice do
    "Roki does not grant access to anything. Enable a provider only for media you are " <>
      "authorised to watch, and only where using that provider is lawful for you. Roki does " <>
      "not decrypt DRM or bypass an access control; streams that require either will not play."
  end
end
