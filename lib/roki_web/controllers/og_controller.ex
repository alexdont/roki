defmodule RokiWeb.OgController do
  @moduledoc """
  The social cards (`Roki.OpenGraph`): `/og/title/:type/:id/card.jpg` and `/og/u/:username/card.jpg`,
  the pictures the `og:image` tags on those pages name. Public — a chat's link preview fetches
  them with no cookie. A card not kept yet costs an ImageMagick render, so renders are held to
  a modest number a minute for the whole site; kept ones are a file read.
  """
  use RokiWeb, :controller

  def title(conn, %{"type" => type, "id" => id}) do
    with true <- type in ["movie", "tv"],
         {n, ""} <- Integer.parse(id),
         :ok <- budget(),
         {:ok, jpeg} <- Roki.OpenGraph.title(type, n) do
      send_jpeg(conn, jpeg)
    else
      {:error, {:rate_limited, _}} -> send_resp(conn, 429, "")
      _ -> send_resp(conn, 404, "")
    end
  end

  def profile(conn, %{"username" => username}) do
    with true <- byte_size(username) in 1..64,
         :ok <- budget(),
         {:ok, jpeg} <- Roki.OpenGraph.profile(username) do
      send_jpeg(conn, jpeg)
    else
      {:error, {:rate_limited, _}} -> send_resp(conn, 429, "")
      _ -> send_resp(conn, 404, "")
    end
  end

  defp budget, do: Roki.RateLimit.check(:og, :site, 60, 60_000)

  defp send_jpeg(conn, jpeg) do
    conn
    |> put_resp_content_type("image/jpeg")
    |> put_resp_header("cache-control", "public, max-age=86400")
    |> send_resp(200, jpeg)
  end
end
