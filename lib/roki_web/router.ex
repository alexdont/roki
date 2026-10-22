defmodule RokiWeb.Router do
  use RokiWeb, :router

  import PhoenixKitWeb.Integration

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {RokiWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug PhoenixKitWeb.Plugs.Integration
  end

  pipeline :session_user do
    plug :fetch_session
    plug PhoenixKitWeb.Users.Auth, :fetch_phoenix_kit_current_user
  end

  scope "/", RokiWeb do
    pipe_through :session_user

    get "/stream/:id/:file", StreamController, :file
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  live_session :site,
    on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}] do
    scope "/", RokiWeb do
      pipe_through :browser

      live "/", RootLive, :index
      live "/home", FeaturedLive, :index
      live "/search", SearchLive, :index
      live "/title/:type/:id", TitleLive, :show
      live "/study", StudyLive, :index
      live "/lists", ListsLive, :index
      live "/lists/:slug", ListLive, :show
      live "/:username/home", UserHomeLive, :index
      live "/:username/stats", StatsLive, :index
      live "/:username/calendar", CalendarLive, :index
      live "/:username/settings", SettingsLive, :index
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", RokiWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:roki, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: RokiWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  phoenix_kit_routes()
end
