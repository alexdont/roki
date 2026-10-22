defmodule Roki.Repo.Migrations.AddPhoenixKitTables do
  use Ecto.Migration

  def up, do: PhoenixKit.Migrations.up([])

  def down, do: PhoenixKit.Migrations.down([])
end
