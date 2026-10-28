defmodule RokiWeb.GiphyController do
  use RokiWeb, :controller

  def search(conn, %{"q" => query}) when byte_size(query) > 0 do
    opts = [
      api_key: api_key(),
      limit: min(String.to_integer(conn.params["limit"] || "20"), 50),
      offset: String.to_integer(conn.params["offset"] || "0"),
      rating: rating()
    ]

    case GiphyApi.search(query, opts) do
      {:ok, gifs} -> json(conn, %{data: gifs})
      {:error, reason} -> conn |> put_status(502) |> json(%{error: inspect(reason)})
    end
  end

  def search(conn, _params) do
    json(conn, %{data: []})
  end

  def trending(conn, _params) do
    opts = [
      api_key: api_key(),
      limit: min(String.to_integer(conn.params["limit"] || "20"), 50),
      rating: rating()
    ]

    case GiphyApi.trending(opts) do
      {:ok, gifs} -> json(conn, %{data: gifs})
      {:error, reason} -> conn |> put_status(502) |> json(%{error: inspect(reason)})
    end
  end

  defp api_key do
    PhoenixKit.Settings.get_setting("comments_giphy_api_key") ||
      Application.get_env(:giphy_api, :api_key)
  end

  defp rating do
    PhoenixKit.Settings.get_setting("comments_giphy_rating") || "pg-13"
  end
end
