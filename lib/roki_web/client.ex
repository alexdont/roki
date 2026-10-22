defmodule RokiWeb.Client do
  @moduledoc """
  Who is asking, for rate limiting: the signed-in user, else the IP.

  Behind Caddy the socket's peer is Caddy itself, so the IP comes from
  `X-Forwarded-For` — Caddy sets it from the real connection and does not pass
  a client-supplied one through. Needs `:peer_data` and `:x_headers` in the
  endpoint's socket `connect_info`.
  """

  def key(_socket, uuid) when is_binary(uuid), do: {:user, uuid}
  def key(socket, nil), do: {:ip, ip(socket)}

  def ip(socket) do
    if Phoenix.LiveView.connected?(socket) do
      forwarded(Phoenix.LiveView.get_connect_info(socket, :x_headers)) ||
        peer(Phoenix.LiveView.get_connect_info(socket, :peer_data)) || "unknown"
    else
      "unknown"
    end
  end

  defp forwarded(headers) when is_list(headers) do
    with {_, value} <- List.keyfind(headers, "x-forwarded-for", 0),
         [first | _] <- String.split(value, ","),
         ip when ip != "" <- String.trim(first) do
      ip
    else
      _ -> nil
    end
  end

  defp forwarded(_), do: nil

  defp peer(%{address: address}), do: address |> :inet.ntoa() |> to_string()
  defp peer(_), do: nil
end
