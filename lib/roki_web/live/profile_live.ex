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

  import RokiWeb.PosterComponents
  import PhoenixKitWeb.Components.Core.UserInfo, only: [user_avatar: 1]

  alias PhoenixKit.Users.Auth.Scope
  alias Roki.Profile

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
          visible?: true,
          editing?: false,
          bio_editing?: false,
          error: nil,
          notice: nil,
          stats: nil,
          watched: nil,
          favorites: nil,
          shelf: nil,
          shelf_error: nil,
          candidates: [],
          query: ""
        )
        |> then(fn s ->
          if owner?,
            do: allow_upload(s, :banner, accept: ~w(.jpg .jpeg .png .webp), max_entries: 1, max_file_size: 12_000_000, auto_upload: true),
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
    |> start_async(:watched, fn -> length(Profile.history(uuid)) end)
    |> then(fn s -> if Roki.Laev.connected?(uuid), do: start_async(s, :stats, fn -> Roki.Stats.summary(uuid) end), else: s end)
  end

  # ── events: the profile ─────────────────────────────────────────────

  @impl true
  def handle_event("edit", _params, %{assigns: %{owner?: true}} = socket),
    do: {:noreply, assign(socket, editing?: not socket.assigns.editing?, error: nil)}

  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, editing?: false, error: nil)}

  # The words, written right where they go — only while there are none; once written, the
  # panel on the banner is where they change.
  def handle_event("bio_edit", _params, %{assigns: %{owner?: true, profile: %{bio: ""}}} = socket),
    do: {:noreply, assign(socket, bio_editing?: true, error: nil)}

  def handle_event("bio_cancel", _params, socket), do: {:noreply, assign(socket, bio_editing?: false)}

  def handle_event("bio_save", %{"bio" => bio}, %{assigns: %{owner?: true, uuid: uuid}} = socket) do
    case Profile.update(uuid, %{"bio" => bio}) do
      {:ok, profile} -> {:noreply, assign(socket, profile: profile, bio_editing?: false, error: nil)}
      {:error, why} -> {:noreply, assign(socket, :error, why)}
    end
  end

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("save", %{"profile" => attrs}, %{assigns: %{owner?: true, uuid: uuid}} = socket) do
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

  # Open a shelf for editing: what may go on it is the owner's watched titles of that kind.
  def handle_event("shelf_edit", %{"kind" => kind}, %{assigns: %{owner?: true}} = socket) do
    case Profile.shelf(kind) do
      nil ->
        {:noreply, socket}

      shelf ->
        if socket.assigns.shelf == shelf do
          {:noreply, assign(socket, shelf: nil, candidates: [], query: "", shelf_error: nil)}
        else
          uuid = socket.assigns.uuid

          {:noreply,
           socket
           |> assign(shelf: shelf, candidates: [], query: "", shelf_error: nil)
           |> start_async(:candidates, fn -> {shelf, Profile.candidates(uuid, shelf)} end)}
        end
    end
  end

  def handle_event("shelf_close", _params, socket),
    do: {:noreply, assign(socket, shelf: nil, candidates: [], query: "", shelf_error: nil)}

  def handle_event("shelf_search", %{"q" => q}, socket), do: {:noreply, assign(socket, :query, String.trim(q))}

  def handle_event("shelf_add", %{"type" => type, "id" => id, "title" => title}, %{assigns: %{owner?: true, shelf: shelf}} = socket)
      when shelf != nil do
    with {n, ""} <- Integer.parse(to_string(id)),
         {:ok, favorites} <- Profile.add_favorite(socket.assigns.uuid, shelf, {type, n}, title) do
      {:noreply, socket |> assign(favorites: favorites, shelf_error: nil) |> mark_candidates()}
    else
      {:error, why} -> {:noreply, assign(socket, :shelf_error, why)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("shelf_remove", %{"type" => type, "id" => id}, %{assigns: %{owner?: true}} = socket) do
    with {n, ""} <- Integer.parse(to_string(id)),
         {:ok, favorites} <- Profile.remove_favorite(socket.assigns.uuid, {type, n}) do
      {:noreply, socket |> assign(favorites: favorites, shelf_error: nil) |> mark_candidates()}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("shelf_move", %{"type" => type, "id" => id, "dir" => dir}, %{assigns: %{owner?: true}} = socket)
      when dir in ["up", "down"] do
    with {n, ""} <- Integer.parse(to_string(id)),
         {:ok, favorites} <- Profile.move_favorite(socket.assigns.uuid, {type, n}, String.to_existing_atom(dir)) do
      {:noreply, assign(socket, favorites: favorites)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Which candidates are on a shelf already, after a change.
  defp mark_candidates(%{assigns: %{candidates: cands, favorites: favs}} = socket) when is_map(favs) do
    taken = for {_, items} <- favs, i <- items, into: MapSet.new(), do: Profile.favorite_key(i)
    assign(socket, :candidates, Enum.map(cands, &Map.put(&1, :on_shelf, MapSet.member?(taken, Profile.favorite_key(&1)))))
  end

  defp mark_candidates(socket), do: socket

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
  def handle_async(:favorites, {:ok, favorites}, socket) when is_map(favorites), do: {:noreply, assign(socket, :favorites, favorites)}
  def handle_async(:favorites, _other, socket), do: {:noreply, assign(socket, :favorites, %{})}
  def handle_async(:watched, {:ok, n}, socket) when is_integer(n), do: {:noreply, assign(socket, :watched, n)}
  def handle_async(:watched, _other, socket), do: {:noreply, socket}
  def handle_async(:stats, {:ok, {:ok, s}}, socket), do: {:noreply, assign(socket, :stats, s)}
  def handle_async(:stats, _other, socket), do: {:noreply, socket}

  def handle_async(:candidates, {:ok, {shelf, list}}, %{assigns: %{shelf: shelf}} = socket),
    do: {:noreply, assign(socket, :candidates, list)}

  def handle_async(:candidates, _other, socket), do: {:noreply, socket}

  # ── view ───────────────────────────────────────────────────────────

  @months ~w(January February March April May June July August September October November December)

  defp joined(%{inserted_at: %DateTime{} = at}), do: "#{Enum.at(@months, at.month - 1)} #{at.year}"
  defp joined(_), do: nil

  # One of the numbers, with thousands separated; a dash while they are not known.
  defp stat(%{totals: t}, :films), do: thousands(t.films)
  defp stat(%{totals: t}, :episodes), do: thousands(t.episodes)
  defp stat(%{totals: t}, :hours), do: thousands(div(t.seconds || 0, 3600))
  defp stat(_stats, _), do: "…"

  defp thousands(n) when is_integer(n),
    do: n |> Integer.to_string() |> String.reverse() |> String.replace(~r/(\d{3})(?=\d)/, "\\1,") |> String.reverse()

  defp thousands(n), do: to_string(n)

  # The candidates that match what was typed, newest first, at most forty.
  defp matching(candidates, "") , do: Enum.take(candidates, 40)

  defp matching(candidates, query) do
    q = String.downcase(query)
    candidates |> Enum.filter(&String.contains?(String.downcase(&1.title || ""), q)) |> Enum.take(40)
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, banner: assigns.profile && Profile.banner_url(assigns.profile))

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

      <div :if={@visible?} class="space-y-10">
        <section class="overflow-hidden rounded-box bg-base-200">
          <div
            class={["relative h-40 w-full bg-cover bg-center sm:h-60", !@banner && "bg-gradient-to-r from-primary/40 via-base-300 to-secondary/40"]}
            style={@banner && "background-image: url('#{@banner}')"}
          >
            <button :if={@owner?} type="button" phx-click="edit" class="btn btn-sm absolute right-3 top-3 shadow">
              <.icon name="hero-pencil-square" class="h-4 w-4" /> Edit profile
            </button>
          </div>
          <%!-- The avatar is PhoenixKit's biggest, and overlaps the banner. On a phone it is drawn
                smaller and the name goes under it, clear of the banner, rather than beside it. --%>
          <div class="-mt-12 flex flex-col gap-y-2 px-4 pb-4 sm:-mt-16 sm:flex-row sm:flex-wrap sm:items-end sm:gap-x-4 sm:gap-y-3 sm:px-6">
            <div class="w-24 shrink-0 rounded-full ring-4 ring-base-200 sm:w-40 [&_.avatar>div]:!h-24 [&_.avatar>div]:!w-24 sm:[&_.avatar>div]:!h-40 sm:[&_.avatar>div]:!w-40">
              <.user_avatar user={@user} size="xl" />
            </div>
            <div class="min-w-0 flex-1 pt-1 sm:pb-1 sm:pt-0">
              <h1 class="truncate text-2xl font-bold sm:text-3xl">{@user.username}</h1>
              <p :if={joined(@user)} class="text-sm text-base-content/60">On roki since {joined(@user)}</p>
            </div>
          </div>
          <p :if={@profile.bio != ""} class="whitespace-pre-line px-4 pb-4 sm:px-6">{@profile.bio}</p>
          <%!-- Nothing written yet: a place held for it; the owner presses it and writes there. --%>
          <p :if={@profile.bio == "" and @owner? and not @bio_editing?} class="px-4 pb-4 sm:px-6">
            <button type="button" phx-click="bio_edit" class="text-left italic text-base-content/50 hover:text-base-content">
              Say something about yourself — a few words, a favourite quote, what you are into. Press here to write it.
            </button>
          </p>
          <form :if={@bio_editing?} phx-submit="bio_save" class="flex flex-wrap items-center gap-2 px-4 pb-4 sm:px-6">
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
          <p :if={@profile.bio == "" and not @owner?} class="px-4 pb-4 italic text-base-content/40 sm:px-6">
            {@username} hasn't written anything here yet.
          </p>
          <p :if={@error != nil and not @editing?} class="px-4 pb-4 text-sm text-error sm:px-6">{@error}</p>

          <%!-- The numbers, as the thing they are: big, with a word under each. --%>
          <div class="grid grid-cols-2 gap-px overflow-hidden border-t border-base-300 bg-base-300 sm:grid-cols-4">
            <.link
              navigate={"/#{@username}/watched"}
              class="group bg-base-200 px-4 py-4 transition hover:bg-base-100 sm:px-6"
            >
              <div class="text-3xl font-bold tabular-nums tracking-tight sm:text-4xl">{if @watched, do: thousands(@watched), else: "…"}</div>
              <div class="text-xs font-medium uppercase tracking-wide text-base-content/60 group-hover:text-primary">Watched →</div>
            </.link>
            <div class="bg-base-200 px-4 py-4 sm:px-6">
              <div class="text-3xl font-bold tabular-nums tracking-tight sm:text-4xl">{stat(@stats, :films)}</div>
              <div class="text-xs font-medium uppercase tracking-wide text-base-content/60">Films</div>
            </div>
            <div class="bg-base-200 px-4 py-4 sm:px-6">
              <div class="text-3xl font-bold tabular-nums tracking-tight sm:text-4xl">{stat(@stats, :episodes)}</div>
              <div class="text-xs font-medium uppercase tracking-wide text-base-content/60">Episodes</div>
            </div>
            <div class="bg-base-200 px-4 py-4 sm:px-6">
              <div class="text-3xl font-bold tabular-nums tracking-tight sm:text-4xl">{stat(@stats, :hours)}</div>
              <div class="text-xs font-medium uppercase tracking-wide text-base-content/60">Hours watched</div>
            </div>
          </div>
          <p :if={@notice} class="mx-4 my-4 text-sm text-success sm:mx-6">{@notice}</p>
        </section>

        <.edit_panel :if={@owner? and @editing?} profile={@profile} uploads={@uploads} error={@error} banner={@banner} user={@user} />

        <%!-- The shelves: a visitor sees the ones with something on them. --%>
        <section :for={{kind, label} <- Profile.shelves()} :if={@favorites == nil or @owner? or (@favorites[kind] || []) != []} class="space-y-3">
          <div class="flex flex-wrap items-center gap-2">
            <h2 class="text-xl font-semibold">Top {Profile.top()} {label}</h2>
            <span :if={@favorites} class="text-sm text-base-content/60">{length(@favorites[kind] || [])}</span>
            <button :if={@owner? and kind != :manga} type="button" phx-click="shelf_edit" phx-value-kind={kind} class={["btn btn-xs ml-auto", @shelf == kind && "btn-primary"]}>
              <.icon name="hero-pencil-square" class="h-3.5 w-3.5" /> {if @shelf == kind, do: "Done", else: "Edit"}
            </button>
          </div>

          <ul :if={@favorites == nil} class="grid grid-cols-5 gap-2 sm:gap-3 lg:grid-cols-10" aria-busy="true">
            <li :for={_ <- 1..5} class="skeleton aspect-[2/3] rounded-box"></li>
          </ul>

          <p :if={@favorites != nil and (@favorites[kind] || []) == [] and kind == :manga} class="text-sm text-base-content/50">
            Manga is coming to roki; the shelf is waiting for it.
          </p>
          <p :if={@favorites != nil and (@favorites[kind] || []) == [] and kind != :manga} class="text-sm text-base-content/50">
            {if @owner?, do: "Nothing on this shelf yet. Press Edit and pick from what you watched.", else: "Nothing here yet."}
          </p>

          <ul :if={(@favorites[kind] || []) != []} class="grid grid-cols-5 gap-2 sm:gap-3 lg:grid-cols-10">
            <li :for={i <- @favorites[kind]} class="space-y-1">
              <.poster item={i} cached_titles={@cached_titles} compact />
              <div :if={@owner? and @shelf == kind} class="flex justify-center gap-1">
                <button type="button" phx-click="shelf_move" phx-value-type={i.type || "mal"} phx-value-id={i.id || i.mal_id} phx-value-dir="up" class="btn btn-xs btn-square" aria-label="Move up" disabled={i.position == 1}>←</button>
                <button type="button" phx-click="shelf_remove" phx-value-type={i.type || "mal"} phx-value-id={i.id || i.mal_id} class="btn btn-xs btn-square text-error" aria-label="Take off the shelf">×</button>
                <button type="button" phx-click="shelf_move" phx-value-type={i.type || "mal"} phx-value-id={i.id || i.mal_id} phx-value-dir="down" class="btn btn-xs btn-square" aria-label="Move down" disabled={i.position == length(@favorites[kind])}>→</button>
              </div>
            </li>
          </ul>

          <.shelf_picker :if={@owner? and @shelf == kind} kind={kind} label={label} candidates={matching(@candidates, @query)} query={@query} error={@shelf_error} count={length(@favorites[kind] || [])} cached_titles={@cached_titles} />
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :kind, :atom, required: true
  attr :label, :string, required: true
  attr :candidates, :list, required: true
  attr :query, :string, default: ""
  attr :error, :string, default: nil
  attr :count, :integer, default: 0
  attr :cached_titles, :any, default: nil

  # What may go on the shelf: the owner's watched titles of that kind, a search box to find one.
  defp shelf_picker(assigns) do
    ~H"""
    <div class="space-y-3 rounded-box border border-base-300 bg-base-200 p-4">
      <div class="flex flex-wrap items-center gap-3">
        <h3 class="font-semibold">Pick from what you watched</h3>
        <span class="text-sm text-base-content/60">{@count} of {Profile.top()} places taken · use ← × → under a poster to order it</span>
        <form phx-change="shelf_search" phx-submit="shelf_search" class="ml-auto">
          <input type="text" name="q" value={@query} placeholder={"Search your #{String.downcase(@label)}…"} autocomplete="off" phx-debounce="200" class="input input-bordered input-sm w-56" />
        </form>
      </div>
      <p :if={@error} class="text-sm text-error">{@error}</p>
      <p :if={@candidates == [] and @query == ""} class="text-sm text-base-content/50">Nothing watched of this kind yet.</p>
      <p :if={@candidates == [] and @query != ""} class="text-sm text-base-content/50">Nothing watched matches "{@query}".</p>
      <ul :if={@candidates != []} class="grid grid-cols-4 gap-2 sm:grid-cols-6 md:grid-cols-8 lg:grid-cols-10">
        <li :for={c <- @candidates} class="space-y-1">
          <.poster item={c} cached_titles={@cached_titles} compact />
          <button
            type="button"
            phx-click="shelf_add"
            phx-value-type={c.type || "mal"}
            phx-value-id={c.id || c.mal_id}
            phx-value-title={c.title}
            disabled={c.on_shelf}
            class={["btn btn-xs w-full", c.on_shelf && "btn-ghost"]}
          >
            {if c.on_shelf, do: "On a shelf", else: "Add"}
          </button>
        </li>
      </ul>
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
    <form id="profile-form" phx-submit="save" phx-change="validate" class="card space-y-4 bg-base-200 p-5">
      <h2 class="text-lg font-semibold">Edit profile</h2>

      <div class="flex flex-wrap items-center gap-4">
        <.user_avatar user={@user} size="lg" />
        <div class="space-y-1">
          <span class="font-medium">Profile picture</span>
          <p class="text-sm text-base-content/60">Changed on your account page, which also has your name and password.</p>
        </div>
        <a href={PhoenixKit.Utils.Routes.user_settings_path()} class="btn btn-sm sm:ml-auto">Change picture</a>
      </div>

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
