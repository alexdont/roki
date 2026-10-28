defmodule Roki.Repo.Migrations.PhoenixKitUpdateV1ToV220 do
  @moduledoc false
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    # PhoenixKit Update Migration: V1 -> V220
    PhoenixKit.Migrations.up(
      prefix: "public",
      version: 220,
      create_schema: false
    )
  end

  def down do
    # The version this project was at before this step is not recorded in
    # its migration filenames (the install migration carries none), so an
    # automatic rollback has no safe target: guessing would drop most of
    # PhoenixKit's tables. To roll back deliberately, call
    # `PhoenixKit.Migrations.down(prefix: "public", version: N)` with
    # the version you mean.
    raise "PhoenixKit: refusing to roll back — the version before this " <>
            "update is unknown. See the comment in this migration."
  end
end
