defmodule Roki.Repo.Migrations.AddStints do
  @moduledoc """
  The `stints` table, from the `stint` package. A reading session is a run of progress ticks
  with no long gap in it, and this is where they are kept — the reading history page draws its
  timeline from them.
  """
  use Ecto.Migration

  def up, do: Stint.Migration.up()
  def down, do: Stint.Migration.down()
end
