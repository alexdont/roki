defmodule RokiWeb.ProfileLive do
  @moduledoc """
  `/:username` — a user's page: a banner and a few words of their own, and under them their
  top ten of each kind — films, shows, anime, manga — picked from what they watched, the way
  one shows a shelf. Everything they finished is a page of its own (`/:username/watched`).

  Open to everyone: the site is a handful of people who know each other. Everything is
  `Roki.Profile`'s and read from this server; the owner edits on the page itself — the words
  right where they go when there are none yet, the rest (picture, banner, words) from the
  button on the banner.
  """
  use RokiWeb, :live_view
  use PhoenixKitComments.Embed

  import PhoenixKitWeb.Components.Core.UserInfo, only: [user_avatar: 1]

  alias PhoenixKit.Users.Auth.Scope
  alias Roki.Profile

  @impl true
  def mount(%{"username" => username}, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    viewer = if scope && Scope.authenticated?(scope), do: Scope.user_uuid(scope)
    viewer_user = if viewer, do: Scope.user(scope)
    user = Profile.user(username)

    if user == nil do
      {:ok,
       assign(socket,
         page_title: "Profile",
         user: nil,
         username: username,
         owner?: false,
         visible?: false,
         profile: nil
       )}
    else
      profile = Profile.get(user.uuid)
      owner? = viewer == user.uuid

      socket =
        socket
        |> assign(
          page_title: user.username,
          og: Roki.OpenGraph.for_profile(user.username, profile),
          user: user,
          username: user.username,
          uuid: user.uuid,
          owner?: owner?,
          profile: profile,
          viewer: viewer_user,
          friends_on?: Roki.Social.friends_on?(),
          relation: Roki.Social.relationship(viewer, user.uuid),
          friend_count: Roki.Social.friend_count(user.uuid),
          pending_count: if(owner?, do: Roki.Social.pending_count(user.uuid), else: 0),
          visible?: true,
          editing?: false,
          bio_editing?: false,
          error: nil,
          notice: nil,
          stats: nil,
          watched: nil,
          rating_counts: nil,
          rating_kind: "all",
          films: nil,
          favorites: nil,
          shelf: nil,
          shelf_error: nil,
          picking: nil,
          pick_list: nil,
          picks: MapSet.new(),
          pick_shown: 60,
          query: ""
        )
        |> then(fn s ->
          if owner?,
            do:
              allow_upload(s, :banner,
                accept: ~w(.jpg .jpeg .png .webp),
                max_entries: 1,
                max_file_size: 12_000_000,
                auto_upload: true
              ),
            else: s
        end)

      {:ok, if(connected?(socket) and socket.assigns.visible?, do: load(socket), else: socket)}
    end
  end

  # Everything here is read from this server — the owner's files, the site's tables, the media
  # library — and nothing is asked of TMDB or MyAnimeList.
  defp load(socket) do
    uuid = socket.assigns.uuid

    socket
    |> start_async(:favorites, fn -> Profile.favorites(uuid) end)
    |> start_async(:watched, fn -> Profile.counts(uuid) end)
    |> start_async(:ratings, fn -> Profile.rating_counts(uuid) end)
    |> then(fn s ->
      if Roki.Laev.connected?(uuid),
        do: start_async(s, :stats, fn -> Profile.hours(uuid) end),
        else: s
    end)
  end

  # ── events: the profile ─────────────────────────────────────────────

  @impl true
  def handle_event("edit", _params, %{assigns: %{owner?: true}} = socket),
    do: {:noreply, assign(socket, editing?: not socket.assigns.editing?, error: nil)}

  def handle_event("cancel", _params, socket),
    do: {:noreply, assign(socket, editing?: false, error: nil)}

  # The words, written right where they go — only while there are none; once written, the
  # panel on the banner is where they change.
  def handle_event(
        "bio_edit",
        _params,
        %{assigns: %{owner?: true, profile: %{bio: ""}}} = socket
      ),
      do: {:noreply, assign(socket, bio_editing?: true, error: nil)}

  def handle_event("bio_cancel", _params, socket),
    do: {:noreply, assign(socket, bio_editing?: false)}

  def handle_event("bio_save", %{"bio" => bio}, %{assigns: %{owner?: true, uuid: uuid}} = socket) do
    case Profile.update(uuid, %{"bio" => bio}) do
      {:ok, profile} ->
        {:noreply, assign(socket, profile: profile, bio_editing?: false, error: nil)}

      {:error, why} ->
        {:noreply, assign(socket, :error, why)}
    end
  end

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("rating_kind", %{"kind" => kind}, socket) when kind in ~w(all movie tv mal),
    do: {:noreply, assign(socket, :rating_kind, kind)}

  # Friends: the buttons beside the name. Whatever the answer, the page then shows how the two
  # stand now (a request may have been taken back or answered meanwhile).
  def handle_event(
        "friend_" <> action,
        _params,
        %{assigns: %{viewer: %{uuid: me}, owner?: false, uuid: them}} = socket
      )
      when action in ~w(add cancel accept decline remove) do
    _ =
      case action do
        "add" -> Roki.Social.request(me, them)
        "cancel" -> Roki.Social.cancel(me, them)
        "accept" -> Roki.Social.accept(me, them)
        "decline" -> Roki.Social.decline(me, them)
        "remove" -> Roki.Social.remove(me, them)
      end

    {:noreply,
     assign(socket,
       relation: Roki.Social.relationship(me, them),
       friend_count: Roki.Social.friend_count(them)
     )}
  end

  def handle_event(
        "save",
        %{"profile" => attrs},
        %{assigns: %{owner?: true, uuid: uuid}} = socket
      ) do
    with {:ok, profile} <- Profile.update(uuid, attrs),
         {:ok, profile} <- store_banner(socket, profile) do
      {:noreply,
       socket
       |> assign(profile: profile, visible?: true, editing?: false, error: nil, notice: "Saved.")
       |> then(&if(&1.assigns.favorites == nil, do: load(&1), else: &1))}
    else
      {:error, why} -> {:noreply, assign(socket, :error, why)}
    end
  end

  def handle_event("remove_banner", _params, %{assigns: %{owner?: true, uuid: uuid}} = socket) do
    Profile.clear_banner(uuid)
    {:noreply, assign(socket, :profile, Profile.get(uuid))}
  end

  # ── events: the shelves ─────────────────────────────────────────────

  # Edit a shelf: its titles get a cross in a corner and a grip to drag by, and its empty
  # places open the picker.
  def handle_event("shelf_edit", %{"kind" => kind}, %{assigns: %{owner?: true}} = socket) do
    case Profile.shelf(kind) do
      nil ->
        {:noreply, socket}

      shelf ->
        {:noreply,
         assign(socket,
           shelf: if(socket.assigns.shelf == shelf, do: nil, else: shelf),
           picking: nil,
           shelf_error: nil
         )}
    end
  end

  # Numbers on a shelf, or just ten favourites with none above another.
  def handle_event(
        "shelf_ranked",
        %{"kind" => kind},
        %{assigns: %{owner?: true, uuid: uuid, profile: profile}} = socket
      ) do
    case Profile.shelf(kind) do
      shelf when shelf in [:movie, :tv, :anime, :manga] ->
        {:ok, profile} = Profile.set_ranked(uuid, shelf, not Profile.ranked?(profile, shelf))
        {:noreply, assign(socket, :profile, profile)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("shelf_remove", %{"key" => key}, %{assigns: %{owner?: true}} = socket) do
    with {type, n} <- Profile.parse_key(key),
         {:ok, favorites} <- Profile.remove_favorite(socket.assigns.uuid, {type, n}) do
      {:noreply, assign(socket, favorites: favorites, shelf_error: nil)}
    else
      _ -> {:noreply, socket}
    end
  end

  # A drag ended: the shelf is kept in the order it was left in.
  def handle_event(
        "shelf_reorder",
        %{"ordered_ids" => ids, "kind" => kind} = params,
        %{assigns: %{owner?: true}} = socket
      )
      when is_list(ids) do
    with shelf when shelf in [:movie, :tv, :anime, :manga] <- Profile.shelf(kind) do
      {status, favorites} = Profile.reorder_favorites(socket.assigns.uuid, shelf, ids)

      {:noreply,
       socket
       |> assign(favorites: favorites)
       |> push_event("sortable:flash", %{
         uuid: params["moved_id"],
         status: if(status == :ok, do: "ok", else: "error")
       })}
    else
      _ -> {:noreply, socket}
    end
  end

  # The picker: this shelf's own kind of title from what was watched, best rated first.
  def handle_event(
        "pick_open",
        %{"kind" => kind},
        %{assigns: %{owner?: true, favorites: favs}} = socket
      )
      when is_map(favs) do
    case Profile.shelf(kind) do
      shelf when shelf in [:movie, :tv, :anime, :manga] ->
        uuid = socket.assigns.uuid

        {:noreply,
         socket
         |> assign(
           picking: shelf,
           pick_list: nil,
           picks: on_shelf_keys(favs, shelf),
           pick_shown: 60,
           query: "",
           shelf_error: nil
         )
         |> start_async(:pick_list, fn -> {shelf, Profile.picker(uuid, shelf, favs)} end)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("pick_close", _params, socket),
    do:
      {:noreply,
       assign(socket,
         picking: nil,
         pick_list: nil,
         picks: MapSet.new(),
         query: "",
         shelf_error: nil
       )}

  def handle_event("pick_search", %{"q" => q}, socket),
    do: {:noreply, assign(socket, query: String.trim(q), pick_shown: 60)}

  def handle_event("pick_more", _params, socket),
    do: {:noreply, update(socket, :pick_shown, &(&1 + 60))}

  # Tick or untick one. What is on the shelf starts ticked: unticking it takes it off when the
  # picker is saved, and the place it frees can be ticked for something else. No more than
  # the shelf holds can be ticked at once.
  def handle_event(
        "pick_toggle",
        %{"key" => key},
        %{assigns: %{owner?: true, picking: kind}} = socket
      )
      when kind != nil do
    picks = socket.assigns.picks

    cond do
      MapSet.member?(picks, key) ->
        {:noreply, assign(socket, picks: MapSet.delete(picks, key), shelf_error: nil)}

      MapSet.size(picks) >= Profile.top() ->
        {:noreply,
         assign(
           socket,
           :shelf_error,
           "The shelf holds #{Profile.top()}. Untick one to make room."
         )}

      true ->
        {:noreply, assign(socket, picks: MapSet.put(picks, key), shelf_error: nil)}
    end
  end

  # The best rated that fit, in one press: what is ticked stays, the rest of the places are
  # filled from the top of the list.
  def handle_event(
        "pick_best",
        _params,
        %{assigns: %{owner?: true, picking: kind, pick_list: list, picks: picks}} = socket
      )
      when kind != nil and is_list(list) do
    room = Profile.top() - MapSet.size(picks)

    keys =
      list
      |> Enum.reject(&MapSet.member?(picks, &1.key))
      |> Enum.take(max(room, 0))
      |> Enum.map(& &1.key)

    {:noreply,
     assign(socket, picks: Enum.reduce(keys, picks, &MapSet.put(&2, &1)), shelf_error: nil)}
  end

  # Save the picker: what was unticked comes off the shelf, what was newly ticked goes on, in
  # the order the list shows them, the best rated first.
  def handle_event(
        "pick_add",
        _params,
        %{assigns: %{owner?: true, picking: kind, pick_list: list, picks: picks, uuid: uuid}} =
          socket
      )
      when kind != nil and is_list(list) do
    removals = for i <- list, i.on_shelf, not MapSet.member?(picks, i.key), do: i.key
    adds = for i <- list, not i.on_shelf, MapSet.member?(picks, i.key), do: i.key

    Enum.each(removals, fn key ->
      with {type, n} <- Profile.parse_key(key), do: Profile.remove_favorite(uuid, {type, n})
    end)

    result =
      if adds == [],
        do: {:ok, Profile.favorites(uuid), 0},
        else: Profile.add_favorites(uuid, kind, adds)

    case result do
      {:ok, favorites, _n} ->
        {:noreply,
         assign(socket,
           favorites: favorites,
           picking: nil,
           pick_list: nil,
           picks: MapSet.new(),
           query: "",
           shelf_error: nil
         )}

      {:error, why} ->
        {:noreply, assign(socket, favorites: Profile.favorites(uuid), shelf_error: why)}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # The keys ("movie:603", "mal:5114") of what is on a shelf, as the picker names them.
  # Which shelves a page shows. A visitor sees the ones with something on them. Manga also
  # needs a signed-in viewer: the covers that are not in the media library are fetched from the
  # sources by this site, which only does that for someone signed in.
  defp show_shelf?(:manga, owner?, viewer, favorites),
    do: viewer != nil and (favorites == nil or owner? or (favorites[:manga] || []) != [])

  defp show_shelf?(kind, owner?, _viewer, favorites),
    do: favorites == nil or owner? or (favorites[kind] || []) != []

  defp on_shelf_keys(favorites, kind) do
    for i <- (favorites || %{})[kind] || [], into: MapSet.new() do
      {type, id} = Profile.favorite_key(i)
      "#{type}:#{id}"
    end
  end

  defp places_left(favorites, kind), do: Profile.top() - length((favorites || %{})[kind] || [])

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
  def handle_async(:favorites, {:ok, favorites}, socket) when is_map(favorites),
    do: {:noreply, assign(socket, :favorites, favorites)}

  def handle_async(:favorites, _other, socket), do: {:noreply, assign(socket, :favorites, %{})}

  def handle_async(:watched, {:ok, %{watched: n, films: f}}, socket),
    do: {:noreply, assign(socket, watched: n, films: f)}

  def handle_async(:watched, _other, socket), do: {:noreply, socket}

  def handle_async(:ratings, {:ok, counts}, socket) when is_map(counts),
    do: {:noreply, assign(socket, :rating_counts, counts)}

  def handle_async(:ratings, _other, socket), do: {:noreply, socket}
  def handle_async(:stats, {:ok, {:ok, s}}, socket), do: {:noreply, assign(socket, :stats, s)}
  def handle_async(:stats, _other, socket), do: {:noreply, socket}

  def handle_async(:pick_list, {:ok, {kind, list}}, %{assigns: %{picking: kind}} = socket),
    do: {:noreply, assign(socket, :pick_list, list)}

  def handle_async(:pick_list, _other, socket), do: {:noreply, socket}

  # ── view ───────────────────────────────────────────────────────────

  @months ~w(January February March April May June July August September October November December)

  defp joined(%{inserted_at: %DateTime{} = at}),
    do: "#{Enum.at(@months, at.month - 1)} #{at.year}"

  defp joined(_), do: nil

  # A shelf is "Favorite Movies" — none above another — until its owner turns the numbers on,
  # and then it is "Top 10 Movies".
  defp shelf_title(profile, kind, label) do
    if Profile.ranked?(profile, kind),
      do: "Top #{Profile.top()} #{label}",
      else: "Favorite #{label}"
  end

  # One of the numbers, with thousands separated; a dash while they are not known.
  defp stat(%{episodes: n}, :episodes), do: thousands(n)
  defp stat(%{hours: n}, :hours), do: thousands(n)
  defp stat(_stats, _), do: "…"

  defp thousands(n) when is_integer(n),
    do:
      n
      |> Integer.to_string()
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()

  defp thousands(n), do: to_string(n)

  # The picker's titles that match what was typed, still best rated first.
  defp matching(list, ""), do: list

  defp matching(list, query) do
    q = String.downcase(query)
    Enum.filter(list, &String.contains?(String.downcase(&1.title || ""), q))
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, banner: assigns.profile && Profile.banner_url(assigns.profile))

    ~H"""
    <Layouts.app
      socket={@socket}
      flash={@flash}
      flush
      bleed
      overlay
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path={"/u/#{@username}/profile"}
    >
      <p :if={@user == nil} class="px-4 pb-24 pt-40 text-center text-base-content/60">
        There is no one called <strong>{@username}</strong> here.
      </p>

      <div :if={@visible?}>
        <%!-- The top: the banner across the window under the floating header, the person on it. --%>
        <section class="relative z-20 flex min-h-[clamp(22rem,52svh,34rem)] flex-col justify-end text-white [--color-base-content:#fff]">
          <div class="absolute inset-0 -z-10 overflow-hidden bg-neutral-900">
            <div
              class={[
                "h-full w-full bg-cover bg-center",
                !@banner && "bg-gradient-to-r from-primary/60 via-neutral-800 to-secondary/60"
              ]}
              style={@banner && "background-image: url('#{@banner}')"}
            >
            </div>
            <div class="absolute inset-0 bg-gradient-to-r from-black/70 via-black/30 to-black/10">
            </div>
            <div class="absolute inset-0 bg-gradient-to-t from-black/80 via-transparent to-black/50">
            </div>
          </div>

          <div class="flex flex-col gap-4 px-4 pb-5 pt-24 sm:gap-5 sm:px-6 sm:pb-6 sm:pt-28 lg:px-12 xl:px-16">
            <div class="flex flex-wrap items-end gap-x-5 gap-y-3">
              <%!-- The avatar is PhoenixKit's biggest; on a phone it is drawn smaller. --%>
              <div class="w-24 shrink-0 rounded-full ring-4 ring-white/25 sm:w-36 [&_.avatar>div]:!h-24 [&_.avatar>div]:!w-24 sm:[&_.avatar>div]:!h-36 sm:[&_.avatar>div]:!w-36">
                <.user_avatar user={@user} size="xl" />
              </div>
              <div class="min-w-0 flex-1 pb-1">
                <h1 class="truncate text-4xl font-bold tracking-tight drop-shadow-lg sm:text-5xl xl:text-6xl">
                  {@user.username}
                </h1>
                <p :if={joined(@user)} class="text-sm text-white/70">
                  On roki since {joined(@user)}
                </p>
              </div>
              <div class="flex w-full flex-wrap items-center gap-2 pb-1 sm:w-auto">
                <.friend_bar
                  :if={@friends_on?}
                  username={@username}
                  owner?={@owner?}
                  signed_in?={@viewer != nil}
                  relation={@relation}
                  count={@friend_count}
                  pending={@pending_count}
                />
                <button
                  :if={@owner?}
                  type="button"
                  phx-click="edit"
                  class="btn btn-sm gap-1.5 rounded-full border border-white/25 bg-black/30 text-white backdrop-blur-md hover:border-white/60 hover:bg-black/45"
                >
                  <.icon name="hero-pencil-square" class="h-4 w-4" /> Edit profile
                </button>
              </div>
            </div>

            <p :if={@profile.bio != ""} class="max-w-3xl whitespace-pre-line text-white/90">
              {@profile.bio}
            </p>
            <%!-- Nothing written yet: a place held for it; the owner presses it and writes there. --%>
            <p :if={@profile.bio == "" and @owner? and not @bio_editing?}>
              <button
                type="button"
                phx-click="bio_edit"
                class="text-left italic text-white/60 hover:text-white"
              >
                Say something about yourself — a few words, a favourite quote, what you are into. Press here to write it.
              </button>
            </p>
            <p
              :if={@profile.bio == "" and not @owner?}
              class="italic text-white/50"
            >
              {@username} hasn't written anything here yet.
            </p>

            <%!-- The numbers, as the thing they are: big, with a word under each. --%>
            <div class="grid grid-cols-4 gap-2 sm:flex sm:flex-wrap sm:gap-x-10 sm:gap-y-3">
              <.link navigate={"/u/#{@username}/watched"} class="group">
                <div class="text-2xl font-bold tabular-nums tracking-tight sm:text-4xl">
                  {if @watched, do: thousands(@watched), else: "…"}
                </div>
                <div class="text-[0.65rem] font-medium uppercase tracking-wide text-white/60 sm:text-xs group-hover:text-white">
                  Watched →
                </div>
              </.link>
              <div>
                <div class="text-2xl font-bold tabular-nums tracking-tight sm:text-4xl">
                  {if @films, do: thousands(@films), else: "…"}
                </div>
                <div class="text-[0.65rem] font-medium uppercase tracking-wide text-white/60 sm:text-xs">
                  Films
                </div>
              </div>
              <div>
                <div class="text-2xl font-bold tabular-nums tracking-tight sm:text-4xl">
                  {stat(@stats, :episodes)}
                </div>
                <div class="text-[0.65rem] font-medium uppercase tracking-wide text-white/60 sm:text-xs">
                  Episodes
                </div>
              </div>
              <div>
                <div class="text-2xl font-bold tabular-nums tracking-tight sm:text-4xl">
                  {stat(@stats, :hours)}
                </div>
                <div class="text-[0.65rem] font-medium uppercase tracking-wide text-white/60 sm:text-xs">
                  Hours<span class="hidden sm:inline"> watched</span>
                </div>
              </div>
            </div>
            <%!-- On a wide screen it sits on the banner's right, level with the numbers; below that
                  it follows them. --%>
            <.rating_breakdown :if={@rating_counts} counts={@rating_counts} kind={@rating_kind} />
          </div>
        </section>

        <div
          id="profile-cards"
          phx-hook="GridCards"
          class="space-y-10 px-4 pb-12 pt-8 [overflow-x:clip] sm:px-6 lg:px-12 xl:px-16"
        >
          <form
            :if={@bio_editing?}
            id="bio-form"
            phx-submit="bio_save"
            class="flex flex-wrap items-center gap-2"
          >
            <input
              type="text"
              name="bio"
              maxlength="600"
              autofocus
              autocomplete="off"
              placeholder="A few words, a favourite quote, what you are into…"
              class="input input-bordered min-w-0 flex-1"
              phx-key="Escape"
              phx-keydown="bio_cancel"
            />
            <button type="submit" class="btn btn-primary">Done</button>
            <button type="button" phx-click="bio_cancel" class="btn btn-ghost">Cancel</button>
          </form>
          <p :if={@error != nil and not @editing?} class="text-sm text-error">{@error}</p>
          <p :if={@notice} class="text-sm text-success">{@notice}</p>

          <.edit_panel
            :if={@owner? and @editing?}
            profile={@profile}
            uploads={@uploads}
            error={@error}
            banner={@banner}
            user={@user}
          />

          <%!-- The shelves. A visitor sees the ones with something on them. --%>
          <section
            :for={{kind, label} <- Profile.shelves()}
            :if={show_shelf?(kind, @owner?, @viewer, @favorites)}
            class="space-y-3"
          >
            <div class="flex flex-wrap items-center gap-2">
              <h2 class="text-2xl font-semibold tracking-tight">
                {shelf_title(@profile, kind, label)}
              </h2>
              <button
                :if={@owner? and @favorites != nil}
                type="button"
                phx-click="shelf_edit"
                phx-value-kind={kind}
                class={["btn btn-xs ml-auto", @shelf == kind && "btn-primary"]}
              >
                <.icon
                  name={if @shelf == kind, do: "hero-check", else: "hero-pencil-square"}
                  class="h-3.5 w-3.5"
                />
                {if @shelf == kind, do: "Done", else: "Edit"}
              </button>
            </div>

            <ul
              :if={@favorites == nil}
              class="grid grid-cols-5 gap-2 sm:gap-3 lg:grid-cols-10"
              aria-busy="true"
            >
              <li :for={_ <- 1..5} class="skeleton aspect-[2/3] rounded-box"></li>
            </ul>

            <%!-- Looking: the posters as they are, each a link to its page. --%>
            <ul
              :if={@shelf != kind and (@favorites[kind] || []) != []}
              class="grid grid-cols-5 gap-2 sm:gap-3 lg:grid-cols-10"
            >
              <RokiWeb.FeaturedLive.tile
                :for={i <- @favorites[kind]}
                item={if Profile.ranked?(@profile, kind), do: i, else: Map.put(i, :badge, nil)}
                kind={kind}
                keep_colour?
              />
            </ul>
            <p
              :if={@shelf != kind and @favorites != nil and (@favorites[kind] || []) == []}
              class="text-sm text-base-content/50"
            >
              {if @owner?,
                do: "Nothing on this shelf yet. Press Edit to add what you loved.",
                else: "Nothing here yet."}
            </p>

            <%!-- Editing: a cross in a corner takes one off, the grip along the bottom drags it to
                a new place, and the empty places open the picker. --%>
            <div :if={@owner? and @shelf == kind and @favorites != nil} class="space-y-2">
              <div class="flex flex-wrap items-center gap-x-4 gap-y-2">
                <label class="flex cursor-pointer items-center gap-2 text-sm font-medium">
                  <input
                    type="checkbox"
                    class="toggle toggle-primary toggle-sm"
                    checked={Profile.ranked?(@profile, kind)}
                    phx-click="shelf_ranked"
                    phx-value-kind={kind}
                  /> Rank them 1 to {Profile.top()}
                </label>
                <button
                  type="button"
                  phx-click="pick_open"
                  phx-value-kind={kind}
                  class="btn btn-sm btn-outline btn-primary rounded-full"
                >
                  <.icon name="hero-squares-plus" class="h-4 w-4" />
                  {if kind == :manga, do: "Choose from read", else: "Choose from watched"}
                </button>
                <p class="text-sm text-base-content/60">
                  {if Profile.ranked?(@profile, kind),
                    do: "The numbers show: the order matters. Drag a poster to reorder.",
                    else:
                      "Just your favourites, none above another. Drag to arrange them as you like."} × takes one off; an empty place adds more.
                </p>
              </div>
              <ul
                id={"shelf-#{kind}"}
                phx-hook="SortableGrid"
                data-sortable-event="shelf_reorder"
                data-sortable-scope-kind={kind}
                class="grid grid-cols-5 gap-2 sm:gap-3 lg:grid-cols-10"
              >
                <li
                  :for={i <- @favorites[kind]}
                  id={"fav-#{kind}-#{i.type || "mal"}-#{i.id || i.mal_id}"}
                  data-id={"#{i.type || "mal"}:#{i.id || i.mal_id}"}
                  class="sortable-item cursor-grab touch-none select-none space-y-1 active:cursor-grabbing"
                >
                  <div class="relative aspect-[2/3] overflow-hidden rounded-box bg-base-300 shadow">
                    <img
                      :if={i.poster}
                      src={Roki.Images.local(i.poster)}
                      alt={i.title}
                      class="h-full w-full object-cover"
                      draggable="false"
                    />
                    <span
                      :if={!i.poster}
                      class="flex h-full items-center justify-center p-2 text-center text-xs"
                    >{i.title}</span>
                    <span
                      :if={Profile.ranked?(@profile, kind)}
                      class="badge badge-primary badge-xs absolute bottom-1 right-1 shadow sm:badge-sm sm:bottom-auto sm:right-1.5 sm:top-1.5"
                    >#{i.position}</span>
                    <button
                      type="button"
                      phx-click="shelf_remove"
                      phx-value-key={"#{i.type || "mal"}:#{i.id || i.mal_id}"}
                      class="btn btn-circle btn-error absolute left-0.5 top-0.5 h-6 min-h-0 w-6 p-0 shadow sm:left-1.5 sm:top-1.5"
                      aria-label={"Take #{i.title} off the shelf"}
                    >
                      <.icon name="hero-x-mark-micro" class="h-3.5 w-3.5" />
                    </button>
                  </div>
                </li>
                <%!-- Not "sortable-ignore": that filter makes SortableJS cancel the touch, and the
                    tap never becomes a click on a phone. Only .sortable-item is draggable anyway. --%>
                <li :for={_ <- 1..places_left(@favorites, kind)//1}>
                  <button
                    type="button"
                    phx-click="pick_open"
                    phx-value-kind={kind}
                    class="flex aspect-[2/3] w-full flex-col items-center justify-center gap-1 rounded-box border-2 border-dashed border-primary/50 text-primary transition hover:border-primary hover:bg-primary/10"
                  >
                    <.icon name="hero-plus" class="h-5 w-5 sm:h-6 sm:w-6" />
                    <span class="hidden text-xs font-medium sm:block">Add</span>
                  </button>
                </li>
              </ul>
            </div>
          </section>

          <%!-- Whatever anyone wants to say to them: comments, a thread of replies. Plain text, so it
              needs no editor script. --%>
          <section class="space-y-3" aria-label="Comments">
            <.live_component
              module={PhoenixKitComments.Web.CommentsComponent}
              id="profile-comments"
              resource_type="profile"
              resource_uuid={@uuid}
              current_user={@viewer}
              rich_text={false}
            />
          </section>
        </div>
      </div>

      <.picker
        :if={@owner? and @picking}
        kind={@picking}
        label={Keyword.get(Profile.shelves(), @picking)}
        list={@pick_list}
        picks={@picks}
        query={@query}
        shown={@pick_shown}
        error={@shelf_error}
        left={places_left(@favorites, @picking)}
      />
    </Layouts.app>
    """
  end

  attr :counts, :map, required: true
  attr :kind, :string, required: true

  # How the account rates: a column per score, as tall as the number of titles given it, in the
  # score's own colour, with the average and the total. Films, shows and anime on their own or
  # together. Nothing at all when there is nothing rated.
  defp rating_breakdown(assigns) do
    kinds = if assigns.kind == "all", do: nil, else: [assigns.kind]
    breakdown = Profile.rating_breakdown(assigns.counts, kinds)

    present =
      for {k, label} <- [{"movie", "Films"}, {"tv", "Shows"}, {"mal", "Anime"}],
          Map.has_key?(assigns.counts, k),
          do: {k, label}

    assigns =
      assign(assigns,
        b: breakdown,
        tabs: [{"all", "All"} | present],
        max: breakdown && breakdown.bars |> Enum.map(&elem(&1, 1)) |> Enum.max()
      )

    ~H"""
    <section
      :if={@counts != %{}}
      class="w-full space-y-2 rounded-box border border-white/15 bg-black/35 p-3 backdrop-blur-md sm:space-y-3 sm:p-4 lg:absolute lg:bottom-6 lg:right-12 lg:w-[26rem] xl:right-16"
      aria-label="Ratings"
    >
      <div class="flex flex-wrap items-end justify-between gap-2">
        <div>
          <h2 class="text-sm font-semibold uppercase tracking-wide text-white/70">Ratings</h2>
          <p :if={@b} class="text-sm text-white/70">
            <span class="text-2xl font-bold tabular-nums text-white">
              {Roki.Profile.score_text(@b.average)}
            </span>
            average · {@b.total} rated
          </p>
        </div>
        <div
          :if={length(@tabs) > 2}
          role="tablist"
          class="tabs tabs-box tabs-xs bg-white/10 [--color-base-content:#fff] [&_.tab-active]:!text-neutral-900"
        >
          <button
            :for={{k, label} <- @tabs}
            type="button"
            role="tab"
            phx-click="rating_kind"
            phx-value-kind={k}
            class={["tab", @kind == k && "tab-active"]}
          >
            {label}
          </button>
        </div>
      </div>

      <div :if={@b}>
        <ol class="flex h-20 items-end gap-0.5 sm:h-28 sm:gap-1">
          <li
            :for={{score, n} <- @b.bars}
            class="group relative flex h-full min-w-0 flex-1 flex-col justify-end"
            title={"#{Roki.Profile.score_text(score)}: #{n} #{if n == 1, do: "title", else: "titles"}"}
          >
            <span class="mb-0.5 text-center text-[0.6rem] tabular-nums text-white/70">
              {if n > 0, do: n}
            </span>
            <span
              class="block w-full rounded-t-sm"
              style={"height: #{if n == 0, do: "2px", else: "#{max(n / @max * 100, 3)}%"}; background: #{RokiWeb.ScoreColor.color(score)}; opacity: #{if n == 0, do: "0.25", else: "1"}"}
            ></span>
          </li>
        </ol>
        <ol class="mt-1 flex gap-0.5 sm:gap-1">
          <li
            :for={{score, _n} <- @b.bars}
            class="min-w-0 flex-1 text-center text-[0.6rem] tabular-nums text-white/55"
          >
            {if score == Float.round(score), do: trunc(score)}
          </li>
        </ol>
      </div>
    </section>
    """
  end

  attr :username, :string, required: true
  attr :owner?, :boolean, required: true
  attr :signed_in?, :boolean, required: true

  attr :relation, :any,
    required: true,
    doc: "how the viewer stands with them; nil for oneself or a visitor"

  attr :count, :integer, required: true
  attr :pending, :integer, required: true

  # Beside the name: how many friends, and what the viewer can do about it — ask, take the request
  # back, answer it, or end the friendship. On their own page, the requests waiting for them.
  defp friend_bar(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2 sm:pb-1">
      <.link navigate={"/u/#{@username}/friends"} class="btn btn-sm btn-ghost -ml-2 gap-1.5 sm:ml-0">
        <.icon name="hero-users" class="h-4 w-4" />
        {@count} {if @count == 1, do: "friend", else: "friends"}
        <span :if={@owner? and @pending > 0} class="badge badge-primary badge-sm">{@pending} new</span>
      </.link>

      <%= if @signed_in? and not @owner? and @relation != nil and not @relation.blocked_by and not @relation.blocked do %>
        <%= cond do %>
          <% @relation.connected -> %>
            <button
              type="button"
              phx-click="friend_remove"
              data-confirm={"Remove #{@username} from your friends?"}
              class="btn btn-sm btn-outline gap-1.5"
            >
              <.icon name="hero-check" class="h-4 w-4" /> Friends
            </button>
          <% @relation.connection_pending == :sent -> %>
            <button type="button" phx-click="friend_cancel" class="btn btn-sm btn-outline gap-1.5">
              <.icon name="hero-clock" class="h-4 w-4" /> Request sent · cancel
            </button>
          <% @relation.connection_pending == :received -> %>
            <button type="button" phx-click="friend_accept" class="btn btn-sm btn-primary gap-1.5">
              <.icon name="hero-check" class="h-4 w-4" /> Accept
            </button>
            <button type="button" phx-click="friend_decline" class="btn btn-sm btn-ghost">Decline</button>
          <% true -> %>
            <button type="button" phx-click="friend_add" class="btn btn-sm btn-primary gap-1.5">
              <.icon name="hero-user-plus" class="h-4 w-4" /> Add friend
            </button>
        <% end %>
      <% end %>
    </div>
    """
  end

  attr :kind, :atom, required: true
  attr :label, :string, required: true
  attr :list, :any, required: true, doc: "nil while loading"
  attr :picks, :any, required: true
  attr :query, :string, default: ""
  attr :shown, :integer, default: 60
  attr :error, :string, default: nil
  attr :left, :integer, required: true

  # The picker: a view of its own over the page — the user's watched titles of the shelf's kind,
  # best rated first, to tick as many as fit and add in one go.
  defp picker(assigns) do
    matches = if is_list(assigns.list), do: matching(assigns.list, assigns.query), else: []

    on =
      if is_list(assigns.list),
        do: for(c <- assigns.list, c.on_shelf, into: MapSet.new(), do: c.key),
        else: MapSet.new()

    added =
      if is_list(assigns.list),
        do:
          Enum.count(assigns.list, &(not &1.on_shelf and MapSet.member?(assigns.picks, &1.key))),
        else: 0

    removed = Enum.count(on, &(not MapSet.member?(assigns.picks, &1)))

    assigns =
      assign(assigns,
        matches: matches,
        selected: MapSet.size(assigns.picks),
        verb: if(assigns.kind == :manga, do: "read", else: "watched"),
        added: added,
        removed: removed
      )

    ~H"""
    <div
      class="fixed inset-0 z-50 flex items-end justify-center sm:items-center"
      role="dialog"
      aria-modal="true"
      aria-label={"Choose your favorite #{String.downcase(@label)}"}
      phx-window-keydown="pick_close"
      phx-key="Escape"
    >
      <div class="absolute inset-0 bg-black/60" phx-click="pick_close"></div>
      <div class="relative flex max-h-[94vh] w-full max-w-6xl flex-col overflow-hidden rounded-t-box bg-base-100 shadow-2xl sm:max-h-[90vh] sm:rounded-box">
        <div class="space-y-3 border-b border-base-300 p-4">
          <div class="flex items-start gap-3">
            <div class="min-w-0 flex-1">
              <h2 class="text-lg font-semibold sm:text-xl">
                Choose your favorite {String.downcase(@label)}
              </h2>
              <p class="text-sm text-base-content/60">
                Your {@verb} {String.downcase(@label)}, best rated first. What is on the shelf is ticked: untick it to take it off, tick others to put them on.
              </p>
            </div>
            <button
              type="button"
              phx-click="pick_close"
              class="btn btn-sm btn-circle btn-ghost"
              aria-label="Close"
            >
              <.icon name="hero-x-mark" class="h-5 w-5" />
            </button>
          </div>
          <div class="flex flex-wrap items-center gap-2">
            <form
              id="pick-search"
              phx-change="pick_search"
              phx-submit="pick_search"
              class="min-w-0 flex-1 sm:max-w-xs"
            >
              <input
                type="text"
                name="q"
                value={@query}
                placeholder={"Search your #{String.downcase(@label)}…"}
                autocomplete="off"
                phx-debounce="200"
                class="input input-bordered input-sm w-full"
              />
            </form>
            <button type="button" phx-click="pick_best" class="btn btn-sm">
              <.icon name="hero-star" class="h-4 w-4" /> Fill with my best
            </button>
            <span :if={is_list(@list)} class="text-sm text-base-content/60">{length(@matches)} to choose from</span>
          </div>
        </div>

        <div class="min-h-0 flex-1 overflow-y-auto p-4">
          <ul
            :if={@list == nil}
            class="grid grid-cols-3 gap-3 sm:grid-cols-5 md:grid-cols-5 lg:grid-cols-6 xl:grid-cols-7 2xl:grid-cols-8"
            aria-busy="true"
          >
            <li :for={_ <- 1..16} class="skeleton aspect-[2/3] rounded-box"></li>
          </ul>
          <p :if={@list == []} class="py-10 text-center text-base-content/60">
            Nothing {@verb} of this kind yet. What you finish shows up here.
          </p>
          <p
            :if={is_list(@list) and @list != [] and @matches == []}
            class="py-10 text-center text-base-content/60"
          >
            Nothing {@verb} matches "{@query}".
          </p>

          <ul
            :if={@matches != []}
            class="grid grid-cols-3 gap-3 sm:grid-cols-5 md:grid-cols-5 lg:grid-cols-6 xl:grid-cols-7 2xl:grid-cols-8"
          >
            <li :for={c <- Enum.take(@matches, @shown)}>
              <button
                type="button"
                phx-click="pick_toggle"
                phx-value-key={c.key}
                aria-pressed={to_string(MapSet.member?(@picks, c.key))}
                class={[
                  "group relative block w-full overflow-hidden rounded-box bg-base-300 text-left shadow transition",
                  "aspect-[2/3] focus-visible:outline focus-visible:outline-2 focus-visible:outline-primary",
                  MapSet.member?(@picks, c.key) && "ring-4 ring-primary",
                  c.on_shelf && !MapSet.member?(@picks, c.key) && "opacity-50 grayscale",
                  !MapSet.member?(@picks, c.key) && "hover:scale-[1.02]"
                ]}
              >
                <img
                  :if={c.poster}
                  src={Roki.Images.local(c.poster)}
                  alt=""
                  loading="lazy"
                  class="h-full w-full object-cover"
                  draggable="false"
                />
                <span class="absolute inset-x-0 bottom-0 bg-gradient-to-t from-black/85 to-transparent px-2 pb-1.5 pt-6 text-xs font-medium leading-tight text-white">
                  <span class="line-clamp-2">{c.title}</span>
                </span>
                <span
                  :if={c.score != nil}
                  class="badge badge-warning badge-sm absolute left-1.5 top-1.5 shadow"
                >★ {Profile.score_text(c.score)}</span>
                <span
                  :if={MapSet.member?(@picks, c.key)}
                  class="absolute right-1.5 top-1.5 flex h-6 w-6 items-center justify-center rounded-full bg-primary text-primary-content shadow"
                >
                  <.icon name="hero-check-micro" class="h-4 w-4" />
                </span>
                <span
                  :if={c.on_shelf and MapSet.member?(@picks, c.key)}
                  class="absolute bottom-9 left-1.5 rounded-full bg-primary px-2 py-0.5 text-[0.65rem] font-semibold text-primary-content shadow"
                >On shelf</span>
                <span
                  :if={c.on_shelf and !MapSet.member?(@picks, c.key)}
                  class="absolute inset-0 flex items-center justify-center bg-black/50 text-xs font-semibold text-white"
                >Coming off</span>
              </button>
            </li>
          </ul>
          <div :if={length(@matches) > @shown} class="flex justify-center pt-4">
            <button type="button" phx-click="pick_more" class="btn btn-ghost btn-sm">Show {min(
              length(@matches) - @shown,
              60
            )} more</button>
          </div>
        </div>

        <div class="flex flex-wrap items-center gap-3 border-t border-base-300 bg-base-100 px-4 pb-[max(0.75rem,env(safe-area-inset-bottom))] pt-3">
          <p id="pick-count" class="min-w-0 flex-1 text-sm">
            <b>{@selected}</b>
            of {Profile.top()} on the shelf <span :if={@error} class="ml-2 text-error">{@error}</span>
          </p>
          <button type="button" phx-click="pick_close" class="btn btn-ghost">Cancel</button>
          <button
            type="button"
            phx-click="pick_add"
            class="btn btn-primary"
            disabled={@added == 0 and @removed == 0}
          >
            {cond do
              @added > 0 and @removed > 0 -> "Save changes"
              @removed > 0 -> "Take #{@removed} off"
              @added > 0 -> "Add #{@added} to the shelf"
              true -> "Save"
            end}
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :profile, :map, required: true
  attr :uploads, :any, required: true
  attr :error, :string, default: nil
  attr :banner, :string, default: nil
  attr :user, :map, required: true

  # The owner's panel: the picture (PhoenixKit's own page changes it), the banner, the words.
  defp edit_panel(assigns) do
    ~H"""
    <form
      id="profile-form"
      phx-submit="save"
      phx-change="validate"
      class="card space-y-4 bg-base-200 p-5"
    >
      <h2 class="text-lg font-semibold">Edit profile</h2>

      <div class="flex flex-wrap items-center gap-4">
        <.user_avatar user={@user} size="lg" />
        <div class="space-y-1">
          <span class="font-medium">Profile picture</span>
          <p class="text-sm text-base-content/60">
            Changed on your account page, which also has your name and password.
          </p>
        </div>
        <a href={PhoenixKit.Utils.Routes.user_settings_path()} class="btn btn-sm sm:ml-auto">Change picture</a>
      </div>

      <label class="form-control w-full">
        <span class="label-text mb-1 font-medium">About you</span>
        <textarea
          name="profile[bio]"
          rows="3"
          maxlength="600"
          class="textarea textarea-bordered w-full"
          placeholder="A few words, a favourite quote, what you are into…"
        >{@profile.bio}</textarea>
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
        <.live_file_input
          upload={@uploads.banner}
          class="file-input file-input-bordered file-input-sm w-full max-w-md"
        />
        <div :for={entry <- @uploads.banner.entries} class="text-sm">
          <span>{entry.client_name}</span>
          <progress
            class="progress progress-primary ml-2 inline-block w-40 align-middle"
            value={entry.progress}
            max="100"
          ></progress>
          <p :for={err <- upload_errors(@uploads.banner, entry)} class="text-error">
            {upload_error(err)}
          </p>
        </div>
        <p :for={err <- upload_errors(@uploads.banner)} class="text-sm text-error">
          {upload_error(err)}
        </p>
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
