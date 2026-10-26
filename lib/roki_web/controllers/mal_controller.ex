defmodule RokiWeb.MalController do
  @moduledoc """
  Where MyAnimeList sends people back after they approve the site's app:
  `/mal/callback?code=…&state=…`. The login the settings page began (`Roki.Laev.mal_begin/1`)
  is finished with the code, and the settings page is shown again, saying how it went.
  """
  use RokiWeb, :controller

  plug :fetch_flash

  def callback(conn, _params) do
    case conn.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} when is_binary(uuid) ->
        {kind, text} =
          case Roki.Laev.mal_finish(uuid, "?" <> conn.query_string) do
            {:ok, name} -> {:info, "MyAnimeList connected as #{name}."}
            {:error, why} -> {:error, "MyAnimeList: #{why}"}
          end

        conn |> put_flash(kind, text) |> redirect(to: ~p"/account/services")

      _ ->
        redirect(conn, to: "/phoenix_kit/users/log-in")
    end
  end
end
