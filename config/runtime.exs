import Config
import Dotenvy

# Configuration is centralised here, following the pattern established by
# `langust` (beamlab) and the `phoenix-dotenvy-config` skill in
# elixir_app_helpers: one AppConfig.load/1 that reads every variable, then
# plain config blocks that consume the result.
#
# Source order is `.env.{MIX_ENV}` -> `.env` -> System.get_env(), LAST WINS.
#
# No .env files exist in this repo and none should be created. The compose
# stack exports DB_* and friends into the container environment via env_file,
# and System.get_env() is last in the list above — so a committed .env.test
# would be silently ignored while the suite ran against the development
# database. That trap is documented in server-agents1 adrs/0009; the skill's
# "copy .env.example to .env" step does NOT apply on this host.
source!([".env.#{config_env()}", ".env", System.get_env()])

defmodule ConfigHelpers do
  def parse_server_origins(origins_string) when is_binary(origins_string) do
    origins_string
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def parse_server_origins(_), do: []
end

defmodule AppConfig do
  def load(env) do
    base = %{
      # Database credentials are REQUIRED — `:string!` raises when unset.
      #
      # This is a deliberate divergence from langust, which defaults these to
      # "postgres"/"postgres". Every project on this host shares one Postgres
      # server where the isolation between tenants is role grants and nothing
      # stronger (adrs/0006), so a missing variable must crash at boot rather
      # than quietly attempt a connection as some other identity.
      db_username: env!("DB_USERNAME", :string!),
      db_password: env!("DB_PASSWORD", :string!),
      db_database: env!("DB_DATABASE", :string!),
      db_hostname: env!("DB_HOSTNAME", :string, "pgbouncer"),
      db_port: env!("DB_PORT", :integer, 5432),
      db_pool_size: env!("DB_POOL_SIZE", :integer, 10),

      # Tests use the DIRECT postgres endpoint, never pgbouncer: Ecto's SQL
      # sandbox holds one transaction open across statements and transaction
      # pooling cannot keep that pinned to a single backend connection.
      # The database name defaults to DB_DATABASE + "_test", which is what
      # platform/stacks/postgres/newtestdb.sh provisions.
      test_db_hostname: env!("TEST_DB_HOSTNAME", :string, "postgres"),
      test_db_database: env!("TEST_DB_DATABASE", :string, nil),

      # Server
      port: env!("PORT", :integer, 4000),
      phx_host: env!("PHX_HOST", :string, "localhost"),
      server_origins:
        ConfigHelpers.parse_server_origins(
          env!("SERVER_ORIGINS", :string, "//localhost,//127.0.0.1")
        ),

      # Secrets — required in every environment, no fallback.
      secret_key_base: env!("SECRET_KEY_BASE", :string!),
      live_view_salt: env!("LIVE_VIEW_SIGNING_SALT", :string!),
      phx_server: env!("PHX_SERVER", :boolean, false)
    }

    case env do
      :prod ->
        Map.merge(base, %{
          database_url: env!("DATABASE_URL", :string, nil),
          pool_size: env!("POOL_SIZE", :integer, 10),
          ecto_ipv6: env!("ECTO_IPV6", :boolean, false),
          dns_cluster_query: env!("DNS_CLUSTER_QUERY", :string, nil)
        })

      _ ->
        base
    end
  end
end

cfg = AppConfig.load(config_env())

# ============================================
# Database
# ============================================
if config_env() == :prod and cfg[:database_url] do
  maybe_ipv6 = if cfg.ecto_ipv6, do: [:inet6], else: []

  config :roki, Roki.Repo,
    url: cfg.database_url,
    # :unnamed when the URL points at pgbouncer in transaction pooling mode —
    # named prepared statements do not survive it.
    prepare: if(env!("DB_PREPARE", :string, nil) == "named", do: :named, else: :unnamed),
    pool_size: cfg.pool_size,
    socket_options: maybe_ipv6
else
  repo_config =
    if config_env() == :test do
      [
        username: cfg.db_username,
        password: cfg.db_password,
        database:
          (cfg.test_db_database || cfg.db_database <> "_test") <>
            (env!("MIX_TEST_PARTITION", :string, nil) || ""),
        hostname: cfg.test_db_hostname,
        port: cfg.db_port,
        pool: Ecto.Adapters.SQL.Sandbox,
        pool_size: System.schedulers_online() * 2
      ]
    else
      [
        username: cfg.db_username,
        password: cfg.db_password,
        database: cfg.db_database,
        hostname: cfg.db_hostname,
        port: cfg.db_port,
        # pgbouncer pools transactions, which the named prepared statements
        # Postgrex uses by default do not survive.
        prepare: :unnamed,
        pool_size: cfg.db_pool_size,
        stacktrace: config_env() != :prod,
        # Deliberately false even in dev. When true, a failed connection prints
        # the credentials into /var/log/elixir.log, which on this host sits on
        # the snapshotted and backed-up `data` dataset — so the secret would
        # leave the box. Set to `config_env() != :prod` if you need it while
        # debugging a connection problem, and put it back.
        show_sensitive_data_on_connection_error: false
      ]
    end

  config :roki, Roki.Repo, repo_config
end

# ============================================
# Endpoint
# ============================================
endpoint_config = [
  http: [ip: {0, 0, 0, 0}, port: cfg.port],
  secret_key_base: cfg.secret_key_base,
  live_view: [signing_salt: cfg.live_view_salt],
  # Behind Caddy the public address is https on 443; without it the endpoint builds
  # http://host:4000 links (the QR sign-in code encoded one). A bare localhost stays as it is.
  url:
    if(cfg.phx_host == "localhost",
      do: [host: cfg.phx_host],
      else: [host: cfg.phx_host, scheme: "https", port: 443]
    )
]

endpoint_config =
  if config_env() == :dev do
    Keyword.put(endpoint_config, :check_origin, false)
  else
    Keyword.put(endpoint_config, :check_origin, cfg.server_origins)
  end

endpoint_config =
  if cfg.phx_server do
    Keyword.put(endpoint_config, :server, true)
  else
    endpoint_config
  end

config :roki, RokiWeb.Endpoint, endpoint_config

# ============================================
# Production
# ============================================
if config_env() == :prod do
  config :roki, RokiWeb.Endpoint,
    url: [host: cfg.phx_host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: cfg.port]

  if cfg[:dns_cluster_query] do
    config :roki, :dns_cluster_query, cfg.dns_cluster_query
  end
end

# ============================================
# Development
# ============================================
if config_env() == :dev do
  # This server is also the live site, so a saved file must not reload anybody's open page
  # (no `patterns`), and the server's log — which carries other people's requests and sessions —
  # must not be mirrored into every visitor's browser console (`web_console_logger`).
  # Code still recompiles on the next request.
  config :roki, RokiWeb.Endpoint,
    live_reload: [
      web_console_logger: false,
      patterns: []
    ]
end

# Laev: one TMDB key for everything that runs outside a user's scope — the public
# Featured page. A user who has carried their own key keeps using it; this is only
# the fallback laev documents for a server. Optional: without it /home says so.
if (tmdb = System.get_env("TMDB_API_KEY")) not in [nil, ""] do
  config :laev, tmdb_key: tmdb
end

# MyAnimeList: the site's own app, shared by every account so nobody has to register one. Only
# the app's identity is shared — each user still logs in to their own MyAnimeList and keeps their
# own token. Optional: without it each user sets their own client id under Connections.
config :roki,
  mal_client_id: System.get_env("MAL_CLIENT_ID"),
  mal_client_secret: System.get_env("MAL_CLIENT_SECRET")

# fabledex.com: the arcs, volumes and chapter titles a manga page shows. Optional — without the
# token the saved copy still renders and nothing tries to refresh it.
if (fabledex = System.get_env("FABLEDEX_TOKEN")) not in [nil, ""] do
  config :roki, fabledex_token: fabledex
end

# ============================================
# Test
# ============================================
# LAST on purpose. This container exports PHX_SERVER=true and PORT=4000 for the
# dev server, and runtime.exs runs in EVERY environment — so without this block
# `mix test` inherited server: true on port 4000 and died with :eaddrinuse
# against the running dev server. Forcing it here, after the endpoint block
# above, is how langust avoids the same collision.
if config_env() == :test do
  config :roki, RokiWeb.Endpoint,
    http: [ip: {127, 0, 0, 1}, port: 4002],
    server: false
end

# PenguPlay, as a Stremio addon: the install URL from pengu.uk (it carries an auth token, so it
# lives in the stack .env only). Optional — without it the PenguPlay sources page says so.
if (pengu = System.get_env("PENGU_ADDON_URL")) not in [nil, ""] do
  config :roki, pengu_addon_url: pengu
end
