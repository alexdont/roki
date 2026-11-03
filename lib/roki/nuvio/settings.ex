defmodule Roki.Nuvio.Settings do
  @moduledoc """
  Per-account Nuvio configuration, kept in the user's `custom_fields` the same way the
  PenguPlay link is kept.

      %{
        "enabled"  => ["purstream"],            # switched on by the account
        "disabled" => ["movix"],                # defaults the account switched off
        "options"  => %{"vidlink" => %{"someOption" => "value"}}
      }

  Every account starts with `defaults/0` on, so Nuvio plays without a visit to Settings;
  `enabled_ids/1` is the account's own choices first, then the defaults it has not switched
  off. Defaults are kept apart from `enabled` so a default added later reaches every account.
  Options are
  provider-defined (`onSettings`), read inside the sandbox and never from the manifest's
  claims. (An older `accepted` map, from when each provider needed a separate
  acknowledgement, is dropped on the next save.)
  """

  alias Roki.Nuvio.{Provider, Registry, Sandbox}
  alias Roki.TTLCache

  @field "nuvio"
  @ttl 15

  # On for every account until it switches one off. Picked by a live probe on 2026-11-02
  # (The Matrix, Oppenheimer, Breaking Bad 1x1, The Last of Us 2x1: every title found, the
  # streams answered with real media, under ten seconds): playimdb (English original audio,
  # HLS), vidrock (HLS, two servers), movix (dual-audio HLS), moviebox (MP4 in several audio
  # languages, Russian among them). See dev_docs/nuvio-compatibility.md.
  @defaults ~w(playimdb vidrock movix moviebox)

  @doc "The providers every account has on unless it switched them off."
  def defaults, do: @defaults

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

  defp normalize(nil), do: %{"enabled" => [], "disabled" => [], "options" => %{}}

  defp normalize(%{} = raw) do
    enabled = ids(raw["enabled"])
    disabled = ids(raw["disabled"])

    options =
      case raw["options"] do
        %{} = map ->
          Map.new(map, fn {k, v} -> {k, if(is_map(v), do: stringify(v), else: %{})} end)

        _ ->
          %{}
      end

    %{"enabled" => enabled, "disabled" => disabled, "options" => options}
  end

  defp normalize(_), do: normalize(nil)

  defp ids(list) do
    list
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/, &1)))
    |> Enum.uniq()
  end

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

  @doc """
  The provider ids the account has on: its own, most recently enabled first, then the
  defaults it has not switched off.
  """
  def enabled_ids(uuid), do: active(get(uuid))

  @doc false
  def active(settings) do
    Enum.uniq(settings["enabled"] ++ (@defaults -- settings["disabled"]))
  end

  @doc "Whether at least one provider is enabled."
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

  @doc "Turn one provider on or off, keeping its options."
  def set_enabled(user, provider_id, enabled?) do
    settings = get(user.uuid)

    {enabled, disabled} =
      cond do
        enabled? and provider_id in @defaults ->
          {settings["enabled"], List.delete(settings["disabled"], provider_id)}

        enabled? ->
          {Enum.uniq([provider_id | settings["enabled"]]), settings["disabled"]}

        provider_id in @defaults ->
          {List.delete(settings["enabled"], provider_id),
           Enum.uniq([provider_id | settings["disabled"]])}

        true ->
          {List.delete(settings["enabled"], provider_id), settings["disabled"]}
      end

    save(user, %{settings | "enabled" => enabled, "disabled" => disabled})
  end

  @doc "Back to `defaults/0` and nothing else; each provider's options are kept."
  def reset_providers(user) do
    settings = get(user.uuid)
    save(user, %{settings | "enabled" => [], "disabled" => []})
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

  @doc "The notice shown above the provider list."
  def authorization_notice do
    "Roki does not grant access to anything. Enable a provider only for media you are " <>
      "authorised to watch, and only where using that provider is lawful for you. Roki does " <>
      "not decrypt DRM or bypass an access control; streams that require either will not play."
  end
end
