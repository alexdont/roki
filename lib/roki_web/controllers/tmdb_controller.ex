defmodule RokiWeb.TmdbController do
  @moduledoc """
  Linking a person's own TMDB account, so what they rate is saved on it.

  `/tmdb/link?return=…` asks TMDB for a login and sends the browser there to approve;
  `/tmdb/callback?request_token=…&approved=true` is where TMDB sends it back, and the session is
  saved on the signed-in account only (`Roki.Laev.tmdb_finish/2`).
  """
  use RokiWeb, :controller

  plug :fetch_flash

  def link(conn, params) do
    case conn.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} when is_binary(uuid) ->
        return_to = safe_path(params["return"])

        case Roki.RateLimit.check(:tmdb_link, {:user, uuid}, 10, 60_000) do
          :ok ->
            case Roki.Laev.tmdb_begin(uuid, return_to) do
              {:ok, url} -> redirect(conn, external: url)
              {:error, why} -> conn |> put_flash(:error, why) |> redirect(to: return_to)
            end

          _ ->
            conn |> put_flash(:error, "Slow down, then try again.") |> redirect(to: return_to)
        end

      _ ->
        redirect(conn, to: "/phoenix_kit/users/log-in")
    end
  end

  def callback(conn, params) do
    case conn.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} when is_binary(uuid) ->
        result =
          if params["approved"] == "true",
            do: Roki.Laev.tmdb_finish(uuid, params["request_token"]),
            else: {:error, "TMDB was not approved. Start again when you are ready.", nil}

        case result do
          {:ok, return_to} ->
            conn
            |> put_flash(:info, "TMDB linked. Your ratings are saved there now.")
            |> redirect(to: safe_path(return_to))

          {:error, why, return_to} ->
            conn |> put_flash(:error, why) |> redirect(to: safe_path(return_to))
        end

      _ ->
        redirect(conn, to: "/phoenix_kit/users/log-in")
    end
  end

  # Only a path on this site, so the link cannot send anyone elsewhere.
  defp safe_path("/" <> rest = path) do
    if String.starts_with?(rest, "/") or String.contains?(path, "\\"), do: "/", else: path
  end

  defp safe_path(_), do: "/"
end
