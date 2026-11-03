defmodule Ecto.Migrations.PhoenixKitUpdateV220ToV225 do
  @moduledoc false
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    # PhoenixKit Update Migration: V220 -> V225
    PhoenixKit.Migrations.up(
      prefix: "public",
      version: 225,
      create_schema: false
    )
  end

  def down do
    # Rollback PhoenixKit to V220
    PhoenixKit.Migrations.down(
      prefix: "public",
      version: 220
    )
  end
end
