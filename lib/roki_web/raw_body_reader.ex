defmodule RokiWeb.RawBodyReader do
  @moduledoc """
  Body reader for `Plug.Parsers` that stashes the RAW request bytes for
  `/api/laev/*` requests before the JSON parser consumes them.

  The Laev sync store's contract is byte-for-byte fidelity: what the CLI
  PUTs is exactly what a later GET returns. Phoenix's JSON parser decodes
  the body into params and the original bytes are gone — re-encoding is
  not the same document (key order, whitespace, number formatting). This
  reader is a no-op for every other path.
  """

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, chunk, conn} -> {:ok, chunk, stash(conn, chunk)}
      {:more, chunk, conn} -> {:more, chunk, stash(conn, chunk)}
      other -> other
    end
  end

  defp stash(%Plug.Conn{path_info: ["api", "laev" | _]} = conn, chunk) do
    acc = Map.get(conn.private, :laev_raw_body, [])
    Plug.Conn.put_private(conn, :laev_raw_body, [acc | chunk])
  end

  defp stash(conn, _chunk), do: conn
end
