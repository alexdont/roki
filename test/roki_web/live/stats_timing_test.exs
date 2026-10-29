defmodule RokiWeb.StatsTimingTest do
  @moduledoc """
  What a row of the stats list says about how its time is made up. These are the rows that read
  "69% assumed" and "92% assumed" and made a film watched to the end look half-watched.
  """
  use ExUnit.Case, async: true

  alias RokiWeb.StatsLive

  # Masterplan: finished, and the player timed 33m of a 1h 50m film (2027s of 6600s).
  @masterplan %{kind: :movie, title: "Masterplan", seconds: 6600, off: 6600 - 2027}
  # The Menendez show: three episodes really played, the rest marked in one click.
  @menendez %{kind: :tv, title: "Monsters", seconds: 30_240, off: 21_563}
  # A show marked watched and never played here.
  @alice %{kind: :tv, title: "Alice in Borderland", seconds: 36_960, off: 36_960}
  # Overgeared: 2h 19m read in the reader, 26h 31m entered by hand.
  @overgeared %{kind: :manga, title: "Overgeared", seconds: 8340 + 95_460, off: 95_460}
  # An arc of a series dated by hand: all of its time is hand-entered.
  @arc %{kind: :manga, title: "Overgeared · Arc", seconds: 3600, off: 3600}

  test "a film finished but barely timed says it counts in full, and how much was timed" do
    assert StatsLive.timing(@masterplan) == " · counted in full, 33m of it timed"
    refute StatsLive.timing(@masterplan) =~ "%"
    refute StatsLive.timing(@masterplan) =~ "assumed"
  end

  test "a show part played and part marked says the same, with its own figure" do
    assert StatsLive.timing(@menendez) == " · counted in full, 2h 24m of it timed"
  end

  test "a title marked watched and never played says so" do
    assert StatsLive.timing(@alice) == " · marked watched, not timed"
  end

  test "reading splits what was read here from what was entered by hand" do
    assert StatsLive.timing(@overgeared) == " · 2h 19m read here · 26h 31m added by hand"
    refute StatsLive.timing(@overgeared) =~ "assumed"
  end

  test "reading that is all hand-entered says so" do
    assert StatsLive.timing(@arc) == " · added by hand"
  end

  test "a row that was timed in full says nothing at all" do
    assert StatsLive.timing(%{kind: :movie, seconds: 6000, off: 0}) == ""
    assert StatsLive.timing_note(%{kind: :movie, seconds: 6000, off: 0}) == nil
  end

  test "every row that carries a note explains itself in the tooltip" do
    for row <- [@masterplan, @menendez, @alice, @overgeared, @arc] do
      note = StatsLive.timing_note(row)
      assert is_binary(note) and note != "", "no note for #{row.title}"
      refute note =~ "assumed"
    end

    assert StatsLive.timing_note(@masterplan) =~ "full length counts"
    assert StatsLive.timing_note(@overgeared) =~ "entered by hand"
  end
end
