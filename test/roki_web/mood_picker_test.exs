defmodule RokiWeb.MoodPickerTest do
  @moduledoc """
  The mood carousel must not depend on how long a title or a tagline is: the slides share one
  grid cell, so the box is as tall as the tallest, and the poster row never shrinks (a squeezed
  row made the posters nearly square and crushed the button). The real widths are measured by
  `test/e2e/mood_layout.js`.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  setup do
    {:ok, html: render_component(&RokiWeb.FeaturedLive.mood_picker/1, moods: %{})}
  end

  test "every mood is a slide in the same grid cell", %{html: html} do
    assert length(Regex.scan(~r/data-mood="[a-z]+"/, html)) == length(Roki.Mood.all())

    assert length(Regex.scan(~r/relative col-start-1 row-start-1 flex transition-opacity/, html)) ==
             length(Roki.Mood.all())

    assert html =~ "grid-cols-[minmax(0,1fr)]"
    # No fixed height any more (min-h is the floor, not a cap).
    refute html =~ ~r/(^|[" ])h-\[26rem\]/
  end

  test "the posters keep their shape and their row its size", %{html: html} do
    assert html =~ ~r/class="[^"]*aspect-\[2\/3\][^"]*shrink-0/
    assert html =~ "aspect-[2/3]"
  end

  test "on a wide screen the moods are bars in the picture, and the chip row and poster strip give way",
       %{html: html} do
    # Twelve bars and twelve chips: the hook lights both by mood.
    assert length(Regex.scan(~r/data-mood-chip=/, html)) == 2 * length(Roki.Mood.all())
    assert html =~ "group/bar"
    assert html =~ ~r/class="[^"]*sm:flex-wrap[^"]*lg:hidden"/
    assert html =~ "lg:min-h-"
    assert html =~ "lg:rounded-none"
  end
end
