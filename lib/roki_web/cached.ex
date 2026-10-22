defmodule RokiWeb.Cached do
  @moduledoc """
  `on_mount` for the site's LiveViews: which titles have cached sources for the signed-in
  user (`@cached_titles`, a `MapSet` of `{type, id}`), so a poster can say "cached".
  Nothing is read for a visitor or before the socket is connected.
  """
  import Phoenix.Component, only: [assign: 3]

  alias PhoenixKit.Users.Auth.Scope
  alias Roki.Watch.SourceCache

  def on_mount(:assign_titles, _params, _session, socket) do
    titles =
      with true <- Phoenix.LiveView.connected?(socket),
           scope when not is_nil(scope) <- socket.assigns[:phoenix_kit_current_scope],
           true <- Scope.authenticated?(scope),
           uuid = Scope.user_uuid(scope),
           true <- Roki.Laev.connected?(uuid) do
        hours = SourceCache.hours(Roki.Laev.web_settings(uuid))

        for {type, id, _s, _e} <- SourceCache.keys(uuid, hours),
            into: MapSet.new(),
            do: {type, id}
      else
        _ -> MapSet.new()
      end

    {:cont, assign(socket, :cached_titles, titles)}
  end
end
