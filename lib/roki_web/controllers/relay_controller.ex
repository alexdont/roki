defmodule RokiWeb.RelayController do
  @moduledoc "`/relay?u=&t=` and `/relay/nuvio?u=&t=` — `RokiWeb.Relay`, for a signed-in person with a link this server signed."
  use RokiWeb, :controller

  def bytes(conn, %{"u" => url, "t" => token}) do
    cond do
      is_nil(conn.assigns[:phoenix_kit_current_user]) -> send_resp(conn, 403, "log in")
      not RokiWeb.Relay.allowed?(url) -> send_resp(conn, 400, "not a debrid host")
      RokiWeb.Relay.verify(token, url) != :ok -> send_resp(conn, 403, "bad or old link")
      true -> RokiWeb.Relay.stream(conn, url)
    end
  end

  def bytes(conn, _params), do: send_resp(conn, 400, "u= and t= needed")

  def nuvio(conn, %{"u" => url, "t" => token}) do
    with false <- is_nil(conn.assigns[:phoenix_kit_current_user]),
         {:ok, %{url: ^url, headers: headers}} <- RokiWeb.Relay.nuvio_verify(token),
         true <- RokiWeb.Relay.public_https?(url) do
      RokiWeb.Relay.stream(conn, url, headers)
    else
      true -> send_resp(conn, 403, "log in")
      {:error, :bad_token} -> send_resp(conn, 403, "bad or old link")
      false -> send_resp(conn, 400, "not a public stream")
      _ -> send_resp(conn, 403, "bad or old link")
    end
  end

  def nuvio(conn, _params), do: send_resp(conn, 400, "u= and t= needed")
end
