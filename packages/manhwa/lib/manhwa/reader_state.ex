defmodule Manhwa.ReaderState do
  @moduledoc """
  Normalized access to the per-series state map returned by
  `c:Manhwa.Store.reader_state/2`, plus the settings resolution
  cascade (package default → saved setting → per-device slot →
  transient URL override — the URL layer is applied by the
  controllers).
  """

  @doc "Fetch a key off the (possibly nil) state map/struct."
  def get(nil, _key), do: nil
  def get(state, key) when is_struct(state), do: Map.get(state, key)
  def get(state, key) when is_map(state), do: Map.get(state, key)

  @doc """
  Reading mode for the resolved device — the per-device slot wins,
  falling back to the generic field. `nil` when nothing is saved.
  """
  def effective_reading_mode(nil, _device), do: nil

  def effective_reading_mode(state, "mobile"),
    do: get(state, :reading_mode_mobile) || get(state, :reading_mode)

  def effective_reading_mode(state, _device),
    do: get(state, :reading_mode_desktop) || get(state, :reading_mode)

  @doc "Tap-zone preset for the resolved device, same fallback shape."
  def effective_tap_zone_preset(nil, _device), do: nil

  def effective_tap_zone_preset(state, "mobile"),
    do: get(state, :tap_zone_preset_mobile) || get(state, :tap_zone_preset)

  def effective_tap_zone_preset(state, _device),
    do: get(state, :tap_zone_preset_desktop) || get(state, :tap_zone_preset)

  @doc """
  Resolve `"mobile"` / `"desktop"` for the request. Priority: explicit
  `?device=` param → User-Agent sniff → `"desktop"`.
  """
  def device_kind(conn, params) do
    case params["device"] do
      "mobile" -> "mobile"
      "desktop" -> "desktop"
      _ -> device_from_ua(conn)
    end
  end

  defp device_from_ua(conn) do
    ua = conn |> Plug.Conn.get_req_header("user-agent") |> List.first() || ""
    if Regex.match?(~r/Mobi|Android|iPhone|iPad|iPod/i, ua), do: "mobile", else: "desktop"
  end

  @doc ~S"""
  The device slot a settings write should target: explicit
  `device=mobile|desktop|all` form field wins; otherwise UA detection,
  so in-reader toggles update the slot the user is actually on.
  """
  def effective_update_device(conn, params) do
    case normalize_device(params["device"]) do
      nil -> device_kind(conn, params)
      d -> d
    end
  end

  def normalize_device("mobile"), do: "mobile"
  def normalize_device("desktop"), do: "desktop"
  def normalize_device("all"), do: "all"
  def normalize_device(_), do: nil
end
