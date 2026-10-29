defmodule RokiWeb.ReaderGlue do
  @moduledoc """
  The app-side glue functions the `manhwa`/`manga` reader packages call
  via `config :manhwa` — user resolution, host-page links, the
  etcher-host session extras, and the strip reader's OCR head scripts.
  """

  use Phoenix.Component

  def current_user(conn), do: conn.assigns[:phoenix_kit_current_user]

  @doc """
  Extra session for `RokiWeb.Live.EtcherHostLive` — it re-loads
  the user from the session token (live_render mounts can't use
  PhoenixKit's on_mount helpers).
  """
  def etcher_session(conn, user) do
    %{
      "user_id" => user && user.uuid,
      "user_token" => Plug.Conn.get_session(conn, "user_token")
    }
  end

  # The reader came from an app where a series lived under /reader/manga/…, which the port
  # rewrote to /manga/manga/… — one segment too many for this app, where it is /manga/…. Same
  # for the legacy link.
  def series_url([source, slug]), do: "/manga/#{source}/#{slug}"

  def legacy_url([source, slug], chapter),
    do: "/manga/legacy/#{source}/#{slug}/#{chapter}"

  @doc "OCR runtime for the strip reader's smart auto-reader."
  def strip_head(assigns) do
    ~H"""
    <TesseractJs.Component.preload />
    <TesseractJs.Component.script />
    <%!-- Hide Etcher's auto-added nav buttons (pencil + eye). This reader
         surfaces annotation-mode and comments-visibility in its own toolbar,
         so all controls live in one place — same policy the app's other two
         readers apply in their own templates.

         Both wrapper classes: the canvas viewer uses fresco's `.fresco-nav`,
         the strip its own sticky `.fresco-strip-nav`. Etcher attaches via
         `handle.appendNavButton`, which sets `title` on the button, so the
         titles are the stable hook. They were invisible until fresco_strip
         0.3.0 — before that the strip passed `navEl: null` and dropped them. --%>
    <style>
      .fresco-nav button[title="Annotate"],
      .fresco-nav button[title="Hide annotations"],
      .fresco-nav button[title="Show annotations"],
      .fresco-strip-nav button[title="Annotate"],
      .fresco-strip-nav button[title="Hide annotations"],
      .fresco-strip-nav button[title="Show annotations"] {
        display: none !important;
      }
    </style>
    """
  end
end
