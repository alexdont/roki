defmodule RokiWeb.OldAddressController do
  @moduledoc """
  Addresses from before user pages moved under `/u/` and Featured to the bare address: each is
  sent, permanently (301), to where it lives now, its query kept. `/u/:name` alone goes to the
  profile, `/u/:name/profile`.
  """
  use RokiWeb, :controller

  def featured(conn, _params), do: moved(conn, "/")

  def corner(conn, %{"username" => name}), do: moved(conn, "/u/#{name}/corner")

  def page(conn, %{"username" => name}), do: moved(conn, "/u/#{name}/#{conn.assigns.page}")

  def profile(conn, %{"username" => name}), do: moved(conn, "/u/#{name}/profile")

  defp moved(conn, to) do
    to = if conn.query_string in [nil, ""], do: to, else: to <> "?" <> conn.query_string

    conn
    |> put_status(:moved_permanently)
    |> redirect(to: to)
  end
end
