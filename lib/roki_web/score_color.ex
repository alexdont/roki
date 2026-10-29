defmodule RokiWeb.ScoreColor do
  @moduledoc """
  The colour of a score: what the rating dialog's track, thumb and number are drawn in.

  **One ramp, once.** Red at 1, through yellow, to green at 7 — and from there *deepening*, toward
  emerald at 9.5, rather than coming back round. The ramp used to carry on turning past green,
  back through yellow to gold at 10, so the scale ran red, yellow, green, yellow: 8 looked less
  good than 7, and 10 looked like a yellow 4. A rating scale should only ever get better as it
  goes up, and the eye should never have to decide whether the colour it is looking at is the
  start or the end.

  **Ten is not on the ramp.** It is the one score that is a different kind of thing — nothing
  scores higher — so it is gold, a metal rather than a hue: set in a gradient on the number and
  the thumb, and as a hard-edged cap at the very end of the track, so nothing in between can blend
  toward it. Gold is defined in the stylesheet (`--gold`, `--gold-fill`); this module only says
  *where* it is used.

  The colours a score has are handed to the page's script as a table (`table/0`), so the slider
  does not carry a second copy of the formula to drift from this one.
  """

  # The ramp turns red to green over 1..7, then deepens over 7..9.5.
  @green_at 7
  @top_of_ramp 9.5

  @doc "Is this score the top one, which is gold rather than a colour on the ramp?"
  def gold?(v) when is_number(v), do: v >= 10
  def gold?(_other), do: false

  @doc """
  The colour a score is drawn in, as a CSS colour. Ten is the stylesheet's gold, which is not a
  single colour: `gold?/1` says when to use it.
  """
  def color(v) when is_number(v) do
    if gold?(v), do: "var(--gold)", else: ramp(v)
  end

  # A score from 0.5 to 9.5. Anything between 9.5 and 10 is a rounding of the slider's, and is
  # kept on the ramp's last colour rather than invented a place.
  defp ramp(v) do
    s = v |> max(1) |> min(@top_of_ramp)

    {hue, sat, light} =
      if s <= @green_at do
        {(s - 1) / (@green_at - 1) * 130, 75, 46}
      else
        t = (s - @green_at) / (@top_of_ramp - @green_at)
        {130 + t * 22, 75 + t * 5, 46 - t * 4}
      end

    "hsl(#{round(hue)} #{round(sat)}% #{round(light)}%)"
  end

  @doc """
  The track the thumb runs along, as a CSS gradient. `min` is where the slider starts (0.5 for a
  TMDB rating, 1 for MyAnimeList's whole numbers), so a score sits where the thumb will.

  The ramp is smooth up to 9.5, and then the last notch is gold with a hard edge: no stop on the
  way blends toward it.
  """
  def track(min \\ 0.5) do
    at = fn v -> Float.round((v - min) / (10 - min) * 100, 1) end

    ramp_stops = for v <- 1..9, do: "#{ramp(v)} #{at.(v)}%"
    # The edge halfway between the last score on the ramp and ten.
    edge = at.((@top_of_ramp + 10) / 2)

    stops =
      ramp_stops ++
        ["#{ramp(@top_of_ramp)} #{at.(@top_of_ramp)}%", "#{ramp(@top_of_ramp)} #{edge}%"] ++
        ["var(--gold) #{edge}%", "var(--gold) 100%"]

    "linear-gradient(90deg, #{Enum.join(stops, ", ")})"
  end

  @doc """
  Every score the slider can land on, as the string the script reads its value as, with its colour
  — and `"gold"` for ten, which the script draws with the stylesheet's gold instead.
  """
  def table do
    for halves <- 1..20, into: %{} do
      v = halves / 2

      key =
        if v == trunc(v),
          do: Integer.to_string(trunc(v)),
          else: :erlang.float_to_binary(v, decimals: 1)

      {key, if(gold?(v), do: "gold", else: color(v))}
    end
  end
end
