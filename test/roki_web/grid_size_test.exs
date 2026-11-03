defmodule RokiWeb.GridSizeTest do
  @moduledoc "One poster size for every grid: the switch, the classes, and the default per page."
  use RokiWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias RokiWeb.GridSize

  test "each size has its columns; nothing chosen is the page's own default" do
    assert GridSize.cols("l") =~ "grid-cols-1"
    assert GridSize.cols("m") =~ "grid-cols-2"
    assert GridSize.cols(nil) =~ "grid-cols-3"
    assert GridSize.cols(nil, "m") =~ "grid-cols-2"
    assert GridSize.cols("nonsense", "m") =~ "grid-cols-2"
  end

  test "a mood page has the switch, and choosing a size changes its grid", %{conn: conn} do
    {:ok, view, _} = live(conn, "/mood/laugh")

    assert has_element?(
             view,
             ~s([aria-label="Poster size"] button[aria-pressed="true"][phx-value-size="s"])
           )

    view |> element(~s(button[phx-click="grid_size"][phx-value-size="l"])) |> render_click()

    assert has_element?(
             view,
             ~s([aria-label="Poster size"] button[aria-pressed="true"][phx-value-size="l"])
           )

    assert_push_event(view, "roki:grid", %{size: "l"})
  end
end
