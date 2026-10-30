defmodule RokiWeb.LinkButtonTest do
  @moduledoc """
  The "Link progress" button on a show's own page: at the right end of the pill row (under the
  player switch), saying where the link stands, and not there for a film.
  """
  use RokiWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  defp pills(type, link_state) do
    render_component(&RokiWeb.TitleLive.action_pills/1,
      title: %{type: type, id: 1, vote: 8.1},
      lib: %{saved?: false, held?: false, watched?: false, all_watched?: false},
      busy: false,
      rating: %{state: :ok, value: nil, provider: :tmdb},
      link_state: link_state
    )
  end

  test "a show offers it, at the right end of the row" do
    html = pills("tv", :none)
    assert html =~ "Link progress"
    assert html =~ ~s(#link-sheet)
    assert html =~ "ml-auto"
    # After the rating button, so it ends the row.
    assert :binary.match(html, "Rate it") < :binary.match(html, "Link progress")
  end

  test "it says where the link stands" do
    assert pills("tv", :invited) =~ "Link request"
    html = pills("tv", {:linked, ["max", "sam"]})
    assert html =~ "Linked with max, sam"
    assert html =~ "btn-primary"
  end

  test "a film has none" do
    refute pills("movie", :none) =~ "Link progress"
  end
end
