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

  test "on a wide screen the moods are bars in the picture, and the chip row and poster strip give way",
       %{html: html} do
    # Twelve bars and twelve chips: the hook lights both by mood.
    assert length(Regex.scan(~r/data-mood-chip=/, html)) == 2 * length(Roki.Mood.all())
    assert html =~ "group/bar"
    # On a phone the chips are glass, laid over the bottom of the picture.
    assert html =~ ~r/class="absolute inset-x-0 bottom-5[^"]*lg:hidden"/
    assert html =~ "backdrop-blur-md"
    assert html =~ "lg:min-h-"
  end
end
