defmodule RokiWeb.PageController do
  use RokiWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end

  # The browser decoding self-test is a plain page under /images; the short addresses lead to it.
  def hevc_test(conn, _params), do: redirect(conn, to: "/images/hevc-test/index.html")
end
