defmodule Roki.MixProject do
  use Mix.Project

  def project do
    [
      app: :roki,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers:
        [:phoenix_kit_js_sources, :phoenix_kit_css_sources, :phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Roki.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:finch, "~> 0.18"},
      {:phoenix_kit, "~> 2.0"},
      # Terminal cinema as a library: per-user watchlist, stats, settings, playback.
      # Declares elixir ~> 1.20 though it compiles clean on 1.19.6 (this image) — warning only.
      {:laev, "~> 0.1.40"},
      # Build-time tooling for the mix phoenix_kit.install / .update tasks,
      # which refuse to patch code without it. PhoenixKit declares :igniter
      # optional and an optional dep is not resolved transitively, so it has
      # to be named here. dev+test only: it never reaches the supervision
      # tree or the request path, and Mix tasks are not part of a release.
      {:igniter, "~> 0.7", only: [:dev, :test]},
      # Loads .env.{MIX_ENV} -> .env -> System.get_env(), last wins. No .env
      # files exist in this repo and none should be created: on this host the
      # container environment is the only source, and it wins regardless
      # (server-agents1/adrs/0009 insets).
      {:dotenvy, "~> 1.2.0"},
      {:phoenix, "~> 1.8.15"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.7.46",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      # No ecto.create/ecto.drop anywhere in here: the project role is
      # NOSUPERUSER + NOCREATEDB and Ecto reaches the maintenance database
      # first, where CONNECT is revoked from PUBLIC on purpose. Both databases
      # are provisioned by platform/stacks/postgres/{newdb,newtestdb}.sh
      # (server-agents1 adrs/0006 and 0009).
      "ecto.setup": ["ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.setup"],
      # No ecto.create: the project role is NOCREATEDB; the test database is
      # provisioned by platform/stacks/postgres/newtestdb.sh (adrs/0009).
      test: ["ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind roki", "esbuild roki"],
      "assets.deploy": [
        "tailwind roki --minify",
        "esbuild roki --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
