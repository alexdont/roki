defmodule Roki.WatchNotOutTest do
  use ExUnit.Case, async: true

  alias Roki.Watch

  @today ~D[2026-11-04]

  describe "not_out?/3 — what the red mark on a poster means" do
    test "a date after today is not out yet" do
      assert Watch.not_out?(~D[2026-11-05], "Released", @today)
      assert Watch.not_out?(~D[2027-03-01], "Post Production", @today)
    end

    test "a date before today is out, whatever its status says" do
      refute Watch.not_out?(~D[2026-11-03], "Released", @today)
      refute Watch.not_out?(~D[2026-05-13], "Post Production", @today)
    end

    test "today's date is out when released, not out while still in production" do
      refute Watch.not_out?(@today, "Released", @today)
      refute Watch.not_out?(@today, nil, @today)

      for status <- ["Planned", "In Production", "Post Production", "Rumored"] do
        assert Watch.not_out?(@today, status, @today), status
      end
    end
  end
end
