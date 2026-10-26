defmodule RokiWeb.WatchedLive do
  @moduledoc """
  `/:username/watched` — everything a user finished, newest first or by their own ratings
  (`?sort=top`, `?kind=anime`, `?tens=1` for the ten-out-of-tens), open to everyone, like the
  profile. Everything is read from this server (`Roki.Profile`).
  """
  use RokiWeb, :live_view

  import RokiWeb.PosterComponents
  import PhoenixKitWeb.Components.Core.UserInfo, only: [user_avatar: 1]

  alias PhoenixKit.Users.Auth.Scope
  alias Roki.Profile

  @page 60

  @impl true
  def mount(%{"username" => username}, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    viewer = if scope && Scope.authenticated?(scope), do: Scope.user_uuid(scope)
    user = Profile.user(username)

    if user == nil do
      {:ok, assign(socket, page_title: "Watched", user: nil, username: username, owner?: false, visible?: false, profile: nil)}
    else
      profile = Profile.get(user.uuid)
      owner? = viewer == user.uuid
      visible? = true

      socket =
        assign(socket,
          page_title: "#{user.username} · watched",
          user: user,
          username: user.username,
          uuid: user.uuid,
          owner?: owner?,
          profile: profile,
          visible?: visible?,
          history: nil,
          ratings: %{},
          sort: :latest,
          kind: :all,
          tens?: false,
          shown: @page,
          page: @page
        )

      {:ok, if(connected?(socket) and visible?, do: load(socket), else: socket)}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     assign(socket, sort: Profile.sort(params["sort"]), kind: Profile.kind(params["kind"]), tens?: params["tens"] == "1", shown: @page)}
  end

  defp load(socket) do
    uuid = socket.assigns.uuid

    socket
    |> start_async(:ratings, fn -> Profile.ratings(uuid) end)
    |> start_async(:history, fn -> Profile.history(uuid) end)
  end

  defp arranged(%{assigns: a}) when is_list(a.history),
    do: Profile.arrange(a.history, if(a.owner? or a.profile.show_ratings, do: a.ratings, else: %{}), a.kind, a.sort, a.tens?)

  defp arranged(_socket), do: []

  @impl true
  def handle_event("more", _params, socket), do: {:noreply, update(socket, :shown, &(&1 + @page))}
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:history, {:ok, items}, socket) when is_list(items), do: {:noreply, assign(socket, :history, items)}
  def handle_async(:history, _other, socket), do: {:noreply, assign(socket, :history, [])}
  def handle_async(:ratings, {:ok, ratings}, socket) when is_map(ratings), do: {:noreply, assign(socket, :ratings, ratings)}
  def handle_async(:ratings, _other, socket), do: {:noreply, socket}

  defp address(username, view) do
    query =
      Enum.flat_map(view, fn
        {:sort, :top} -> [sort: "top"]
        {:kind, k} when k != :all -> [kind: Atom.to_string(k)]
        {:tens, true} -> [tens: "1"]
        _ -> []
      end)

    base = "/#{username}/watched"
    if query == [], do: base, else: base <> "?" <> URI.encode_query(query)
  end

  @months ~w(January February March April May June July August September October November December)

  defp day(%{dated?: true, at: at}) do
    d = DateTime.from_unix!(at)
    "#{String.slice(Enum.at(@months, d.month - 1), 0, 3)} #{d.day}, #{d.year}"
  end

  defp day(_), do: nil

  @impl true
  def render(assigns) do
    assigns = assign(assigns, items: arranged(%{assigns: assigns}))

    ~H"""
    <Layouts.app
      flash={@flash}
      wide
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path={"/#{@username}/watched"}
    >
      <p :if={@user == nil} class="py-24 text-center text-base-content/60">
        There is no one called <strong>{@username}</strong> here.
      </p>

      <div :if={@visible?} class="space-y-6">
        <div class="flex flex-wrap items-center gap-3">
          <.link navigate={"/#{@username}"} class="flex items-center gap-3 text-base-content/70 hover:text-base-content">
            <.user_avatar user={@user} size="md" />
            <span class="font-semibold">{@user.username}</span>
          </.link>
          <h1 class="text-2xl font-bold sm:text-3xl">Watched</h1>
          <span :if={is_list(@history)} class="text-sm text-base-content/60">{length(@history)}</span>
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <div class="join">
            <.link
              :for={{s, label} <- [latest: "Latest", top: "By rating"]}
              patch={address(@username, sort: s, kind: @kind, tens: @tens?)}
              class={["btn btn-sm join-item", @sort == s && "btn-primary"]}
            >
              {label}
            </.link>
          </div>
          <div class="join">
            <.link
              :for={{k, label} <- Profile.kinds()}
              patch={address(@username, sort: @sort, kind: k, tens: @tens?)}
              class={["btn btn-sm join-item", @kind == k && "btn-primary"]}
            >
              {label}
            </.link>
          </div>
          <.link
            :if={@owner? or @profile.show_ratings}
            patch={address(@username, sort: :top, kind: @kind, tens: not @tens?)}
            class={["btn btn-sm", @tens? && "btn-primary"]}
          >
            ★ 10 only
          </.link>
        </div>

        <ul :if={@history == nil} class="grid grid-cols-3 gap-4 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-8" aria-busy="true">
          <li :for={_ <- 1..8} class="space-y-1">
            <div class="skeleton aspect-[2/3] w-full rounded-box"></div>
            <div class="skeleton h-4 w-3/4 rounded"></div>
          </li>
        </ul>

        <p :if={@history == []} class="text-sm text-base-content/50">
          {if @owner?, do: "Nothing finished yet. What you watch to the end shows up here.", else: "Nothing here yet."}
        </p>
        <p :if={@history != nil and @history != [] and @items == []} class="text-sm text-base-content/50">
          Nothing of that kind{if @tens?, do: " rated 10", else: ""}.
        </p>

        <ul :if={@items != []} class="grid grid-cols-3 gap-4 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-8">
          <li :for={i <- Enum.take(@items, @shown)} class="space-y-1">
            <.poster item={i} cached_titles={@cached_titles} compact />
            <div class="flex items-center justify-between text-xs text-base-content/50">
              <span>{day(i)}</span>
              <span :if={i.score != nil and (@owner? or @profile.show_ratings)} class="font-semibold text-warning">★ {Profile.score_text(i.score)}</span>
            </div>
          </li>
        </ul>

        <button :if={length(@items) > @shown} phx-click="more" class="btn btn-ghost btn-sm">
          Show {min(length(@items) - @shown, @page)} more
        </button>
      </div>
    </Layouts.app>
    """
  end
end
