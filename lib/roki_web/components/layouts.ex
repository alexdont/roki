defmodule RokiWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use RokiWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :phoenix_kit_current_scope, :any,
    default: nil,
    doc: "PhoenixKit's scope for the signed-in user (nil for a visitor)"

  attr :socket, :any,
    default: nil,
    doc: "the page's LiveView socket: the notifications bell is a nested LiveView and needs it"

  attr :conn, :any,
    default: nil,
    doc: "the connection, on a controller-rendered page — what the bell uses in place of a socket"

  attr :current_path, :string, default: "/"
  attr :wide, :boolean, default: false, doc: "full-width content, for the home page"

  attr :flush, :boolean,
    default: false,
    doc:
      "content that brings its own margins — the wrapper adds none, so it can reach the screen edge"

  slot :inner_block, required: true

  def app(assigns) do
    scope = assigns.phoenix_kit_current_scope || assigns.current_scope

    username =
      with true <- scope != nil and PhoenixKit.Users.Auth.Scope.authenticated?(scope),
           name when is_binary(name) and name != "" <-
             PhoenixKit.Users.Auth.Scope.user(scope).username do
        name
      else
        _ -> nil
      end

    # The sections of the site, left; what is yours (shelf, calendar, search), right.
    sections = [
      {"Movies", ~p"/movies"},
      {"Shows", ~p"/shows"},
      {"Anime", ~p"/anime"},
      {"Manga", ~p"/manga"}
    ]

    # The bell is a nested LiveView, so it needs whatever this page is: a socket on a LiveView,
    # the connection on a controller page. Reading only the socket meant it vanished from the
    # header on every controller-rendered page — the whole manga reader, as it turned out.
    bell_parent = assigns[:socket] || assigns[:conn]

    # Whom the bell is for: a signed-in person, on a page that gave us one of those.
    bell_user =
      if username && bell_parent && PhoenixKit.Notifications.enabled?(),
        do: PhoenixKit.Users.Auth.Scope.user(scope)

    assigns =
      assigns
      |> assign(:scope, scope)
      |> assign(:username, username)
      |> assign(:bell_user, bell_user)
      |> assign(:bell_parent, bell_parent)
      |> assign(:user, username && PhoenixKit.Users.Auth.Scope.user(scope))
      |> assign(
        :admin?,
        username != nil and PhoenixKit.Users.Auth.Scope.can_access_admin_area?(scope)
      )
      |> assign(:sections, sections)

    ~H"""
    <header class="site-header relative border-b border-base-300/60">
      <div class="mx-auto flex h-14 max-w-6xl items-stretch gap-1 px-3 sm:px-6 lg:px-8">
        <a
          href={~p"/home"}
          class="flex items-center gap-2 pr-1.5 text-lg font-bold tracking-tight min-[420px]:pr-3"
          aria-label="roki — home"
        >
          <span class="inline-flex h-7 w-7 items-center justify-center rounded-md bg-primary text-primary-content">
            <.icon name="hero-play-solid" class="h-4 w-4" />
          </span>
          <span class="hidden min-[340px]:inline">roki</span>
        </a>

        <nav class="hidden items-stretch md:flex" aria-label="Sections">
          <.top_link
            :for={{label, href} <- @sections}
            href={href}
            active={active?(@current_path, href)}
          >
            {label}
          </.top_link>
        </nav>

        <div class="flex-1"></div>

        <%!-- The right side is one quiet row: search, new episodes, the bell, then home (the star) and
              you, last. On a phone new episodes moves into the account menu. --%>
        <div class="flex items-stretch">
          <button
            type="button"
            phx-click={
              JS.hide(to: "#mobile-nav")
              |> JS.hide(to: "#account-pop")
              |> JS.toggle(to: "#search-pop", display: "flex")
              |> JS.focus(to: "#search-input")
            }
            class={icon_button()}
            aria-label="Search"
            title="Search"
          >
            <.icon name="hero-magnifying-glass" class="h-5 w-5" />
          </button>
          <.top_icon
            :if={@username}
            href={~p"/#{@username}/calendar"}
            icon="hero-calendar-days"
            label="New episodes"
            class="max-md:hidden"
            active={active?(@current_path, ~p"/#{@username}/calendar")}
          />
          <%!-- Notifications: PhoenixKit's bell, a sticky nested LiveView, so its count keeps up
                as pages change. Its button is restyled to match the others. --%>
          <div
            :if={@bell_user}
            class="flex items-stretch [&>*]:flex [&>*]:items-stretch [&_.dropdown]:flex [&_.dropdown]:items-stretch max-sm:[&_.dropdown-content]:!fixed max-sm:[&_.dropdown-content]:!inset-x-2 max-sm:[&_.dropdown-content]:!top-14 max-sm:[&_.dropdown-content]:!mt-0 max-sm:[&_.dropdown-content]:!w-auto [&_label]:flex [&_label]:h-full [&_label]:min-h-0 [&_label]:w-10 [&_label]:items-center [&_label]:justify-center [&_label]:rounded-none [&_label]:border-b-2 [&_label]:border-transparent [&_label]:p-0 [&_label]:transition [&_label:hover]:bg-base-200 min-[420px]:[&_label]:w-12"
          >
            <%!-- `sticky:` only means anything for a LiveView nested in another LiveView; handed a
                  connection it renders nothing at all, which is how the bell went missing from
                  every controller page here. --%>
            {Phoenix.Component.live_render(
              @bell_parent,
              PhoenixKitWeb.Live.NotificationsBell,
              [
                id: "pk-notifications-bell",
                session: %{
                  "user_uuid" => @bell_user.uuid,
                  "locale" => nil,
                  "can_open_inbox" => false
                }
              ] ++ if(assigns[:socket], do: [sticky: true], else: [])
            )}
          </div>

          <.top_icon
            :if={@username}
            href={~p"/#{@username}/home"}
            icon="hero-star"
            label="Home"
            active={active?(@current_path, ~p"/#{@username}/home")}
          />

          <div :if={@username} class="flex items-stretch sm:relative">
            <button
              type="button"
              id="account-button"
              phx-click={
                JS.hide(to: "#mobile-nav")
                |> JS.hide(to: "#search-pop")
                |> JS.toggle(to: "#account-pop", display: "block")
              }
              class="flex items-center border-b-2 border-transparent px-2.5 transition hover:bg-base-200 min-[420px]:px-3.5"
              aria-label="Your account"
              aria-controls="account-pop"
            >
              <PhoenixKitWeb.Components.Core.UserInfo.user_avatar
                user={@user}
                size="sm"
                class="!rounded-full"
              />
            </button>
            <%!-- The account menu: who you are first (it is the way to your profile and shelves), then
                    the few things you do now and then. Theme and player live in Settings. --%>
            <div
              :if={@username}
              id="account-pop"
              class="absolute right-3 top-full z-50 mt-1 hidden w-[min(18rem,calc(100vw-1.5rem))] rounded-box border border-base-300 bg-base-100 p-2 shadow-xl sm:right-0"
              phx-click-away={JS.hide(to: "#account-pop")}
              phx-window-keydown={JS.hide(to: "#account-pop")}
              phx-key="escape"
            >
              <.link
                navigate={~p"/#{@username}"}
                phx-click={JS.hide(to: "#account-pop")}
                class="flex items-center gap-3 rounded-xl p-2 transition hover:bg-base-200"
              >
                <PhoenixKitWeb.Components.Core.UserInfo.user_avatar
                  user={@user}
                  size="lg"
                  class="!rounded-full"
                />
                <span class="min-w-0">
                  <span class="block truncate font-semibold">{@username}</span>
                  <span class="block text-xs text-base-content/60">Profile, shelves and stats</span>
                </span>
              </.link>

              <div class="my-2 border-t border-base-300/70"></div>

              <.menu_row
                href={~p"/#{@username}/calendar"}
                icon="hero-calendar-days"
                class="md:hidden"
                active={active?(@current_path, ~p"/#{@username}/calendar")}
              >
                New episodes
              </.menu_row>
              <%!-- Where Play opens things, right here: it is changed often enough to live in the menu. --%>
              <div class="px-3 pb-1 pt-1.5">
                <p class="mb-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/50">
                  Watch in
                </p>
                <.player_switch class="w-full" />
              </div>

              <div class="my-2 border-t border-base-300/70"></div>

              <.menu_row
                href={~p"/#{@username}/friends"}
                icon="hero-user-group"
                active={active?(@current_path, ~p"/#{@username}/friends")}
              >
                Friends
              </.menu_row>
              <.menu_row
                href={~p"/#{@username}/settings"}
                icon="hero-cog-6-tooth"
                active={active?(@current_path, ~p"/#{@username}/settings")}
              >
                Settings
              </.menu_row>
              <.menu_row
                :if={@admin?}
                href={PhoenixKit.Utils.Routes.path("/admin")}
                icon="hero-shield-check"
              >
                Admin
              </.menu_row>

              <div class="my-2 border-t border-base-300/70"></div>

              <.link
                href={PhoenixKit.Utils.Routes.path("/users/log-out")}
                method="delete"
                class="flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-medium text-error transition hover:bg-error/10"
              >
                <.icon name="hero-arrow-right-on-rectangle" class="h-5 w-5" /> Log out
              </.link>
            </div>
          </div>

          <%!-- A visitor gets the two ways in, nothing else. --%>
          <div :if={!@username} class="flex items-center gap-1.5 px-1">
            <a href={PhoenixKit.Utils.Routes.path("/users/log-in")} class="btn btn-ghost btn-sm">
              Log in
            </a>
            <a
              href={PhoenixKit.Utils.Routes.path("/users/register")}
              class="btn btn-primary btn-sm max-[380px]:hidden"
            >
              Sign up
            </a>
          </div>

          <%!-- On a phone the sections move into a panel under the header (not a small dropdown
                that can run off the edge of the screen). --%>
          <button
            type="button"
            phx-click={
              JS.toggle(to: "#mobile-nav", display: "block")
              |> JS.hide(to: "#search-pop")
              |> JS.hide(to: "#account-pop")
            }
            class={[icon_button(), "md:hidden"]}
            aria-label="Menu"
            aria-controls="mobile-nav"
          >
            <.icon name="hero-bars-3" class="h-6 w-6" />
          </button>
        </div>
      </div>

      <%!-- Search opens under the icon, big enough to type in; Enter goes to the results, Escape or
            a click elsewhere puts it away. --%>
      <form
        id="search-pop"
        action={~p"/search"}
        method="get"
        role="search"
        class="absolute right-4 top-full z-50 hidden w-[min(24rem,calc(100vw-2rem))] items-center gap-2 rounded-box border border-base-300 bg-base-100 p-2 shadow-xl sm:right-6 lg:right-8"
        phx-click-away={JS.hide(to: "#search-pop")}
        phx-window-keydown={JS.hide(to: "#search-pop")}
        phx-key="escape"
      >
        <.icon name="hero-magnifying-glass" class="ml-1 h-5 w-5 shrink-0 opacity-60" />
        <input
          id="search-input"
          type="search"
          name="q"
          placeholder="Search movies and shows"
          autocomplete="off"
          class="input input-ghost w-full focus:outline-none"
        />
      </form>

      <nav
        id="mobile-nav"
        aria-label="Sections"
        class="absolute inset-x-3 top-full z-50 mt-1 hidden rounded-box border border-base-300 bg-base-100 p-2 shadow-xl md:hidden"
        phx-click-away={JS.hide(to: "#mobile-nav")}
        phx-window-keydown={JS.hide(to: "#mobile-nav")}
        phx-key="escape"
      >
        <.link
          :for={{label, href} <- @sections}
          navigate={href}
          class={[
            "flex items-center justify-between rounded-lg px-4 py-3 text-base font-medium",
            if(active?(@current_path, href),
              do: "bg-base-200 text-primary",
              else: "hover:bg-base-200"
            )
          ]}
        >
          {label}
          <.icon name="hero-chevron-right-micro" class="h-4 w-4 opacity-40" />
        </.link>
      </nav>
    </header>

    <main class={unless @flush, do: "px-4 py-8 sm:px-6 lg:px-8"}>
      <%!-- Flush content is laid out by whoever wrote it. Wrapping it in this app's padding and
            width as well would indent it twice over — on a phone that is the whole screen
            margin spent twice, and the page can no longer reach the edge. --%>
      <div :if={@flush} class="flush-page">{render_slot(@inner_block)}</div>
      <div
        :if={!@flush}
        class={["mx-auto space-y-4", if(@wide, do: "max-w-6xl", else: "max-w-2xl")]}
      >
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  The layout the manga reader's own pages render inside: this site's header, then the page.

  Those pages came from an app where they were the whole site, so they carry their own bar and
  nothing else — which left no way back to films, the profile or search. Rather than edit the
  twenty-odd templates, they are wrapped in `app/1`, so the header keeps exactly one definition
  and a change to it reaches every page here.

  Used by the controller pages and by the live session behind `/manga/settings` and
  `/manga/history`, which is why it takes its path from `@conn` only when there is one — a
  LiveView has a socket instead.

  The chapter reader itself is deliberately NOT wrapped: it is a full-screen canvas.
  """
  # The manga pages' own navigation. The header above carries what spans the whole site
  # (Movies, Shows, Anime, Manga, search, notifications, the account menu), so this row
  # carries only what exists for manga and nothing else — which is why these pages no
  # longer need a menu of their own. Settings and Stats are missing on purpose: they are
  # this site's pages now, at /:username/settings and /:username/stats.
  @manga_nav [
    {"Explore", "/manga/explore"},
    {"Categories", "/manga/categories"},
    {"History", "/manga/history"},
    {"Comments", "/manga/comments"},
    {"Tierlist", "/manga/tierlist"},
    {"Grid", "/manga/grid"}
  ]

  def manga(assigns) do
    path =
      (assigns[:conn] && assigns.conn.request_path) || assigns[:current_path] || "/manga"

    # Map.merge, not assign/2: a controller renders this layout with a plain assigns map,
    # which Phoenix.Component.assign/2 refuses.
    assigns =
      Map.merge(assigns, %{path: path, nav: @manga_nav, resume: assigns[:resume_manga]})

    ~H"""
    <.app
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      socket={assigns[:socket]}
      conn={assigns[:conn]}
      current_path={@path}
      flush
    >
      <nav class="mx-auto flex max-w-6xl flex-wrap items-center gap-2 px-4 pt-6">
        <a
          :for={{label, href} <- @nav}
          href={href}
          class={["btn btn-sm", (@path == href && "btn-primary") || "btn-ghost"]}
        >
          {label}
        </a>
        <%!-- Carry on reading, from wherever you are. Each page used to draw this for
             itself above its own menu; one row holds both now. --%>
        <a
          :if={@resume && @resume.last_chapter}
          href={~p"/manga/#{@resume.source}/#{@resume.slug}/#{@resume.last_chapter}"}
          class="btn btn-sm btn-primary ml-auto sm:px-8"
        >
          ▶ Resume
        </a>
      </nav>
      {@inner_content}
    </.app>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Which player this device uses: the page's own (browser) or an app such as VLC (external).
  Two icons, lit from `data-player` on the page element (set before paint in root.html.heex and
  kept by app.js), so it reads right on every page. A click goes to the open LiveView as
  `set_mode`; `RokiWeb.PlayerMode` makes sure there is always something to answer it.
  """
  def player_toggle(assigns) do
    ~H"""
    <div
      class="card relative flex flex-row items-center rounded-full border-2 border-base-300 bg-base-300"
      role="group"
      aria-label="Where to watch"
    >
      <div class="absolute left-1/2 h-full w-1/2 rounded-full border-1 border-base-200 bg-primary transition-[left] [[data-player=browser]_&]:left-0" />
      <button
        class="relative flex w-1/2 cursor-pointer justify-center p-2.5 text-base-content [[data-player=browser]_&]:text-primary-content"
        phx-click="set_mode"
        phx-value-mode="browser"
        title="Watch in the browser"
        aria-label="Watch in the browser"
      >
        <.icon name="hero-window" class="size-5" />
      </button>
      <button
        class="relative flex w-1/2 cursor-pointer justify-center p-2.5 text-primary-content [[data-player=browser]_&]:text-base-content"
        phx-click="set_mode"
        phx-value-mode="external"
        title="Watch in an external player (VLC and the like)"
        aria-label="Watch in an external player"
      >
        <.icon name="hero-arrow-top-right-on-square" class="size-5" />
      </button>
    </div>
    """
  end

  @doc """
  The same choice with words: a two-part switch, *Browser* or *VLC / app*, lit from
  `data-player` on the page like `player_toggle/1`, sending `set_mode` the same way. For the
  places the choice is made most — the account menu and beside Play on a title.
  """
  attr :class, :any, default: nil
  attr :size, :string, default: "md", doc: "md, or sm for a tight row"

  def player_switch(assigns) do
    ~H"""
    <div
      class={["inline-grid grid-cols-2 rounded-full bg-base-200 p-0.5", @class]}
      role="group"
      aria-label="Where to watch"
    >
      <button
        type="button"
        phx-click="set_mode"
        phx-value-mode="browser"
        class={[
          "flex items-center justify-center gap-1.5 whitespace-nowrap rounded-full font-semibold transition",
          @size == "sm" && "px-2.5 py-1 text-xs",
          @size != "sm" && "px-3 py-1.5 text-sm",
          "text-base-content/60 hover:text-base-content [[data-player=browser]_&]:bg-base-100 [[data-player=browser]_&]:text-base-content [[data-player=browser]_&]:shadow-sm"
        ]}
        title="Play here, in the browser"
      >
        <.icon name="hero-window" class="h-4 w-4" /> Browser
      </button>
      <button
        type="button"
        phx-click="set_mode"
        phx-value-mode="external"
        class={[
          "flex items-center justify-center gap-1.5 whitespace-nowrap rounded-full font-semibold transition",
          @size == "sm" && "px-2.5 py-1 text-xs",
          @size != "sm" && "px-3 py-1.5 text-sm",
          "text-base-content/60 hover:text-base-content [[data-player=external]_&]:bg-base-100 [[data-player=external]_&]:text-base-content [[data-player=external]_&]:shadow-sm"
        ]}
        title="Hand the release to VLC or another app"
      >
        <.icon name="hero-arrow-top-right-on-square" class="h-4 w-4" /> VLC / app
      </button>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end

  # The link for the page you are on is lit; /lists stays lit inside a list.
  attr :href, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  # A section link: as tall as the header, the current one underlined.
  defp top_link(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class={[
        "flex items-center border-b-2 px-3 text-sm font-medium transition hover:bg-base-200",
        if(@active,
          do: "border-primary text-base-content",
          else: "border-transparent text-base-content/70 hover:text-base-content"
        )
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false
  attr :class, :any, default: nil

  # A round icon link, lit when it is the page you are on.
  defp top_icon(assigns) do
    ~H"""
    <.link
      navigate={@href}
      aria-label={@label}
      title={@label}
      class={[
        icon_button(),
        @active && "!border-primary !text-primary",
        @class
      ]}
    >
      <.icon name={@icon} class="h-5 w-5" />
    </.link>
    """
  end

  defp icon_button,
    do:
      "flex items-center justify-center border-b-2 border-transparent px-2.5 text-base-content/70 transition hover:bg-base-200 hover:text-base-content min-[420px]:px-3.5"

  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :active, :boolean, default: false
  attr :class, :any, default: nil
  slot :inner_block, required: true

  # A row of the account menu.
  defp menu_row(assigns) do
    ~H"""
    <.link
      navigate={@href}
      phx-click={JS.hide(to: "#account-pop")}
      class={[
        "flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-medium transition",
        if(@active, do: "bg-base-200 text-primary", else: "hover:bg-base-200"),
        @class
      ]}
    >
      <.icon name={@icon} class="h-5 w-5 opacity-70" />
      {render_slot(@inner_block)}
    </.link>
    """
  end

  defp active?(current_path, href) when is_binary(current_path),
    do: current_path == href or String.starts_with?(current_path, href <> "/")

  defp active?(_, _), do: false

  # ── the manga reader's header ─────────────────────────────────────
  # Two components its pages call, copied from the app they came from so those templates need no
  # change. They sit at the end of the module, where they cannot come between another
  # component's `attr` block and the function it describes.

  attr :parent, :any, required: true, doc: "@conn (controller pages) or @socket (LiveView pages)"
  attr :scope, :any, default: nil, doc: "the @phoenix_kit_current_scope assign"

  def notifications_bell(assigns) do
    user =
      case assigns[:scope] do
        %PhoenixKit.Users.Auth.Scope{user: %{} = u} -> u
        _ -> nil
      end

    assigns = assign(assigns, :user, user)

    ~H"""
    <%= if @user && PhoenixKit.Notifications.enabled?() do %>
      {live_render(@parent, PhoenixKitWeb.Live.NotificationsBell,
        id: "pk-notifications-bell",
        session: %{"user_uuid" => @user.uuid}
      )}
    <% end %>
    """
  end

  attr :scope, :any, required: true, doc: "the @phoenix_kit_current_scope assign"
  attr :current_path, :string, default: ""

  def user_menu(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.UserDashboardNav.user_dropdown
      scope={@scope}
      current_path={@current_path}
    />
    """
  end
end
