defmodule RokiWeb.BannerController do
  @moduledoc """
  Serves a profile's banner (`/banners/<user uuid>-<time>.jpg`, see `Roki.Profile`). The name
  changes with every upload, so what is served under one never changes and may be cached.
  """
  use RokiWeb, :controller

  def show(conn, %{"file" => name}) do
    case Roki.Profile.banner_file(name) do
      path when is_binary(path) ->
        if File.regular?(path) do
          conn
          |> put_resp_content_type("image/jpeg")
          |> put_resp_header("cache-control", "public, max-age=604800, immutable")
          |> send_file(200, path)
        else
          send_resp(conn, 404, "no such banner")
        end

      nil ->
        send_resp(conn, 400, "bad request")
    end
  end
end
