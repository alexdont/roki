defmodule RokiWeb.ImageController do
  @moduledoc """
  `/img/:size/:file` (TMDB) and `/img/mal/*path` (MyAnimeList): a picture the site did not hold
  yet. It is fetched, kept in the media library (`Roki.Images`), and the browser is sent on to
  its media address — pages name that address directly from then on.
  """
  use RokiWeb, :controller

  def tmdb(conn, %{"size" => size, "file" => file}), do: serve(conn, size <> "/" <> file)

  def mal(conn, %{"path" => parts}) when is_list(parts),
    do: serve(conn, "mal/" <> Enum.join(parts, "/"))

  defp serve(conn, short) do
    case Roki.Images.ensure(short) do
      {:ok, url} ->
        conn
        |> put_resp_header("cache-control", "public, max-age=86400")
        |> redirect(to: url)

      {:error, :bad_name} ->
        send_resp(conn, 400, "bad request")

      {:error, _reason} ->
        # Not ours to keep this once (the source said no, or was not reachable): the browser
        # gets it from the source.
        case Roki.Images.source_url(short) do
          nil -> send_resp(conn, 404, "no such picture")
          src -> redirect(conn, external: src)
        end
    end
  end
end
