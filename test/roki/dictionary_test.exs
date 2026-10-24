defmodule Roki.DictionaryTest do
  use ExUnit.Case, async: true

  alias Roki.Dictionary

  test "a word is looked up as written, then as the word underneath it" do
    assert Dictionary.candidates("d'aimer") == ["d'aimer", "aimer"]
    assert Dictionary.candidates("L\u2019homme,") == ["l'homme", "homme", "L\u2019homme,"]
    assert Dictionary.candidates("Maison") == ["maison", "Maison"]
  end

  test "pronouns hung on with a hyphen come off" do
    assert "dis" in Dictionary.candidates("dis-moi")
    assert "donne" in Dictionary.candidates("Donne-le !")
    # not every hyphen is a clitic
    refute "peut" in Dictionary.candidates("peut-être")
  end
end
