defmodule RokiWeb.PageController do
  use RokiWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end

  # PhoenixKit's mount point on its own: there is nothing there. Home is where a visitor who has
  # just logged out ends up (the flash that says so is kept through the redirect).
  def phoenix_kit_root(conn, _params), do: redirect(conn, to: ~p"/")

  # The browser decoding self-test is a plain page under /images; the short addresses lead to it.
  def hevc_test(conn, _params), do: redirect(conn, to: "/images/hevc-test/index.html")

  # The self-test's fragmented HEVC file served two ways through our own range handling: with
  # its size known, and as a file still being written (no total length), which is what a
  # conversion in progress would look like to the browser.
  def hevc_test_file(conn, %{"how" => how}) when how in ["sized", "growing"] do
    path = Path.join(:code.priv_dir(:roki), "static/images/hevc-test/hevc-frag.mp4")
    Fmp4.RangeFile.send(conn, path, "video/mp4", growing?: how == "growing")
  end
end
