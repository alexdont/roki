defmodule RokiWeb.PlayerMode do
  @moduledoc """
  `on_mount` for the site's LiveViews: the Browser / External switch in the header (see
  `RokiWeb.Layouts.player_toggle/1`) sends `set_mode` from every page. A page that plays things
  keeps a `@mode` and answers the event itself (its list follows the player); on any other page
  this just remembers the choice in the browser, so the switch works everywhere.
  """
  import Phoenix.LiveView, only: [attach_hook: 4, push_event: 3]

  # Accounts made from this day on start with the browser player; earlier ones keep the external
  # player (VLC) they have been using unless they chose otherwise. Either way the switch in the
  # header, remembered per device, wins.
  @browser_default_from ~U[2026-10-24 00:00:00Z]

  @doc "The player a device with no remembered choice starts with, for this account: `\"browser\"` or `\"external\"`."
  def default_for(%{inserted_at: %DateTime{} = at}),
    do: if(DateTime.compare(at, @browser_default_from) == :lt, do: "external", else: "browser")

  def default_for(_user), do: "external"

  def on_mount(:attach, _params, _session, socket) do
    {:cont, attach_hook(socket, :player_mode, :handle_event, &handle/3)}
  end

  defp handle("set_mode", %{"mode" => mode}, socket) when mode in ["browser", "external"] do
    if Map.has_key?(socket.assigns, :mode),
      do: {:cont, socket},
      else: {:halt, push_event(socket, "roki:player", %{mode: mode})}
  end

  defp handle(_event, _params, socket), do: {:cont, socket}
end
