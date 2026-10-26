defmodule RokiWeb.ProfileLive do
  @moduledoc """
  `/:username` — a user's public page: a banner and a few words of their own over what they
  have watched, newest first or by their own ratings (`?sort=top`, `?kind=anime`, `?tens=1`
  for the ten-out-of-tens), so a link to it says "this is what I watch and what I rate".

  Private until its owner opens it (the owner always sees it, with a note saying so), and the
  owner chooses whether the history and the ratings are on it. Everything is `Roki.Profile`'s;
  the owner edits in a panel on the page itself.
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
      {:ok, assign(socket, page_title: "Profile", user: nil, username: username, owner?: false, visible?: false, profile: nil)}
    else
      profile = Profile.get(user.uuid)
      owner? = viewer == user.uuid

      socket =
        socket
        |> assign(
          page_title: user.username,
          user: user,
          username: user.username,
          uuid: user.uuid,
          owner?: owner?,
          profile: profile,
          visible?: profile.public or owner?,
          editing?: false,
          error: nil,
          notice: nil,
          history: nil,
          ratings: %{},
          stats: nil,
          sort: :latest,
          kind: :all,
          tens?: false,
          shown: @page,
          page: @page
        )
        |> then(fn s ->
          if owner?,
            do: allow_upload(s, :banner, accept: ~w(.jpg .jpeg .png .webp), max_entries: 1, max_file_size: 12_000_000, auto_upload: true),
            else: s
        end)

      {:ok, if(connected?(socket) and socket.assigns.visible?, do: load(socket), else: socket)}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(sort: Profile.sort(params["sort"]), kind: Profile.kind(params["kind"]), tens?: params["tens"] == "1", shown: @page)
     |> fetch_posters()}
  end

  # Everything here is read from this server — the owner's files, the site's tables, the media
  # library — and nothing is asked of TMDB or MyAnimeList: the copies are kept current on a
  # clock (`Roki.Refresher`) and by what is done on the site.
  defp load(socket) do
    %{uuid: uuid, owner?: owner?, profile: profile} = socket.assigns

    socket = start_async(socket, :ratings, fn -> Profile.ratings(uuid) end)

    socket =
      if owner? or profile.show_history,
        do: start_async(socket, :history, fn -> Profile.history(uuid) end),
        else: assign(socket, :history, [])

    if Roki.Laev.connected?(uuid),
      do: start_async(socket, :stats, fn -> Roki.Stats.summary(uuid) end),
      else: socket
  end

  # Posters come with the history, from the title store; a title the store has no card for yet
  # shows without one until the refresher has been by.
  defp fetch_posters(socket), do: socket

  defp arranged(%{assigns: a}) when is_list(a.history),
    do: Profile.arrange(a.history, if(a.owner? or a.profile.show_ratings, do: a.ratings, else: %{}), a.kind, a.sort, a.tens?)

  defp arranged(_socket), do: []

  # ── events ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("more", _params, socket),
    do: {:noreply, socket |> update(:shown, &(&1 + @page)) |> fetch_posters()}

  def handle_event("edit", _params, %{assigns: %{owner?: true}} = socket),
    do: {:noreply, assign(socket, editing?: not socket.assigns.editing?, error: nil)}

  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, editing?: false, error: nil)}

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("save", %{"profile" => attrs}, %{assigns: %{owner?: true, uuid: uuid}} = socket) do
    with {:ok, profile} <- Profile.update(uuid, attrs),
         {:ok, profile} <- store_banner(socket, profile) do
      {:noreply,
       socket
       |> assign(profile: profile, visible?: true, editing?: false, error: nil, notice: "Saved.")
       |> then(&if(&1.assigns.history == nil, do: load(&1), else: &1))}
    else
      {:error, why} -> {:noreply, assign(socket, :error, why)}
    end
  end

  def handle_event("remove_banner", _params, %{assigns: %{owner?: true, uuid: uuid}} = socket) do
    Profile.clear_banner(uuid)
    {:noreply, assign(socket, :profile, Profile.get(uuid))}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # The picture uploaded with the form, if any, becomes the banner.
  defp store_banner(socket, profile) do
    results =
      consume_uploaded_entries(socket, :banner, fn %{path: path}, _entry ->
        {:ok, Profile.store_banner(socket.assigns.uuid, path)}
      end)

    case results do
      [] -> {:ok, profile}
      [{:ok, updated}] -> {:ok, updated}
      [{:error, why}] -> {:error, why}
    end
  end

  # ── async results ──────────────────────────────────────────────────

  @impl true
  def handle_async(:history, {:ok, items}, socket) when is_list(items),
    do: {:noreply, socket |> assign(:history, items) |> fetch_posters()}

  def handle_async(:history, _other, socket), do: {:noreply, assign(socket, :history, [])}

  def handle_async(:ratings, {:ok, ratings}, socket) when is_map(ratings), do: {:noreply, assign(socket, :ratings, ratings)}
  def handle_async(:ratings, _other, socket), do: {:noreply, socket}

  def handle_async(:stats, {:ok, {:ok, s}}, socket), do: {:noreply, assign(socket, :stats, s)}
  def handle_async(:stats, _other, socket), do: {:noreply, socket}

  # ── view ───────────────────────────────────────────────────────────

  defp address(username, view) do
    query =
      Enum.flat_map(view, fn
        {:sort, :top} -> [sort: "top"]
        {:kind, k} when k != :all -> [kind: Atom.to_string(k)]
        {:tens, true} -> [tens: "1"]
        _ -> []
      end)

    if query == [], do: "/#{username}", else: "/#{username}?" <> URI.encode_query(query)
  end

  @months ~w(January February March April May June July August September October November December)

  defp joined(%{inserted_at: %DateTime{} = at}), do: "#{Enum.at(@months, at.month - 1)} #{at.year}"
  defp joined(_), do: nil

  defp day(%{dated?: true, at: at}) do
    d = DateTime.from_unix!(at)
    "#{String.slice(Enum.at(@months, d.month - 1), 0, 3)} #{d.day}, #{d.year}"
  end

  defp day(_), do: nil

  @impl true
  def render(assigns) do
    assigns = assign(assigns, items: arranged(%{assigns: assigns}), banner: assigns.profile && Profile.banner_url(assigns.profile))

    ~H"""
    <Layouts.app
      flash={@flash}
      wide
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path={"/#{@username}"}
    >
      <p :if={@user == nil} class="py-24 text-center text-base-content/60">
        There is no one called <strong>{@username}</strong> here.
      </p>

      <div :if={@user != nil and not @visible?} class="space-y-2 py-24 text-center">
        <h1 class="text-2xl font-bold">{@username}</h1>
        <p class="text-base-content/60">This profile is private.</p>
      </div>

      <div :if={@visible?} class="space-y-8">
        <section class="overflow-hidden rounded-box bg-base-200">
          <div
            class={["h-40 w-full bg-cover bg-center sm:h-60", !@banner && "bg-gradient-to-r from-primary/40 via-base-300 to-secondary/40"]}
            style={@banner && "background-image: url('#{@banner}')"}
          >
          </div>
          <%!-- The avatar is PhoenixKit's biggest; on a phone it is drawn smaller so the name has room. --%>
          <div class="-mt-12 flex flex-wrap items-end gap-x-4 gap-y-3 px-4 pb-4 sm:-mt-16 sm:px-6">
            <div class="shrink-0 rounded-full ring-4 ring-base-200 [&_.avatar>div]:!h-24 [&_.avatar>div]:!w-24 sm:[&_.avatar>div]:!h-40 sm:[&_.avatar>div]:!w-40">
              <.user_avatar user={@user} size="xl" />
            </div>
            <div class="min-w-0 flex-1 pb-1">
              <h1 class="truncate text-2xl font-bold sm:text-3xl">{@user.username}</h1>
              <p :if={joined(@user)} class="text-sm text-base-content/60">On roki since {joined(@user)}</p>
            </div>
            <button :if={@owner?} type="button" phx-click="edit" class="btn btn-sm basis-full sm:basis-auto">
              <.icon name="hero-pencil-square" class="h-4 w-4" /> Edit profile
            </button>
          </div>
          <p :if={@profile.bio != ""} class="whitespace-pre-line px-4 pb-4 sm:px-6">{@profile.bio}</p>
          <p :if={match?(%{totals: _}, @stats)} class="flex flex-wrap gap-x-4 px-4 pb-4 text-sm text-base-content/60 sm:px-6">
            <span><b class="text-base-content">{@stats.totals.films}</b> films</span>
            <span><b class="text-base-content">{@stats.totals.episodes}</b> episodes</span>
            <span><b class="text-base-content">{Roki.Laev.duration(@stats.totals.seconds)}</b> watched</span>
          </p>
          <p :if={@owner? and not @profile.public} class="mx-4 mb-4 alert text-sm sm:mx-6">
            <.icon name="hero-lock-closed" class="h-4 w-4" />
            <span>Only you can see this page. Make it public under <b>Edit profile</b> to share it.</span>
          </p>
          <p :if={@notice} class="mx-4 mb-4 text-sm text-success sm:mx-6">{@notice}</p>
        </section>

        <.edit_panel :if={@owner? and @editing?} profile={@profile} uploads={@uploads} error={@error} banner={@banner} />

        <section :if={@owner? or @profile.show_history} class="space-y-4">
          <div class="flex flex-wrap items-center gap-2">
            <h2 class="mr-2 text-xl font-semibold">Watched</h2>
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

          <p :if={@history == [] } class="text-sm text-base-content/50">
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
        </section>

        <p :if={not @owner? and not @profile.show_history} class="text-sm text-base-content/50">
          {@username} keeps their watch history to themselves.
        </p>
      </div>
    </Layouts.app>
    """
  end

  attr :profile, :map, required: true
  attr :uploads, :any, required: true
  attr :error, :string, default: nil
  attr :banner, :string, default: nil

  # The owner's panel: the words, the banner, and what is shown to others.
  defp edit_panel(assigns) do
    ~H"""
    <form id="profile-form" phx-submit="save" phx-change="validate" class="card space-y-4 bg-base-200 p-5">
      <h2 class="text-lg font-semibold">Edit profile</h2>

      <label class="form-control w-full">
        <span class="label-text mb-1 font-medium">About you</span>
        <textarea name="profile[bio]" rows="3" maxlength="600" class="textarea textarea-bordered w-full" placeholder="A few words, a favourite quote, what you are into…">{@profile.bio}</textarea>
      </label>

      <div class="space-y-2">
        <span class="font-medium">Banner</span>
        <p class="text-sm text-base-content/60">
          A wide picture, 3:1 or so. It is resized to 1800 px across; anything up to 12 MB.
        </p>
        <div :if={@banner} class="flex items-center gap-3">
          <img src={@banner} alt="" class="h-16 w-48 rounded object-cover" />
          <button type="button" phx-click="remove_banner" class="btn btn-sm btn-ghost text-error">Remove</button>
        </div>
        <.live_file_input upload={@uploads.banner} class="file-input file-input-bordered file-input-sm w-full max-w-md" />
        <div :for={entry <- @uploads.banner.entries} class="text-sm">
          <span>{entry.client_name}</span>
          <progress class="progress progress-primary ml-2 inline-block w-40 align-middle" value={entry.progress} max="100"></progress>
          <p :for={err <- upload_errors(@uploads.banner, entry)} class="text-error">{upload_error(err)}</p>
        </div>
        <p :for={err <- upload_errors(@uploads.banner)} class="text-sm text-error">{upload_error(err)}</p>
      </div>

      <div class="space-y-2">
        <label :for={{key, label, hint} <- [
          {:public, "Public profile", "anyone with the link can see this page"},
          {:show_history, "Show what I watched", "the list below, newest first"},
          {:show_ratings, "Show my ratings", "the stars, and the by-rating order"}
        ]} class="flex cursor-pointer items-start gap-3">
          <input type="hidden" name={"profile[#{key}]"} value="false" />
          <input type="checkbox" name={"profile[#{key}]"} value="true" checked={Map.get(@profile, key)} class="checkbox mt-0.5" />
          <span class="text-sm"><span class="font-medium">{label}</span> <span class="text-base-content/60">— {hint}</span></span>
        </label>
      </div>

      <p :if={@error} class="alert alert-error text-sm">{@error}</p>

      <div class="flex gap-2">
        <button type="submit" class="btn btn-primary btn-sm">Save</button>
        <button type="button" phx-click="cancel" class="btn btn-ghost btn-sm">Cancel</button>
      </div>
    </form>
    """
  end

  defp upload_error(:too_large), do: "That file is too large (12 MB at most)."
  defp upload_error(:not_accepted), do: "A JPEG, PNG or WebP picture, please."
  defp upload_error(:too_many_files), do: "One picture at a time."
  defp upload_error(other), do: "Upload failed: #{inspect(other)}"
end
