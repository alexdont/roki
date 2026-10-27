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

  pipeline :csrf do
    plug :protect_from_forgery
  end

  pipeline :session_user do
    plug :fetch_session
    plug PhoenixKitWeb.Users.Auth, :fetch_phoenix_kit_current_user
  end

  scope "/", RokiWeb do
    pipe_through :session_user

    get "/stream/:id/:file", StreamController, :file
    get "/peek/:type/:id", PeekController, :show
    get "/library/:type/:id", LibraryController, :show
    get "/dict/:lang", DictController, :show
    get "/hevc-test", PageController, :hevc_test
    get "/hevc-test/file/:how", PageController, :hevc_test_file
    get "/images/hevc-test", PageController, :hevc_test
    # The player lab: the browser does the whole job itself (owner only).
    get "/relay", RelayController, :bytes
    get "/lab/sample/:name", LabController, :sample
    get "/lab/bytes", LabController, :bytes
    post "/lab/report", LabController, :report
    get "/lab/reports", LabController, :reports
    get "/lab/links", LabController, :links
    # PhoenixKit's own account page (profile picture, name, email, password) is the account
    # menu's "Settings". This site's playback and services page is /:username/settings, reached
    # from the menu by this address, which only needs to know who is signed in.
    get "/account/services", AccountController, :services
    # Where MyAnimeList sends people back after they approve the site's app.
    get "/mal/callback", MalController, :callback
    # Linking a TMDB account, so ratings are saved on the person's own account: begin, and where
    # TMDB sends them back.
    get "/tmdb/link", TmdbController, :link
    get "/tmdb/callback", TmdbController, :callback
    # A picture the site has not kept yet: fetched into the media library, then served from it.
    get "/img/mal/*path", ImageController, :mal
    get "/img/:size/:file", ImageController, :tmdb
  end

  scope "/", RokiWeb do
    pipe_through [:session_user, :csrf]

    post "/library/:type/:id/:what", LibraryController, :toggle
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  live_session :site,
    on_mount: [
      {PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope},
      {RokiWeb.Cached, :assign_titles},
      {RokiWeb.PlayerMode, :attach},
      {RokiWeb.SyncPull, :default}
    ] do
    scope "/", RokiWeb do
      pipe_through :browser

      live "/", RootLive, :index
      live "/home", FeaturedLive, :index
      live "/mood/:slug", MoodLive, :show
      live "/movies", CategoryLive, :movies
      live "/shows", CategoryLive, :shows
      live "/anime", CategoryLive, :anime
      live "/search", SearchLive, :index
      live "/title/tv/:id/episodes", TitleLive, :episodes
      live "/title/:type/:id", TitleLive, :show
      live "/sources/movie/:id", SourcesLive, :movie
      live "/sources/tv/:id/:season/:episode", SourcesLive, :episode
      live "/watch/movie/:id", WatchLive, :movie
      live "/watch/tv/:id/:season/:episode", WatchLive, :episode
      live "/study", StudyLive, :index
      live "/lists", ListsLive, :index
      live "/lists/:slug", ListLive, :show
      live "/:username/home", UserHomeLive, :index
      live "/:username/stats", StatsLive, :index
      live "/:username/calendar", CalendarLive, :index
      live "/:username/settings", SettingsLive, :index
      live "/:username/watched", WatchedLive, :index
      live "/:username/friends", FriendsLive, :index
      # The public profile. Last: a name is anything, so every fixed address goes before it.
      live "/:username", ProfileLive, :show
    end
  end

  # The laev terminal app's sync store: a blob store, the key in the address is the whole of the
  # authentication (401 on a malformed one), so no session and no CSRF. Bodies are handled raw.
  scope "/api/laev", RokiWeb do
    pipe_through :api

    get "/:token/:doc", SyncApiController, :show
    put "/:token/:doc", SyncApiController, :put
    patch "/:token/:doc", SyncApiController, :merge
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
