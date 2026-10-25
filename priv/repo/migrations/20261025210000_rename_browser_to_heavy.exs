defmodule Roki.Repo.Migrations.RenameBrowserToHeavy do
  use Ecto.Migration

  # Everyone may play in the browser now (releases that need no re-encoding); the per-account switch
  # is for re-encoding the rest, which is what costs the server.
  def change do
    rename table(:roki_key_grants), :browser, to: :heavy
  end
end
