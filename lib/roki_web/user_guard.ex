defmodule RokiWeb.UserGuard do
  @moduledoc """
  Whose page is this? `/:username/…` pages belong to that one signed-in user.
  Anyone else is sent to the featured page, and a visitor to the login.
  """
  alias PhoenixKit.Users.Auth.Scope

  @doc "`{:ok, uuid}` when the signed-in user is `username`, else `{:redirect, path}`."
  def check(socket, username) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    cond do
      !(scope && Scope.authenticated?(scope)) -> {:redirect, "/phoenix_kit/users/log-in"}
      !same_user?(Scope.user(scope).username, username) -> {:redirect, "/"}
      true -> {:ok, Scope.user_uuid(scope)}
    end
  end

  defp same_user?(mine, requested) when is_binary(mine),
    do: String.downcase(mine) == String.downcase(requested)

  defp same_user?(_, _), do: false
end
