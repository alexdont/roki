defmodule Roki.Repo.Migrations.KeyAccessPermissions do
  use Ecto.Migration

  # Per-account permissions: which of the lent keys an account may use (one by one), and whether it
  # may play in the browser. Accounts that already had access keep all the shared keys and the
  # browser, which is what "allowed" meant until now.
  def up do
    alter table(:roki_key_grants) do
      add :keys, {:array, :text}, null: false, default: []
      add :browser, :boolean, null: false, default: false
    end

    execute """
    update roki_key_grants set
      keys = coalesce((select array_agg(distinct p) from (
        select case when s in ('OPENSUBTITLES_API_KEY', 'OPENSUBTITLES_USERNAME', 'OPENSUBTITLES_PASSWORD')
                    then 'OPENSUBTITLES' else s end as p
        from roki_key_settings, unnest(shared) as s where id = 1) x), '{}'),
      browser = true
    """
  end

  def down do
    alter table(:roki_key_grants) do
      remove :keys
      remove :browser
    end
  end
end
