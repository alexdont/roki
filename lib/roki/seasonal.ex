defmodule Roki.Seasonal do
  @moduledoc """
  What suits the time of year: Halloween in October, Christmas in December, summer movies in
  the summer. Every day of the year belongs to exactly one season (`current/1`), so the Featured
  page's Seasonal row is never empty and changes by itself as the calendar turns.

  A season is shaped like a mood (`Roki.Mood`) so the same page shows it (`/mood/halloween`): a name
  set in a typeface, a colour, a tagline — and, instead of genres, TMDB keywords, which is what
  "a Halloween film" actually is. Films and shows are asked for by the same keywords.

  The seasons are a calendar of start dates; each runs until the next begins.
  """

  # slug, label, tagline, typeface (all already loaded for the moods), hue, and the TMDB keywords
  # (any of them) that make a title belong — or, for a season no keyword gathers, genres. Keyword ids were looked up on TMDB (2026-10-31).
  @seasons %{
    "winter" => %{
      label: "Winter",
      tagline: "Snow outside, blanket inside.",
      font: "'Cinzel', serif",
      hue: 205,
      kw: [1442, 10794, 226_563, 232_555]
    },
    "valentines" => %{
      label: "Valentine's Day",
      tagline: "For two. Or for one, with snacks.",
      font: "'Pacifico', cursive",
      hue: 340,
      kw: [160_404, 376_604]
    },
    "spring" => %{
      label: "Spring",
      tagline: "Light, bright and feel-good.",
      font: "'Pacifico', cursive",
      hue: 105,
      # No keyword gathers enough of spring on TMDB; its mood is the light end of the genres.
      kw: [],
      genres: [35, 10_751, 16]
    },
    "summer" => %{
      label: "Summer",
      tagline: "Beaches, road trips, one last summer.",
      font: "'Bangers', cursive",
      hue: 42,
      kw: [13_088, 14_714, 200_129, 966]
    },
    "halloween" => %{
      label: "Halloween",
      tagline: "The season for it. Lights low, door locked.",
      font: "'Creepster', cursive",
      hue: 24,
      kw: [3335, 232_795, 318_653, 9694, 3358, 361_281]
    },
    "thanksgiving" => %{
      label: "Thanksgiving",
      tagline: "Family, food, and everything going wrong.",
      font: "'IM Fell English', serif",
      hue: 30,
      kw: [4543, 307_493, 374_738, 9848]
    },
    "christmas" => %{
      label: "Christmas",
      tagline: "Lights on, tree up, kettle on.",
      font: "'Playfair Display', serif",
      hue: 140,
      kw: [207_317, 5570, 260_365, 1991]
    },
    "new-years" => %{
      label: "New Year's",
      tagline: "Count it down, start it over.",
      font: "'Cinzel', serif",
      hue: 48,
      kw: [613]
    }
  }

  # When each season starts ({month, day}); it runs until the next one, and the last runs on past
  # New Year to the first.
  @calendar [
    {{1, 7}, "winter"},
    {{2, 1}, "valentines"},
    {{2, 16}, "winter"},
    {{3, 1}, "spring"},
    {{6, 15}, "summer"},
    {{7, 8}, "summer"},
    {{9, 15}, "halloween"},
    {{11, 3}, "thanksgiving"},
    {{12, 1}, "christmas"},
    {{12, 26}, "new-years"}
  ]

  @doc "The season named by a slug, shaped like a mood (see `Roki.Mood`), or nil."
  def get(slug) when is_binary(slug) do
    case Map.fetch(@seasons, slug) do
      {:ok, season} ->
        genres = Map.get(season, :genres, [])

        Map.merge(
          %{
            slug: slug,
            season: true,
            movie: genres,
            tv: genres,
            tv_kw: season.kw,
            movie_kw: season.kw
          },
          Map.drop(season, [:kw, :genres])
        )

      :error ->
        nil
    end
  end

  def get(_), do: nil

  @doc "Every season, in the order the year runs."
  def all, do: for({_from, slug} <- @calendar |> Enum.uniq_by(&elem(&1, 1)), do: get(slug))

  @doc "The season a date falls in."
  def current(date \\ Date.utc_today()) do
    md = {date.month, date.day}

    {_from, slug} =
      @calendar |> Enum.filter(fn {from, _} -> from <= md end) |> List.last() ||
        List.last(@calendar)

    get(slug)
  end
end
