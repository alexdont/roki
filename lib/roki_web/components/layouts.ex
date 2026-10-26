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

  attr :current_path, :string, default: "/"
  attr :wide, :boolean, default: false, doc: "full-width content, for the home page"

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
      {"Anime", ~p"/anime"}
    ]

    assigns =
      assigns
      |> assign(:scope, scope)
      |> assign(:username, username)
      |> assign(:sections, sections)

    ~H"""
    <header class="relative border-b border-base-300/60">
      <div class="mx-auto flex h-14 max-w-6xl items-stretch gap-1 px-4 sm:px-6 lg:px-8">
        <a
          href={~p"/home"}
          class="flex items-center gap-2 pr-3 text-lg font-bold tracking-tight"
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
          <%!-- Placeholder: manga comes later. --%>
          <span
            class="flex cursor-not-allowed items-center gap-1.5 px-3 text-sm font-medium text-base-content/35"
            title="Coming soon"
          >
            Manga <span class="badge badge-ghost badge-xs">soon</span>
          </span>
        </nav>

        <div class="flex-1"></div>

        <div class="flex items-stretch">
          <button
            type="button"
            phx-click={
              JS.hide(to: "#mobile-nav")
              |> JS.toggle(to: "#search-pop", display: "flex")
              |> JS.focus(to: "#search-input")
            }
            class="flex items-center px-3 text-base-content/70 transition hover:bg-base-200 hover:text-base-content"
            aria-label="Search"
            title="Search"
          >
            <.icon name="hero-magnifying-glass" class="h-5 w-5" />
          </button>
          <.top_icon
            :if={@username}
            href={~p"/#{@username}/calendar"}
            icon="hero-calendar-days"
            label="Calendar"
            active={active?(@current_path, ~p"/#{@username}/calendar")}
          />
          <.top_icon
            :if={@username}
            href={~p"/#{@username}"}
            icon="hero-user-circle"
            label="Profile"
            active={@current_path == "/#{@username}"}
          />
          <.top_icon
            :if={@username}
            href={~p"/#{@username}/home"}
            icon="hero-star"
            label="Shelf"
            active={active?(@current_path, ~p"/#{@username}/home")}
          />
        </div>

        <%!-- PhoenixKit's own account menu: avatar, Settings (which opens this site's settings
              page), admin, log out; or log in / register for a visitor. --%>
        <%!-- The player and theme switches live in that menu. The menu is PhoenixKit's and takes no
              slot, so the hook moves these rows in under Settings (and back after a re-render). --%>
        <div id="account-menu" phx-hook="MenuExtras" class="flex items-center pl-1">
          <PhoenixKitWeb.Components.UserDashboardNav.user_dropdown
            scope={@scope}
            current_path={@current_path}
          />
          <template data-role="menu-extras">
            <li :if={@username} data-menu-extras>
              <.link navigate={~p"/#{@username}/settings"} class="flex items-center gap-3">
                <.icon name="hero-adjustments-horizontal" class="h-4 w-4" />
                <span>Playback & services</span>
              </.link>
            </li>
            <li data-menu-extras class="mt-1 border-t border-base-300 pt-1">
              <div class="flex items-center justify-between gap-3 !bg-transparent hover:!bg-transparent">
                <span class="text-sm">Watch in</span>
                <.player_toggle />
              </div>
            </li>
            <li data-menu-extras>
              <div class="flex items-center justify-between gap-3 !bg-transparent hover:!bg-transparent">
                <span class="text-sm">Theme</span>
                <.theme_toggle />
              </div>
            </li>
          </template>
        </div>

        <%!-- On a phone the sections move into a panel under the header (not a small dropdown
              that can run off the edge of the screen). --%>
        <button
          type="button"
          phx-click={JS.toggle(to: "#mobile-nav", display: "block") |> JS.hide(to: "#search-pop")}
          class="flex items-center px-2 text-base-content/70 hover:text-base-content md:hidden"
          aria-label="Menu"
          aria-controls="mobile-nav"
        >
          <.icon name="hero-bars-3" class="h-6 w-6" />
        </button>
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
        <div class="flex cursor-not-allowed items-center justify-between rounded-lg px-4 py-3 text-base font-medium text-base-content/40">
          Manga <span class="badge badge-ghost badge-sm">soon</span>
        </div>
      </nav>
    </header>

    <main class="px-4 py-8 sm:px-6 lg:px-8">
      <div class={["mx-auto space-y-4", if(@wide, do: "max-w-6xl", else: "max-w-2xl")]}>
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
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

  # An icon button, the full height of the header.
  defp top_icon(assigns) do
    ~H"""
    <.link
      navigate={@href}
      aria-label={@label}
      title={@label}
      class={[
        "flex items-center border-b-2 px-2 transition hover:bg-base-200 min-[380px]:px-3",
        if(@active,
          do: "border-primary text-primary",
          else: "border-transparent text-base-content/70 hover:text-base-content"
        )
      ]}
    >
      <.icon name={@icon} class="h-5 w-5" />
    </.link>
    """
  end

  defp active?(current_path, href) when is_binary(current_path),
    do: current_path == href or String.starts_with?(current_path, href <> "/")

  defp active?(_, _), do: false
end
