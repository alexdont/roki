defmodule Manhwa.Config do
  @moduledoc """
  Runtime configuration access for the reader packages.

  All function-shaped options are `{module, function}` tuples so they
  can live in compile-time config files.

      config :manhwa,
        store: MyApp.ReaderStore,                       # required
        annotations: MyApp.ReaderAnnotations,           # optional
        gif_provider: MyApp.ReaderGifs,                 # optional
        etcher_host: MyAppWeb.EtcherHostLive,           # optional LiveView
        current_user: {MyAppWeb.ReaderGlue, :current_user},   # (conn) -> user
        etcher_session: {MyAppWeb.ReaderGlue, :etcher_session}, # (conn, user) -> map
        series_url: {MyAppWeb.ReaderGlue, :series_url},        # (series) -> path
        legacy_url: {MyAppWeb.ReaderGlue, :legacy_url}         # (series, chapter) -> path | nil
  """

  def store do
    Application.get_env(:manhwa, :store) ||
      raise "config :manhwa, store: MyApp.ReaderStore is required"
  end

  def annotations, do: Application.get_env(:manhwa, :annotations)
  def gif_provider, do: Application.get_env(:manhwa, :gif_provider)

  @doc """
  The LiveView module embedded (via `live_render/3`) to host the Etcher
  annotation layer and whatever comment UI the host wants. `nil` (the
  default) renders no annotation layer.
  """
  def etcher_host, do: Application.get_env(:manhwa, :etcher_host)

  @doc "Resolve the current user from the conn. Default: `conn.assigns[:current_user]`."
  def current_user(conn) do
    case Application.get_env(:manhwa, :current_user) do
      {m, f} -> apply(m, f, [conn])
      nil -> conn.assigns[:current_user]
    end
  end

  @doc """
  Extra session entries for the etcher-host LiveView (e.g. an auth
  token so the LiveView can re-load the user). Merged over the
  package-provided keys (`fresco_id`, `series`, `chapter`, and — for
  two-segment series — `source`/`slug`).
  """
  def etcher_session(conn, user) do
    case Application.get_env(:manhwa, :etcher_session) do
      {m, f} -> apply(m, f, [conn, user])
      nil -> %{}
    end
  end

  @doc "Host page for a series (the reader's Home / details link). Default `/`."
  def series_url(series) do
    case Application.get_env(:manhwa, :series_url) do
      {m, f} -> apply(m, f, [series])
      nil -> "/"
    end
  end

  @doc "Optional link to an alternate/legacy reader, shown in settings when present."
  def legacy_url(series, chapter) do
    case Application.get_env(:manhwa, :legacy_url) do
      {m, f} -> apply(m, f, [series, chapter])
      nil -> nil
    end
  end

  @doc """
  Debug-log sink for on-device telemetry (iOS Safari sessions without
  DevTools). `nil` disables the endpoint body (it still 200s). Set a
  file path to append JSON lines.
  """
  def debug_log_path, do: Application.get_env(:manhwa, :debug_log_path)

  @doc """
  Optional `{module, function}` rendering extra head content on the
  strip reader page (a function component taking an assigns map) —
  e.g. an OCR runtime script tag powering the smart auto-reader.
  """
  def extra_head, do: Application.get_env(:manhwa, :extra_head)

  @doc """
  How far into a chapter (percent, 0–100) the reader must be before
  the host-confirmed read checkmark first appears in the progress
  pill — it latches per chapter once shown. The mark itself only ever
  shows for chapters the Store reported `chapter_read: true` for, so
  this is purely a display gate. Default `95` (the last 5%).

      config :manhwa, read_check_percent: 90
  """
  def read_check_percent do
    case Application.get_env(:manhwa, :read_check_percent, 95) do
      n when is_number(n) and n >= 0 and n <= 100 -> n
      _ -> 95
    end
  end

  @doc """
  The mark rendered in the progress pill when a chapter is confirmed
  read — any short string or emoji. Default `"✓"`.

      config :manhwa, read_check_mark: "read"
  """
  def read_check_mark do
    case Application.get_env(:manhwa, :read_check_mark, "✓") do
      s when is_binary(s) and s != "" -> s
      _ -> "✓"
    end
  end
end
