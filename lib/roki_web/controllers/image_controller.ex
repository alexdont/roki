defmodule RokiWeb.ImageController do
  @moduledoc """
  `/img/:size/:file` — a TMDB picture from the site's own copy (`Roki.Images`), fetched from
  TMDB the first time it is asked for. A picture never changes under its name, so the browser
  may keep it for a month.
  """
  use RokiWeb, :controller

  def show(conn, %{"size" => size, "file" => file}) do
    case Roki.Images.file(size, file) do
      {:ok, path} ->
        conn
        |> put_resp_content_type(Roki.Images.content_type(file))
        |> put_resp_header("cache-control", "public, max-age=2592000, immutable")
        |> send_file(200, path)

      {:error, reason} when reason in [:bad_size, :bad_name] ->
        send_resp(conn, 400, "bad request")

      {:error, _reason} ->
        # Not ours to keep (TMDB said no, or was not reachable): the browser gets it from TMDB this once.
        redirect(conn, external: "https://image.tmdb.org/t/p/#{size}/#{file}")
    end
  end
end
