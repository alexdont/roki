defmodule RokiWeb.PlayerMode do
  @moduledoc """
  `on_mount` for the site's LiveViews: the Browser / External switch in the header (see
  `RokiWeb.Layouts.player_toggle/1`) sends `set_mode` from every page. A page that plays things
  keeps a `@mode` and answers the event itself (its list follows the player); on any other page
  this just remembers the choice in the browser, so the switch works everywhere.
  """
  import Phoenix.LiveView, only: [attach_hook: 4, push_event: 3]

  @doc """
  The player a device with no remembered choice starts with: always `"external"` (VLC, mpv — it costs
  the server nothing). The browser player is a choice, and only for accounts allowed it
  (`Roki.Keys.browser?/1`). A choice made with the switch in the header, remembered per device, wins.
  """
  def default_for(_user), do: "external"

  def on_mount(:attach, _params, _session, socket) do
    {:cont, attach_hook(socket, :player_mode, :handle_event, &handle/3)}
  end

  defp handle("set_mode", %{"mode" => mode}, socket) when mode in ["browser", "external"] do
    if Map.has_key?(socket.assigns, :mode),
      do: {:cont, socket},
      else: {:halt, push_event(socket, "roki:player", %{mode: mode})}
  end

  # The account menu's Torrents / PenguPlay switch: the "Play from" setting, saved to the account.
  defp handle("set_play_from", %{"to" => to}, socket) when to in ["torrent", "pengu"] do
    with scope when not is_nil(scope) <- socket.assigns[:phoenix_kit_current_scope],
         uuid when is_binary(uuid) <- PhoenixKit.Users.Auth.Scope.user_uuid(scope),
         true <- Roki.Sources.available(uuid)[String.to_existing_atom(to)],
         :ok <- Roki.Laev.put_web_setting(uuid, "play_from", to) do
      {:halt, push_event(socket, "roki:source", %{value: to})}
    else
      _ -> {:halt, socket}
    end
  end

  defp handle(_event, _params, socket), do: {:cont, socket}
end
