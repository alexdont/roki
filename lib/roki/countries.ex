defmodule Roki.Countries do
  @moduledoc """
  Countries as TMDB names them (a title's `countries`, from its `production_countries`) and their
  ISO 3166-1 codes — the world map on a profile (`Roki.Profile.country_counts/1`) colours the
  map's countries (`priv/static/data/world-110m.svg`, Natural Earth outlines, keyed `data-c`) by
  code. The table is TMDB's own list (`/configuration/countries`, 250 names), kept in
  `priv/data/tmdb_countries.json`.
  """

  @external_resource Path.join(:code.priv_dir(:roki), "data/tmdb_countries.json")
  @codes Path.join(:code.priv_dir(:roki), "data/tmdb_countries.json")
         |> File.read!()
         |> Jason.decode!()

  @doc "The ISO code for a TMDB country name (`\"South Korea\"` → `\"KR\"`), or nil."
  def code(name) when is_binary(name), do: Map.get(@codes, name)
  def code(_), do: nil

  @doc "The name for a code, as TMDB says it."
  def name(code) when is_binary(code) do
    Enum.find_value(@codes, fn {n, c} -> if c == code, do: n end)
  end
end
