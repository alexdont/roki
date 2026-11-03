defmodule RokiWeb.AccountController do
  @moduledoc """
  `/account/services` — the signed-in user's playback and services page (`/:username/settings`).
  PhoenixKit's account menu keeps its own Settings (profile, email, password); this is the
  shortcut to the page that is specific to this site.
  """
  use RokiWeb, :controller

  def services(conn, _params) do
    case conn.assigns[:phoenix_kit_current_user] do
      %{username: name} when is_binary(name) and name != "" ->
        redirect(conn, to: ~p"/u/#{name}/settings")

      _ ->
        redirect(conn, to: "/phoenix_kit/users/log-in")
    end
  end
end
