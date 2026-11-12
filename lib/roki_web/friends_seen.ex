defmodule RokiWeb.FriendsSeen do
  @moduledoc """
  `on_mount` for the site's LiveViews: how many of the signed-in person's friends have seen
  each title (`@friends_seen`, `%{{type, id} => n}` from `Roki.Friends.seen/1`), so a poster
  can wear a small count and the hover card can say who. Empty for a visitor and before the
  socket is connected.
  """
  import Phoenix.Component, only: [assign: 3]

  alias PhoenixKit.Users.Auth.Scope

  def on_mount(:assign, _params, _session, socket) do
    seen =
      with true <- Phoenix.LiveView.connected?(socket),
           scope when not is_nil(scope) <- socket.assigns[:phoenix_kit_current_scope],
           true <- Scope.authenticated?(scope) do
        Roki.Friends.seen(Scope.user_uuid(scope))
      else
        _ -> %{}
      end

    {:cont, assign(socket, :friends_seen, seen)}
  end
end
