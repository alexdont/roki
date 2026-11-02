defmodule RokiWeb.Router do
  use RokiWeb, :router

  import PhoenixKitWeb.Integration
  import Manga.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {RokiWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug PhoenixKitWeb.Plugs.Integration
    # Who is signed in, on every page rather than only the ones behind :require_auth. This is
    # also the one place a session is rebuilt from the remember-me cookie, so without it a
    # session cookie that did not survive — an installed web app the phone has stopped — left
    # the whole site looking signed out until something under /manga or /phoenix_kit was opened
    # and quietly put it back.
    plug PhoenixKitWeb.Users.Auth, :fetch_phoenix_kit_current_scope
  end

  pipeline :csrf do
    plug :protect_from_forgery
  end

  # The manga reader's pages are for a signed-in person and say so, as they did in the app they
  # came from.
  pipeline :require_auth do
    plug PhoenixKitWeb.Users.Auth, :fetch_phoenix_kit_current_scope
    plug PhoenixKitWeb.Users.Auth, :phoenix_kit_require_authenticated_user
  end

  pipeline :session_user do
    plug :fetch_session
    plug PhoenixKitWeb.Users.Auth, :fetch_phoenix_kit_current_user
  end

  # ── the manga reader ──────────────────────────────────────────────
  # The whole of it, as it stands in the app it came from: same routes, same controller, same
  # live views, with `/reader` reading `/manga` here. Above this app's own routes, since
  # `/:username` matches any single segment.

  # The packaged reader, mounted whole — the one the app this came from reads with. Its own
  # templates, its own API surface (images, settings, progress, marks, gifs), its own snap
  # algorithm, all under this one prefix.
  #
  # The /manga routes below render this app's older in-tree copy of the same reader, which is
  # what the port carried across and what the chapter links still point at. The two are not the
  # same code: the in-tree copy reports itself as build "sg3", the package as "manhwa-bf1". The
  # app this came from mounts the package beside its own copy in exactly this way and says to
  # swap the canonical links over once it proves out, which has not happened there either.
  scope "/" do
    pipe_through [:browser, :require_auth]

    manga_reader("/manga/v3")
  end

  scope "/manga", RokiWeb do
    pipe_through [:browser, :require_auth]

    get "/", MangaController, :home
    # Parallel test route for the redesigned home (hero + cover-dominant
    # cards + animated reordering). Swap into "/" once it's proven out.
    get "/home2", MangaController, :home2
    # Persisted old/new UI switch — when on, "/" and "/..."
    # redirect to their v2 counterparts.
    # Superseded by the HistoryLive route above; kept as a fallback so the
    # old calendar stays comparable (and revertable) while the new one beds in.
    get "/legacy/history", MangaController, :history
    get "/categories", MangaController, :categories
    get "/stats", MangaController, :stats
    get "/explore", MangaController, :explore
    get "/search", MangaController, :search
    # Async per-extension fragments for the two pages above — the
    # pages render instantly and fill these in as sources answer.
    get "/search/extension", MangaController, :search_extension
    get "/explore/extension", MangaController, :explore_extension
    # The pages themselves are at /:username/… now; these keep the reader's own links working.
    get "/comments", MangaController, :moved
    get "/tierlist", MangaController, :moved
    get "/grid", MangaController, :moved
    # The boards save themselves back here, from the page wherever it is drawn.
    put "/tierlist", MangaController, :update_tierlist
    put "/grid", MangaController, :update_grid
    # Parallel test route for the redesigned details page (v2).
    get "/manga2/:source/:slug", MangaController, :index2
    get "/proxy/image", MangaController, :proxy_image
    # Chapter-page images from the kotatsu-parsers sidecar (see
    # RokiWeb.KotatsuProxyController) — reader <img> tags for
    # kotatsu-backed sources point here, never at upstream CDNs.
    get "/kotatsu/image", KotatsuProxyController, :image
    # Kotatsu source extensions: per-user picker + browse surface.
    get "/extensions", KotatsuController, :extensions
    post "/extensions", KotatsuController, :update_extensions
    # MyAnimeList OAuth login (per-user list sync).
    get "/trackers/mal/connect", TrackerController, :connect
    get "/trackers/mal/callback", TrackerController, :callback
    post "/trackers/mal/disconnect", TrackerController, :disconnect
    get "/kotatsu/:name/manga", KotatsuController, :manga
    get "/kotatsu/:name/read", KotatsuController, :read
    post "/sync_caught_up", MangaController, :sync_caught_up
    post "/categories", MangaController, :create_category
    put "/categories/reorder", MangaController, :reorder_categories
    put "/categories/:id", MangaController, :rename_category
    delete "/categories/:id", MangaController, :delete_category
    get "/categories/:id/manga_ids", MangaController, :category_manga_ids
    put "/settings/auto_resume", MangaController, :update_auto_resume
    put "/settings/auto_resume_timer", MangaController, :update_auto_resume_timer
    put "/settings/auto_resume_art", MangaController, :update_auto_resume_art
    put "/settings/default_tap_zone", MangaController, :update_default_tap_zone
    put "/settings/default_reading_direction", MangaController, :update_default_reading_direction
    put "/settings/default_smart_scroll", MangaController, :update_default_smart_scroll
    put "/settings/smart_panels", MangaController, :update_smart_panels
    put "/settings/reader_ui_v2", MangaController, :update_reader_ui_v2
    put "/settings/default_page_padding", MangaController, :update_default_page_padding
    put "/settings/smart_scroll_config", MangaController, :update_smart_scroll_config
    put "/settings/timezone", MangaController, :update_timezone

    # Last on purpose: each of these begins with a wildcard segment, so a literal route
    # declared after them would never be reached. In the app this came from, the series
    # paths carried an extra /manga segment that kept them apart; here they do not.
    get "/:source/:slug", MangaController, :index
    get "/:source/:slug/migrate/search", MangaController, :migrate_search
    get "/:source/:slug/migrate/search_one", MangaController, :migrate_search_one
    post "/:source/:slug/migrate", MangaController, :migrate
    put "/:source/:slug/completed", MangaController, :toggle_completed
    # MyAnimeList per-user title linking (enrichment).
    get "/:source/:slug/mal/search", MangaController, :mal_search
    post "/:source/:slug/mal/link", MangaController, :mal_link
    post "/:source/:slug/mal/unlink", MangaController, :mal_unlink
    post "/:source/:slug/mal/refresh", MangaController, :mal_refresh
    post "/:source/:slug/save", MangaController, :save
    post "/:source/:slug/refresh", MangaController, :refresh
    delete "/:source/:slug/save", MangaController, :unsave
    put "/:source/:slug/reading_mode", MangaController, :update_reading_mode
    put "/:source/:slug/reading_direction", MangaController, :update_reading_direction
    put "/:source/:slug/comments_visible", MangaController, :update_comments_visible
    put "/:source/:slug/reading_rotation", MangaController, :update_reading_rotation
    put "/:source/:slug/smart_crop", MangaController, :update_smart_crop
    put "/:source/:slug/tap_zone_preset", MangaController, :update_tap_zone_preset
    put "/:source/:slug/progress", MangaController, :update_progress
    put "/:source/:slug/reading_time", MangaController, :update_reading_time
    put "/:source/:slug/custom_cover", MangaController, :update_custom_cover
    post "/:source/:slug/cover", MangaController, :set_cover
    post "/:source/:slug/title", MangaController, :set_title
    put "/:source/:slug/reset_max_chapter", MangaController, :reset_max_chapter
    put "/:source/:slug/category", MangaController, :set_manga_category
    post "/:source/:slug/toggle_category", MangaController, :toggle_manga_category
  end

  scope "/manga/api", RokiWeb do
    pipe_through [:browser, :require_auth]

    get "/giphy/search", GiphyController, :search
    get "/giphy/trending", GiphyController, :trending
    post "/fresco-debug-log", MangaController, :fresco_debug_log

    # Last on purpose: each of these begins with a wildcard segment, so a literal route
    # declared after them would never be reached. In the app this came from, the series
    # paths carried an extra /manga segment that kept them apart; here they do not.
    get "/:source/:slug/:chapter/images", MangaController, :chapter_images
    get "/:source/:slug/:chapter/annotations", MangaController, :list_annotations
    post "/:source/:slug/:chapter/annotations", MangaController, :create_annotation
    put "/:source/:slug/:chapter/annotations/:id", MangaController, :update_annotation
    delete "/:source/:slug/:chapter/annotations/:id", MangaController, :delete_annotation
    get "/:source/:slug/:chapter/annotations/:id/detail", MangaController, :annotation_detail
    post "/:source/:slug/:chapter/annotations/:id/like", MangaController, :toggle_like
    get "/:source/:slug/:chapter/annotations/:id/replies", MangaController, :list_replies
    post "/:source/:slug/:chapter/annotations/:id/replies", MangaController, :create_reply

    delete "/:source/:slug/:chapter/annotations/:id/replies/:reply_id",
           MangaController,
           :delete_reply

    # ─── Per-(user, chapter) page overrides — manual fixes for the
    # double-page spread engine when a provider injects an ad or
    # forgets a page. Toggle: same body inserts on absence, removes
    # on presence (single endpoint, idempotent UI).
    post "/:source/:slug/:chapter/page_overrides",
         MangaController,
         :toggle_page_override

    # ─── Generic per-(user, chapter) marks API for the new fresco readers.
    # Items are typed (annotation / drawing / marker / highlight); only
    # the annotation type is wired up so far, but the list/delete
    # endpoints are type-agnostic so future types reuse them.
    get "/:source/:slug/:chapter/marks", MangaController, :list_marks
    post "/:source/:slug/:chapter/marks/annotations", MangaController, :create_mark_annotation

    post "/:source/:slug/:chapter/marks/etcher-shapes/:shape_uuid/comment",
         MangaController,
         :attach_etcher_comment

    delete "/:source/:slug/:chapter/marks/:item_id", MangaController, :delete_mark
  end

  # This scope is declared after the others: its chapter route is `/:source/:slug/:chapter`,
  # three wildcard segments that would otherwise swallow every literal three-segment route in
  # the scopes below it — `/manga2/:source/:slug` among them. In the app this came from, the
  # extra /manga segment on the series paths kept them apart.
  scope "/manga" do
    pipe_through [:browser, :require_auth]

    live_session :reader_settings,
      layout: {RokiWeb.Layouts, :manga},
      on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}] do
      # The reader's preferences were absorbed into /:username/settings; this keeps the
      # reader menus' "Settings" and the MyAnimeList tracker's return link working.
      get "/settings", RokiWeb.MangaController, :settings

      # Reading history, built on phoenix_live_calendar. Replaced the
      # dead-view MangaController.history/2, which stays reachable at
      # /manga/legacy/history as a fallback.
      get "/history", RokiWeb.MangaController, :moved

      # Last on purpose: each of these begins with a wildcard segment, so a literal route
      # declared after them would never be reached. In the app this came from, the series
      # paths carried an extra /manga segment that kept them apart; here they do not.
      # Static path; must be declared before the dynamic :chapter live route below
      # so it isn't shadowed by /manga/:source/:slug/:chapter.
      get "/:source/:slug/comments", RokiWeb.MangaController, :manga_annotations
    end

    # Legacy MangaReaderLive — kept reachable at `/manga/legacy/manga/...`
    # so old comment notification links (built before the fresco switch)
    # still resolve to the OSD reader they were anchored against, and
    # scroll-mode users still get the existing scroll_strip-free OSD
    # experience.
    live_session :manga_reader,
      on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}] do
      live "/legacy/:source/:slug/:chapter", RokiWeb.Live.MangaReaderLive, :show
      live "/legacy/:source/:slug/:chapter/:page", RokiWeb.Live.MangaReaderLive, :show
    end

    # Last on purpose: each of these begins with a wildcard segment, so a literal route
    # declared after them would never be reached. In the app this came from, the series
    # paths carried an extra /manga segment that kept them apart; here they do not.
    # Canonical reader URL — dispatches by reading_mode:
    #   paged / double_page → Fresco paged reader (show_fresco)
    #   scroll              → Fresco scroll-strip reader (show_fresco_strip)
    # Legacy is only reachable via explicit /manga/legacy/manga/... URLs.
    get "/:source/:slug/:chapter", RokiWeb.MangaController, :show
  end

  scope "/", RokiWeb do
    pipe_through :session_user

    get "/stream/:id/:file", StreamController, :file
    get "/peek/:type/:id", PeekController, :show
    get "/card/:type/:id", CardController, :show
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
    # The home page's Continue: straight to playing what is next, not to the title's page.
    get "/continue/:type/:id", ContinueController, :show
    # PhoenixKit sends a logged-out visitor to its own mount point (`/phoenix_kit/`) when it asks
    # this router whether that is a page — and `/:username` below would say yes, and then "no one
    # called phoenix_kit here". The mount point is not a page of this site: it leads home.
    get "/phoenix_kit", PageController, :phoenix_kit_root
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
      # A page to try, linked from nowhere yet.
      live "/:username/dating", DatingLive, :index
      live "/:username/friends", FriendsLive, :index
      # Reading, tiers, boards and what was said — the account's own pages, out of the reader's
      # menu and into the account menu. Each is owner-only.
      live "/:username/history", Live.HistoryLive, :index
      get "/:username/comments", MangaController, :annotations
      get "/:username/tierlist", MangaController, :tierlist
      get "/:username/grid", MangaController, :grid
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
