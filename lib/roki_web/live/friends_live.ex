defmodule RokiWeb.FriendsLive do
  @moduledoc """
  `/:username/friends` — who someone's friends are. Open to everyone, like the rest of a profile.
  On your own page the requests waiting for your answer come first, and the ones you sent last,
  with the buttons to answer, take back, or end a friendship (`Roki.Social`).
  """
  use RokiWeb, :live_view

  import PhoenixKitWeb.Components.Core.UserInfo, only: [user_avatar: 1]

  alias PhoenixKit.Users.Auth.Scope
  alias Roki.{Profile, Social}

  @impl true
  def mount(%{"username" => username}, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    viewer = if scope && Scope.authenticated?(scope), do: Scope.user_uuid(scope)
    user = Profile.user(username)

    socket =
      assign(socket,
        page_title: if(user, do: "#{user.username} · friends", else: "Friends"),
        username: username,
        user: user,
        owner?: user != nil and viewer == user.uuid
      )

    {:ok, load(socket)}
  end

  defp load(%{assigns: %{user: nil}} = socket), do: assign(socket, friends: [], incoming: [], outgoing: [])

  defp load(%{assigns: %{user: %{uuid: uuid}, owner?: owner?}} = socket) do
    assign(socket,
      friends: Social.friends(uuid),
      incoming: if(owner?, do: Social.requests_in(uuid), else: []),
      outgoing: if(owner?, do: Social.requests_out(uuid), else: [])
    )
  end

  @impl true
  def handle_event(action, %{"uuid" => other}, %{assigns: %{owner?: true, user: %{uuid: me}}} = socket)
      when action in ~w(accept decline cancel remove) do
    _ =
      case action do
        "accept" -> Social.accept(me, other)
        "decline" -> Social.decline(me, other)
        "cancel" -> Social.cancel(me, other)
        "remove" -> Social.remove(me, other)
      end

    {:noreply, load(socket)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path={"/#{@username}/friends"}
    >
      <p :if={@user == nil} class="py-24 text-center text-base-content/60">
        There is no one called <strong>{@username}</strong> here.
      </p>

      <div :if={@user} class="space-y-8">
        <div class="flex items-center gap-3">
          <.link navigate={"/#{@user.username}"} class="flex items-center gap-2 text-base-content/70 hover:text-base-content">
            <.user_avatar user={@user} size="md" />
            <span class="font-semibold">{@user.username}</span>
          </.link>
          <h1 class="text-2xl font-bold sm:text-3xl">Friends</h1>
          <span class="rounded-full bg-base-200 px-2 py-0.5 text-xs font-medium tabular-nums text-base-content/60">{length(@friends)}</span>
        </div>

        <section :if={@owner? and @incoming != []} class="space-y-3">
          <h2 class="text-lg font-semibold">Asking to be your friend</h2>
          <ul class="divide-y divide-base-300 overflow-hidden rounded-box border border-base-300">
            <li :for={u <- @incoming} class="flex items-center gap-3 p-3">
              <.person user={u} />
              <button phx-click="accept" phx-value-uuid={u.uuid} class="btn btn-sm btn-primary">Accept</button>
              <button phx-click="decline" phx-value-uuid={u.uuid} class="btn btn-sm btn-ghost">Decline</button>
            </li>
          </ul>
        </section>

        <section class="space-y-3">
          <p :if={@friends == []} class="text-sm text-base-content/50">
            {if @owner?, do: "No friends yet. Open someone's profile and press Add friend.", else: "No friends yet."}
          </p>
          <ul :if={@friends != []} class="divide-y divide-base-300 overflow-hidden rounded-box border border-base-300">
            <li :for={u <- @friends} class="flex items-center gap-3 p-3">
              <.person user={u} />
              <button
                :if={@owner?}
                phx-click="remove"
                phx-value-uuid={u.uuid}
                data-confirm={"Remove #{u.username} from your friends?"}
                class="btn btn-sm btn-ghost text-error"
              >
                Remove
              </button>
            </li>
          </ul>
        </section>

        <section :if={@owner? and @outgoing != []} class="space-y-3">
          <h2 class="text-lg font-semibold">Waiting for an answer</h2>
          <ul class="divide-y divide-base-300 overflow-hidden rounded-box border border-base-300">
            <li :for={u <- @outgoing} class="flex items-center gap-3 p-3">
              <.person user={u} />
              <button phx-click="cancel" phx-value-uuid={u.uuid} class="btn btn-sm btn-ghost">Cancel</button>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :user, :map, required: true

  defp person(assigns) do
    ~H"""
    <.link navigate={"/#{@user.username}"} class="flex min-w-0 flex-1 items-center gap-3 hover:text-primary">
      <.user_avatar user={@user} size="md" />
      <span class="truncate font-medium">{@user.username}</span>
    </.link>
    """
  end
end
