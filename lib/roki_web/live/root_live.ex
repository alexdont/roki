defmodule RokiWeb.RootLive do
  @moduledoc """
  `/` sends you where you belong: your own home when signed in, the featured
  page otherwise.
  """
  use RokiWeb, :live_view

  alias PhoenixKit.Users.Auth.Scope

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    to =
      with true <- scope != nil and Scope.authenticated?(scope),
           name when is_binary(name) and name != "" <- Scope.user(scope).username do
        ~p"/#{name}/home"
      else
        _ -> ~p"/home"
      end

    {:ok, push_navigate(socket, to: to)}
  end

  @impl true
  def render(assigns), do: ~H""
end
