defmodule RokiWeb.PosterCachedTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  @item %{type: "movie", id: 7, title: "A", poster: nil, year: "2020"}

  test "a poster of a title with cached sources says so" do
    html =
      render_component(&RokiWeb.PosterComponents.poster/1,
        item: @item,
        cached_titles: MapSet.new([{"movie", 7}])
      )

    assert html =~ "cached"
  end

  test "others, and pages that know nothing, show no tag" do
    for set <- [MapSet.new([{"movie", 8}]), nil] do
      refute render_component(&RokiWeb.PosterComponents.poster/1, item: @item, cached_titles: set) =~
               "cached"
    end
  end
end
