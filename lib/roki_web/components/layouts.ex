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

    links =
      [{"Featured", ~p"/home"}, {"Lists", ~p"/lists"}] ++
        if username,
          do: [
            {"Shelf", ~p"/#{username}/home"},
            {"Stats", ~p"/#{username}/stats"},
            {"Calendar", ~p"/#{username}/calendar"}
          ],
          else: []

    assigns =
      assigns |> assign(:scope, scope) |> assign(:username, username) |> assign(:links, links)

    ~H"""
    <header class="navbar mx-auto max-w-6xl gap-2 px-4 sm:px-6 lg:px-8">
      <div class="flex-none">
        <a href={~p"/home"} class="flex w-fit items-center gap-2 text-lg font-bold tracking-tight">
          <span class="inline-flex h-7 w-7 items-center justify-center rounded-md bg-primary text-primary-content">
            <.icon name="hero-play-solid" class="h-4 w-4" />
          </span>
          roki
        </a>
      </div>
      <%!-- Search: the box on wider screens, an icon on a phone. --%>
      <form
        action={~p"/search"}
        method="get"
        role="search"
        class="hidden flex-1 justify-center px-4 sm:flex"
      >
        <label class="input input-bordered input-sm flex w-full max-w-md items-center gap-2">
          <.icon name="hero-magnifying-glass" class="h-4 w-4 opacity-60" />
          <input
            type="search"
            name="q"
            placeholder="Search movies and shows"
            autocomplete="off"
            class="grow"
          />
        </label>
      </form>
      <div class="flex-1 sm:hidden"></div>
      <.link
        navigate={~p"/search"}
        class="btn btn-ghost btn-square sm:hidden"
        aria-label="Search"
      >
        <.icon name="hero-magnifying-glass" class="h-5 w-5" />
      </.link>
      <%!-- One list of links, two homes: in the bar from laptop width up, in the menu
            beside the avatar below it — so a long set never crowds the search box. --%>
      <nav class="hidden flex-none items-center gap-1 lg:flex">
        <.link
          :for={{label, href} <- @links}
          navigate={href}
          class={["btn btn-ghost btn-sm", active?(@current_path, href) && "btn-active"]}
        >
          {label}
        </.link>
      </nav>
      <div class="dropdown dropdown-end lg:hidden">
        <div tabindex="0" role="button" class="btn btn-ghost btn-square" aria-label="Menu">
          <.icon name="hero-bars-3" class="h-6 w-6" />
        </div>
        <ul
          tabindex="0"
          class="menu dropdown-content z-[60] mt-3 w-56 rounded-box border border-base-300 bg-base-100 p-2 shadow-xl"
        >
          <li :for={{label, href} <- @links}>
            <.link navigate={href} class={active?(@current_path, href) && "menu-active"}>
              {label}
            </.link>
          </li>
          <li class="menu-title mt-1">Theme</li>
          <li class="px-2 py-1"><.theme_toggle /></li>
        </ul>
      </div>
      <div class="flex flex-none items-center gap-3">
        <div class="hidden lg:block"><.theme_toggle /></div>
        <%!-- PhoenixKit's own account menu: avatar, settings, admin, log out; or
              log in / register for a visitor. --%>
        <PhoenixKitWeb.Components.UserDashboardNav.user_dropdown
          scope={@scope}
          current_path={@current_path}
        />
      </div>
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
  defp active?(current_path, href) when is_binary(current_path),
    do: current_path == href or String.starts_with?(current_path, href <> "/")

  defp active?(_, _), do: false
end
