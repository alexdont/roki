defmodule Roki.Languages do
  @moduledoc """
  The languages a person can pick for audio and subtitles, from the same list PhoenixKit's own
  language switchers use (`BeamLabCountries.Languages`, ISO 639-1: `fr` for French). Offering the
  list means a code cannot be mistyped — a wrong one would simply rank nothing first.
  """

  alias BeamLabCountries.Languages

  # What most people here want, ahead of the long alphabetical list.
  @common ~w(en fr ja es de it pt ru ko zh)

  @doc """
  The choices for a language setting with `current` as it is now: `%{common: [...], rest: [...]}`,
  each `{code, "French (fr)"}`. A value the list does not know (set in the terminal app, say) is
  kept as a choice of its own rather than dropped.
  """
  def choices(current) do
    all = Languages.all() |> Enum.map(&{&1.code, label(&1.code, &1.name)})
    {common, rest} = Enum.split_with(all, fn {code, _} -> code in @common end)

    common = Enum.sort_by(common, fn {code, _} -> Enum.find_index(@common, &(&1 == code)) end)
    rest = Enum.sort_by(rest, fn {_code, label} -> label end)
    known = MapSet.new(all, &elem(&1, 0))

    current = normalize(current)

    extra =
      if current in [nil, ""] or MapSet.member?(known, current) or current == "off",
        do: [],
        else: [{current, "#{current} (as set)"}]

    %{common: common, rest: rest, extra: extra}
  end

  @doc "The value to show selected: lower-case, `nil` when nothing is set."
  def normalize(nil), do: nil

  # "French", "fre" and "FR" are one language; "off" (subtitles) stays itself.
  def normalize(value) do
    case value |> to_string() |> String.trim() |> String.downcase() do
      "off" -> "off"
      other -> Laev.Config.normalise_lang(other) || other
    end
  end

  defp label(code, name), do: "#{name} (#{code})"
end
