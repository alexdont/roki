defmodule Roki.CountriesTest do
  use ExUnit.Case, async: true

  test "TMDB's country names have their codes, and back" do
    assert Roki.Countries.code("United States of America") == "US"
    assert Roki.Countries.code("South Korea") == "KR"
    assert Roki.Countries.code("Japan") == "JP"
    assert Roki.Countries.code("Atlantis") == nil
    assert Roki.Countries.name("JP") == "Japan"
  end

  test "the map's outlines are keyed by the same codes" do
    svg = File.read!(Path.join(:code.priv_dir(:roki), "static/data/world-110m.svg"))
    for code <- ~w(US JP GB KR FR DE IN BR) do
      assert svg =~ ~s(data-c="#{code}"), code
    end
  end
end
