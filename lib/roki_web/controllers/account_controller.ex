defmodule RokiWeb.AccountController do
  @moduledoc """
  PhoenixKit's account menu links "Settings" to its own profile page. On this site Settings
  means playback, languages, keys and sync — so that link lands on the user's settings page
  here. The profile page itself (name, email, password) is still at
  `/phoenix_kit/profile/settings`, which the settings page links to.
  """
  use RokiWeb, :controller

  def settings(conn, _params) do
    case conn.assigns[:phoenix_kit_current_user] do
      %{username: name} when is_binary(name) and name != "" ->
        redirect(conn, to: ~p"/#{name}/settings")

      _ ->
        redirect(conn, to: "/phoenix_kit/users/log-in")
    end
  end
end
