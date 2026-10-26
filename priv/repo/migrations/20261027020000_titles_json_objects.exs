defmodule Roki.Repo.Migrations.TitlesJsonObjects do
  use Ecto.Migration

  # Roki.Titles and Roki.Kept handed their JSON to the column already encoded, so what was stored
  # was a JSON *string* holding the JSON. Made into the objects they are, so SQL can read into
  # them (the runtime of a film, say).
  def up do
    execute "update roki_titles set data = (data #>> '{}')::jsonb where jsonb_typeof(data) = 'string'"
    execute "update roki_kept set data = (data #>> '{}')::jsonb where jsonb_typeof(data) = 'string'"
  end

  def down, do: :ok
end
