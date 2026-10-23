defmodule Roki.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Finch, [name: Swoosh.Finch]},
      RokiWeb.Telemetry,
      Roki.Repo,
      {DNSCluster, query: Application.get_env(:roki, :dns_cluster_query) || :ignore},
      PhoenixKit.Supervisor,
      # Keeps one client from spending the TMDB quota: per-client / site-wide
      # request budgets, and a short cache in front of them (see Roki.Search).
      {Roki.RateLimit, clean_period: :timer.minutes(10)},
      Roki.TTLCache,
      # Stops video conversions nobody is watching any more.
      Roki.Watch.Reaper,
      {Phoenix.PubSub, name: Roki.PubSub},
      {Oban, Application.get_env(:roki, Oban)},
      # Start a worker by calling: Roki.Worker.start_link(arg)
      # {Roki.Worker, arg},
      # Start to serve requests, typically the last entry
      RokiWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Roki.Supervisor]
    Supervisor.start_link(children, opts) |> PhoenixKit.boot()
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    RokiWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
