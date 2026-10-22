defmodule RokiWeb.PageController do
  use RokiWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
