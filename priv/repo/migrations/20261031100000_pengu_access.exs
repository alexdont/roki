defmodule Roki.Repo.Migrations.PenguAccess do
  use Ecto.Migration

  # PenguPlay can be lent like the API keys: `pengu` says an account may use the owner's PenguPlay
  # link, `daily_pengu` caps how many searches a day it may make with it (blank: the site default).
  def change do
    alter table(:roki_key_grants) do
      add :pengu, :boolean, null: false, default: false
      add :daily_pengu, :integer
    end
  end
end
