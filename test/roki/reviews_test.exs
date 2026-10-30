defmodule Roki.ReviewsTest do
  use ExUnit.Case, async: true

  test "a reception section becomes plain paragraphs, without footnotes, tables or stubs" do
    html = """
    <div class="mw-parser-output">
      <p>It was well received by critics.<sup class="reference">[12]</sup>Reviewers praised the cast and the score throughout the film.</p>
      <table><tr><td>Rotten Tomatoes 92%</td></tr></table>
      <p>Short.</p>
      <p>Audiences agreed, and it grossed more than any other film that year[3], by a wide margin.</p>
    </div>
    """

    assert [first, second] = Roki.Reviews.paragraphs(html)
    assert first =~ "critics. Reviewers praised"
    refute first =~ "[12]"
    refute second =~ "[3]"
    refute Enum.any?([first, second], &(&1 =~ "92%"))
  end

  test "a long section is cut between paragraphs, never inside one" do
    para = String.duplicate("word ", 80)
    html = String.duplicate("<p>#{para}</p>", 8)
    out = Roki.Reviews.paragraphs(html)
    assert length(out) in 2..5
    assert Enum.all?(out, &(String.length(&1) > 300))
  end

  test "scores held for a title are given back without asking anyone" do
    held = [
      %{
        source: "tomatoes",
        order: 1,
        label: "Rotten Tomatoes",
        who: "Critics",
        text: "92%",
        votes: 466
      }
    ]

    Roki.TTLCache.put({:mdblist, "movie", 999_001}, 60, {:ok, held})
    assert Roki.Reviews.scores("movie", 999_001) == held
  end
end
