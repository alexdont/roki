# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :swoosh, api_client: Swoosh.ApiClient.Finch

# Sync keys travel in the address and as a `token` parameter; never print them.
config :phoenix, :filter_parameters, ["password", "token"]

# The admin tab "API access": who uses the owner's keys (Roki.Keys, RokiWeb.Admin.KeyAccessLive).
config :phoenix_kit, :admin_dashboard_tabs, [
  %{
    id: :admin_api_access,
    label: "API access",
    icon: "hero-key",
    path: "/admin/api-access",
    permission: "users",
    priority: 130,
    group: :admin_main,
    live_view: {RokiWeb.Admin.KeyAccessLive, :index}
  }
]

config :phoenix_kit,
  parent_app_name: :roki,
  parent_module: Roki,
  url_prefix: "/phoenix_kit",
  repo: Roki.Repo,
  mailer: Roki.Mailer,
  layouts_module: RokiWeb.Layouts,
  phoenix_version_strategy: :modern,
  # phx.new's root layout ships its own data-theme bootstrap (localStorage
  # "phx:theme", falling back to prefers-color-scheme), so PhoenixKit did
  # NOT inject its own — two scripts stamping the same attribute would
  # fight and the host's [data-theme=...] styles would stop applying.
  # Naming the host's theme values here is what makes the kit's admin
  # pages offer the same two palettes instead of its own defaults.
  dashboard_themes: ["light", "dark"],
  # Without this, stored integration credentials and restricted settings are
  # encrypted under a key DERIVED from secret_key_base — the same secret that
  # signs sessions and CSRF tokens, so anything able to read it can decrypt
  # every credential. This gives them a key of their own.
  #
  # Path set EXPLICITLY rather than taking the default
  # ~/.config/phoenix_kit/roki-integrations.key: the default depends on HOME,
  # and supervisord's program block sets no HOME at all (it only inherits
  # docker's). That inheritance happens to work today; a config change or a
  # `sudo -u` would break it, and the app would silently fall back to the
  # secret_key_base-derived key rather than fail.
  #
  # /root is a BIND MOUNT (../../data/roki-ee/root), so the key survives a
  # container recreate — the writable layer does not. It is also outside the
  # git tree, which the store enforces: it refuses to write inside a repo.
  integrations_key_store:
    {PhoenixKit.Integrations.KeyStore.File,
     path: "/root/.config/phoenix_kit/roki-integrations.key"}

config :roki,
  ecto_repos: [Roki.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :roki, RokiWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: RokiWeb.ErrorHTML, json: RokiWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Roki.PubSub,
  live_view: [signing_salt: "cM2UyTih"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :roki, Roki.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  roki: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  roki: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
# Configure rate limiting with Hammer
config :hammer,
  backend:
    {Hammer.Backend.ETS,
     [
       # Cleanup expired rate limit buckets every 60 seconds
       expiry_ms: 60_000,
       # Cleanup interval (1 minute)
       cleanup_interval_ms: 60_000
     ]}

# Configure rate limits for authentication endpoints
config :phoenix_kit, PhoenixKit.Users.RateLimiter,
  # Login: 5 attempts per minute per email
  login_limit: 5,
  login_window_ms: 60_000,
  # Magic link: 3 requests per 5 minutes per email
  magic_link_limit: 3,
  magic_link_window_ms: 300_000,
  # Password reset: 3 requests per 5 minutes per email
  password_reset_limit: 3,
  password_reset_window_ms: 300_000,
  # Registration: 3 attempts per hour per email
  registration_limit: 3,
  registration_window_ms: 3_600_000,
  # Registration IP: 10 attempts per hour per IP
  registration_ip_limit: 10,
  registration_ip_window_ms: 3_600_000

# Configure Ueberauth (minimal configuration for compilation)
# OAuth providers are configured dynamically at runtime from database
config :ueberauth, Ueberauth, providers: %{}
# Configure Oban for PhoenixKit background jobs.
# Queues come from PhoenixKit and the installed modules (their
# `oban_queues/0` declarations); `mix phoenix_kit.update` adds any a
# later module declares, and never changes a limit you set here.
# Limits are per node.
config :roki, Oban,
  repo: Roki.Repo,
  # DB_HOSTNAME is pgbouncer in TRANSACTION pooling mode, which Oban's
  # default Postgres notifier cannot survive: LISTEN/NOTIFY needs one
  # session held across statements, and a transaction pooler hands the
  # backend to someone else between them. The failure is SILENT — jobs
  # still run, but queue pause/resume/scale signals are dropped on the
  # floor. The host documents this constraint for every LISTEN/NOTIFY user
  # (server-agents1 AGENTS.md, Databases). Oban.Notifiers.PG rides Erlang
  # distribution instead of the database and is correct for a single node,
  # which this is. The alternative — a second Repo pointed at postgres:5432
  # past the pooler — buys nothing here and costs a connection pool.
  notifier: Oban.Notifiers.PG,
  queues: [
    # PhoenixKit
    default: 10,

    # PhoenixKit, batch
    file_processing: 20,

    # PhoenixKit, batch
    scheduled_jobs: 1,

    # PhoenixKit, batch
    sitemap: 5,

    # PhoenixKit, interactive
    notifications: 10,

    # PhoenixKit (on behalf of a module)
    posts: 10,

    # PhoenixKit (on behalf of a module)
    newsletters_delivery: 10,

    # PhoenixKit (on behalf of a module), batch
    catalogue_pdf: 2,

    # PhoenixKit (on behalf of a module), batch
    shop_imports: 2
  ],
  plugins: [
    # Pruner: delete completed/discarded jobs after 30 days
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 30},
    # Lifeline: rescue jobs orphaned in :executing by a hard crash
    # (BEAM kill -9, OOM, node failure) back to :available so they
    # run again — without it, an orphaned job sits stuck forever.
    # rescue_after MUST stay above your longest-running job: Lifeline
    # rescues purely by elapsed time, with no check that the node is
    # still alive, so a job that legitimately runs longer is rescued
    # mid-flight and executes a second time concurrently. 60 minutes
    # is Oban's own default and 2x PhoenixKit's longest worker
    # timeout (Storage.Jobs.Reconcile, 30 min).
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(60)},
    {Oban.Plugins.Cron,
     crontab: [
       {"* * * * *", PhoenixKit.ScheduledJobs.Workers.ProcessScheduledJobsWorker},
       {"0 3 * * *", PhoenixKit.Modules.Storage.Workers.PruneTrashJob},
       {"0 4 * * *", PhoenixKit.Notifications.PruneWorker},
       {"10 4 * * *", PhoenixKit.Activity.PruneWorker},
       {"30 4 * * *", PhoenixKit.Users.Referrals.PruneWorker},
       {"45 4 * * *", PhoenixKit.Users.LoginAttemptsPruneWorker},
       {"*/5 * * * *", PhoenixKit.Jobs.SweepWorker},
       {"15 4 * * *", PhoenixKit.Jobs.PruneWorker},
       {"20 4 * * *", PhoenixKit.Modules.Storage.Workers.BucketLogPruneWorker},
       {"0 * * * *", PhoenixKit.Notifications.DigestWorker, args: %{cadence: "hourly"}},
       {"0 */12 * * *", PhoenixKit.Notifications.DigestWorker, args: %{cadence: "12h"}},
       {"0 6 * * *", PhoenixKit.Notifications.DigestWorker, args: %{cadence: "daily"}},
       {"0 6 * * 1", PhoenixKit.Notifications.DigestWorker, args: %{cadence: "weekly"}}
     ]}
  ]

import_config "#{config_env()}.exs"

# PhoenixKit — what to call the admin area
#
# The admin header and the account menu both say "Admin Panel" by default.
# To call it something else AND keep it translated for every visitor, pick
# one of these built-in names:
#
#     :admin_panel     "Admin Panel"     pairs with admin_path: "/admin"
#     :dashboard       "Dashboard"       pairs with admin_path: "/dashboard"
#     :backoffice      "Backoffice"      pairs with admin_path: "/backoffice"
#     :console         "Console"         pairs with admin_path: "/console"
#     :control_panel   "Control Panel"   pairs with admin_path: "/control_panel"
#     :workspace       "Workspace"       pairs with admin_path: "/workspace"
#     :portal          "Portal"          pairs with admin_path: "/portal"
#     :my_account      "My Account"      pairs with admin_path: "/my_account"
#     :management      "Management"      pairs with admin_path: "/management"
#     :studio          "Studio"          pairs with admin_path: "/studio"
#
#     config :phoenix_kit, admin_panel_label: :workspace
#
# Leave it unset and the name is derived from :admin_path, so renaming the
# URL renames the wording with it — one key, never out of step:
#
#     config :phoenix_kit, admin_path: "/backoffice"   # URL and header
#
# A free-text string works too, for a brand name no preset covers:
#
#     config :phoenix_kit, admin_panel_label: "Acme HQ"
#
# ...but it is NOT translated. One string, shown to every visitor in every
# language. That is what the presets above are for.

# Streaming playlists and fMP4 segments get their proper types when served as plain files.
config :mime, :types, %{
  "application/vnd.apple.mpegurl" => ["m3u8"],
  "video/iso.segment" => ["m4s"]
}
