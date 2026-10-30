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

  test "chevrons step through the moods", %{html: html} do
    assert html =~ "data-mood-prev"
    assert html =~ "data-mood-next"
    assert html =~ ~s(aria-label="Next mood")
  end

  test "the picture is full-bleed on a phone too: no poster strip, no rounded card", %{html: html} do
    refute html =~ "aspect-[2/3]"
    refute html =~ "rounded-3xl"
    assert html =~ "min-h-[clamp(30rem,78svh,46rem)]"
  end

  test "the moods are the same thin bars on a phone as on a wide screen", %{html: html} do
    # One bar for each mood, at every width: no row of labelled chips.
    assert length(Regex.scan(~r/data-mood-chip=/, html)) == length(Roki.Mood.all())
    assert html =~ "group/bar"
    refute html =~ "backdrop-blur-md px-3.5"
    assert html =~ "lg:min-h-"
  end
end
