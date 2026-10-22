import Config
config :phoenix_kit, repo: Roki.Repo

# The test database, sandbox pool and server: false are configured in
# config/runtime.exs from the container environment. Keeping them there is
# what stops the dev server's PHX_SERVER/PORT leaking into the test run.

# In test we don't send emails
config :roki, Roki.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
