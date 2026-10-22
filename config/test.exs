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

# The suite registers a throwaway user per test; PhoenixKits

# The suite registers a throwaway user per test; PhoenixKit's registration rate limit
# (3 per hour per address, 10 per IP) is meant for production and would fail them partway.
config :phoenix_kit, PhoenixKit.Users.RateLimiter,
  registration_limit: 100_000,
  registration_ip_limit: 100_000
