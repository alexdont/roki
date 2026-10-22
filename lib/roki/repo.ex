defmodule Roki.Repo do
  use Ecto.Repo,
    otp_app: :roki,
    adapter: Ecto.Adapters.Postgres
end
