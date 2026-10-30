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
    refute html =~ "h-[26rem]"
  end

  test "the posters keep their shape and their row its size", %{html: html} do
    assert html =~ ~r/class="[^"]*aspect-\[2\/3\][^"]*shrink-0/
    assert html =~ "aspect-[2/3]"
  end
end
