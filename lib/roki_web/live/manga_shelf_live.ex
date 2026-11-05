defmodule RokiWeb.MangaShelfLive do
  @moduledoc """
  The saved manga (`/manga`): the account's shelf of what it reads. A banner to carry on with
  the title last read, chips to narrow the shelf, a sort menu, and the covers.

  Replaced the dead view `MangaController.home2/2` and its thousand-line inline script; the
  rules it kept in JavaScript (what each chip keeps, how each sort orders) are
  `Roki.Manga.Shelf` now.

  State lives in the address (`?mode=`, `?exclude_mode=`, `?category=`, `?exclude=`,
  `?sort=`, `?filter=`, `?status=`), so Back, a reload and a shared link all land on the same
  view. A bare `/manga` opens on the view the account was last on: kept with the account
  (`custom_fields["manga_view"]`), so the first paint is already that view, with nothing
  jumping once the socket connects. Before the account has one, the browser's own memory
  under the old page's keys (`manga_sort`, `manga_chip_state`, …, sent as the `manga` connect
  param by `storedMangaPrefs` in app.js) stands in; it is still written back (`manga:prefs`).
  Covers per row are per device class, as before.
  """
  use RokiWeb, :live_view

  alias Roki.Manga.{Library, Shelf}
  alias RokiWeb.MangaHTML

  @cols_range 2..7

  @impl true
  def mount(_params, _session, socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %{user: %{uuid: _} = user} -> mounted(socket, user)
      _ -> {:ok, redirect(socket, to: "/phoenix_kit/users/log-in")}
    end
  end

  defp mounted(socket, user) do
    categories = Library.list_categories(user.uuid)
    items = load_items(user.uuid)

    if items == [] and categories == [] do
      # Nothing saved and nothing to file it under: the place to find something is Explore.
      {:ok, redirect(socket, to: "/manga/explore")}
    else
      prefs = (connected?(socket) && get_connect_params(socket)["manga"]) || %{}
      custom = user.custom_fields || %{}

      {:ok,
       socket
       |> assign(
         page_title: "Manga",
         current_path: "/manga",
         user: user,
         categories: categories,
         category_counts: Library.count_manga_per_category(user.uuid),
         items: items,
         prefs: prefs,
         saved_view: saved_view(custom["manga_view"]),
         restored?: false,
         builtins: builtin_chips(prefs["chips"]),
         cols_m: cols(prefs["cols_m"], 2),
         cols_d: cols(prefs["cols_d"], 5),
         members: %{},
         bulk: nil,
         syncing?: false,
         auto_resume: custom["auto_resume"] == true,
         auto_resume_timer: custom["auto_resume_timer"] || 5,
         auto_resume_art: auto_resume_art(custom["auto_resume_art"])
       )
       |> assign_counts()}
    end
  end

  # ── the address ─────────────────────────────────────────────────────

  @impl true
  def handle_params(params, _uri, socket) do
    chip = parse_chip(params, socket.assigns.categories)
    sort = pick(params["sort"], &Shelf.sort?/1, "updated_at")
    filter = pick(params["filter"], &Shelf.filter?/1, "all")
    status = pick(params["status"], &Shelf.status?/1, "any")

    cond do
      # A bare /manga: the view the account was last on, once. Drawn at once (the first,
      # disconnected paint included), and the address then catches up to name it.
      not socket.assigns.restored? and bare?(params) ->
        {c, so, f, st} = remembered(socket.assigns)
        socket = socket |> assign(:restored?, connected?(socket)) |> show(c, so, f, st)

        if connected?(socket) and address(c, so, f, st) != "/manga",
          do: {:noreply, push_patch(socket, to: address(c, so, f, st), replace: true)},
          else: {:noreply, socket}

      true ->
        {:noreply, socket |> assign(:restored?, true) |> show(chip, sort, filter, status)}
    end
  end

  defp bare?(params),
    do: not Enum.any?(~w(mode exclude_mode category exclude sort filter status), &params[&1])

  defp show(socket, chip, sort, filter, status) do
    socket =
      socket
      |> assign(chip: chip, sort: sort, filter: filter, status: status)
      |> ensure_members(chip)
      |> assign_visible()

    if connected?(socket) do
      socket
      |> save_view(%{
        "chip" => Map.new(chip_json(chip), fn {k, v} -> {to_string(k), v} end),
        "sort" => sort,
        "filter" => filter,
        "status" => status
      })
      |> push_event("manga:prefs", %{
        sort: sort,
        filter: filter,
        status: status,
        chip: chip_json(chip)
      })
    else
      socket
    end
  end

  # The account's last view, written only when it changed. One key merged in place, so a
  # setting saved meanwhile elsewhere (auto-resume, from another tab) is not overwritten.
  defp save_view(%{assigns: %{saved_view: view}} = socket, view), do: socket

  defp save_view(socket, view) do
    PhoenixKit.Users.Auth.merge_user_custom_fields(
      socket.assigns.user,
      %{"manga_view" => view},
      ensure_definitions: false,
      broadcast: false
    )

    assign(socket, :saved_view, view)
  end

  defp assign_visible(%{assigns: a} = socket) do
    members = members_for(a.chip, a.members)
    assign(socket, :visible, Shelf.visible(a.items, a.chip, a.filter, a.status, a.sort, members))
  end

  defp members_for({kind, id}, members) when kind in [:category, :exclude],
    do: Map.get(members, id, MapSet.new())

  defp members_for(_, _), do: MapSet.new()

  defp ensure_members(socket, {kind, id}) when kind in [:category, :exclude] do
    if Map.has_key?(socket.assigns.members, id),
      do: socket,
      else: load_members(socket, id)
  end

  defp ensure_members(socket, _), do: socket

  defp load_members(socket, id) do
    keys =
      id
      |> Library.list_category_manga_keys(socket.assigns.user.uuid)
      |> MapSet.new(&"#{&1.source}:#{&1.slug}")

    update(socket, :members, &Map.put(&1, id, keys))
  end

  defp parse_chip(params, categories) do
    ids = MapSet.new(categories, & &1.id)

    cond do
      Shelf.mode?(params["mode"]) -> {:mode, params["mode"]}
      Shelf.mode?(params["exclude_mode"]) -> {:exclude_mode, params["exclude_mode"]}
      (id = int(params["category"])) && MapSet.member?(ids, id) -> {:category, id}
      (id = int(params["exclude"])) && MapSet.member?(ids, id) -> {:exclude, id}
      true -> nil
    end
  end

  defp saved_view(%{} = view), do: view
  defp saved_view(_), do: nil

  # The view to open a bare /manga on, as {chip, sort, filter, status}: the account's own,
  # else what this browser kept from the old page.
  defp remembered(%{saved_view: %{} = view, categories: categories}),
    do: remembered(view, categories)

  defp remembered(%{prefs: prefs, categories: categories}), do: remembered(prefs, categories)

  defp remembered(prefs, categories) do
    chip =
      case prefs["chip"] do
        %{"mode" => m} -> parse_chip(%{"mode" => m}, categories)
        %{"exclude_mode" => m} -> parse_chip(%{"exclude_mode" => m}, categories)
        %{"category" => id} -> parse_chip(%{"category" => to_string(id)}, categories)
        %{"exclude_category" => id} -> parse_chip(%{"exclude" => to_string(id)}, categories)
        _ -> nil
      end

    {chip, pick(prefs["sort"], &Shelf.sort?/1, "updated_at"),
     pick(prefs["filter"], &Shelf.filter?/1, "all"),
     pick(prefs["status"], &Shelf.status?/1, "any")}
  end

  defp chip_json(nil), do: %{}
  defp chip_json({:mode, m}), do: %{mode: m}
  defp chip_json({:exclude_mode, m}), do: %{exclude_mode: m}
  defp chip_json({:category, id}), do: %{category: id}
  defp chip_json({:exclude, id}), do: %{exclude_category: id}

  @doc false
  def address(chip, sort, filter, status) do
    query =
      chip_query(chip) ++
        Enum.reject(
          [{"sort", sort}, {"filter", filter}, {"status", status}],
          fn {_, v} -> v in ["updated_at", "all", "any", nil] end
        )

    case query do
      [] -> "/manga"
      q -> "/manga?" <> URI.encode_query(q)
    end
  end

  defp chip_query(nil), do: []
  defp chip_query({:mode, m}), do: [{"mode", m}]
  defp chip_query({:exclude_mode, m}), do: [{"exclude_mode", m}]
  defp chip_query({:category, id}), do: [{"category", id}]
  defp chip_query({:exclude, id}), do: [{"exclude", id}]

  # The address after a change, from the current one.
  defp to(a, changes) do
    c = Map.new(changes)

    address(
      Map.get(c, :chip, a.chip),
      Map.get(c, :sort, a.sort),
      Map.get(c, :filter, a.filter),
      Map.get(c, :status, a.status)
    )
  end

  # ── events ──────────────────────────────────────────────────────────

  @impl true
  def handle_event("cols", %{"n" => n, "device" => device}, socket) do
    case {device, cols(n, nil)} do
      {_, nil} ->
        {:noreply, socket}

      {"mobile", n} ->
        {:noreply, socket |> assign(:cols_m, n) |> push_event("manga:cols", %{mobile: n})}

      {_, n} ->
        {:noreply, socket |> assign(:cols_d, n) |> push_event("manga:cols", %{desktop: n})}
    end
  end

  def handle_event("sync", _params, %{assigns: %{syncing?: true}} = socket),
    do: {:noreply, socket}

  def handle_event("sync", _params, socket) do
    user = socket.assigns.user

    {:noreply,
     socket
     |> assign(:syncing?, true)
     |> start_async(:sync, fn -> RokiWeb.MangaController.sync_caught_up(user) end)}
  end

  def handle_event("bulk_open", _params, %{assigns: %{chip: {:category, id}}} = socket) do
    case Enum.find(socket.assigns.categories, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      cat ->
        {:noreply, socket |> load_members(id) |> assign(:bulk, %{id: id, name: cat.name})}
    end
  end

  def handle_event("bulk_open", _params, socket), do: {:noreply, socket}

  def handle_event("bulk_toggle", %{"key" => key}, %{assigns: %{bulk: %{id: id}}} = socket) do
    case Enum.find(socket.assigns.items, &(&1.key == key)) do
      nil ->
        {:noreply, socket}

      item ->
        Library.toggle_manga_category(item.m.id, id)

        {:noreply,
         socket
         |> load_members(id)
         |> assign(:category_counts, Library.count_manga_per_category(socket.assigns.user.uuid))}
    end
  end

  def handle_event("bulk_toggle", _params, socket), do: {:noreply, socket}

  def handle_event("bulk_close", _params, socket),
    do: {:noreply, socket |> assign(:bulk, nil) |> assign_visible()}

  @impl true
  def handle_async(:sync, {:ok, stats}, socket) do
    {:noreply,
     socket
     |> assign(syncing?: false, items: load_items(socket.assigns.user.uuid))
     |> assign_counts()
     |> assign_visible()
     |> put_flash(:info, sync_message(stats))}
  end

  def handle_async(:sync, {:exit, _reason}, socket) do
    {:noreply, socket |> assign(:syncing?, false) |> put_flash(:error, "Sync failed.")}
  end

  defp sync_message(%{total: 0}), do: "No caught-up titles to sync."

  defp sync_message(s) do
    main =
      if s.with_new == 0,
        do: "Synced #{s.refreshed} #{plural(s.refreshed, "title")} — no new chapters.",
        else:
          "#{s.new_chapters} new #{plural(s.new_chapters, "chapter")} across #{s.with_new} #{plural(s.with_new, "title")}."

    if s.errors > 0, do: "#{main} #{s.errors} failed.", else: main
  end

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"

  # ── data ────────────────────────────────────────────────────────────

  # Every saved title with what its card needs, newest read first.
  defp load_items(uuid) do
    rows = Library.list_saved_manga(uuid)
    pairs = Enum.map(rows, &{&1.source, &1.slug})
    covers = Library.list_cover_file_uuids(pairs)
    statuses = Library.list_publication_statuses(pairs)
    comments = Library.count_annotations_grouped(uuid)

    Enum.map(rows, fn m ->
      %{
        key: "#{m.source}:#{m.slug}",
        m: m,
        kind: MangaHTML.tierlist_kind(m),
        status: MangaHTML.publication_status(m, statuses),
        cover: MangaHTML.cover_image_src(m, covers, "medium"),
        comments: Map.get(comments, {m.source, m.slug}, 0),
        chapter_pct:
          MangaHTML.chapter_read_percent(
            m.last_page,
            m.last_page_fraction,
            m.last_chapter_total_pages
          ),
        pct: if(m.completed, do: 100, else: Library.chapter_progress_percent(m))
      }
    end)
  end

  defp assign_counts(socket) do
    items = socket.assigns.items

    assign(socket,
      counts: Shelf.counts(items),
      resume: Enum.find(items, &(Shelf.started?(&1.m) and not &1.m.completed))
    )
  end

  # The built-in chips in the order and visibility set on /manga/categories.
  defp builtin_chips(prefs) when is_list(prefs) do
    known = Map.new(Shelf.modes())

    saved =
      for %{"id" => id} = p <- prefs, Map.has_key?(known, id), uniq: true do
        {id, known[id], p["hidden"] == true}
      end

    seen = MapSet.new(saved, &elem(&1, 0))
    saved ++ for({id, label} <- Shelf.modes(), id not in seen, do: {id, label, false})
  end

  defp builtin_chips(_), do: Enum.map(Shelf.modes(), fn {id, label} -> {id, label, false} end)

  defp auto_resume_art(uuid) when is_binary(uuid) and uuid != "",
    do: PhoenixKit.Modules.Storage.URLSigner.signed_url(uuid, "original")

  defp auto_resume_art(_), do: nil

  defp cols(v, default) do
    case int(v) do
      n when is_integer(n) and n in @cols_range -> n
      _ -> default
    end
  end

  defp int(n) when is_integer(n), do: n

  defp int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp int(_), do: nil

  defp pick(v, valid?, default), do: if(is_binary(v) and valid?.(v), do: v, else: default)

  # ── page ────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path={@current_path}
      flush
      bleed
      overlay
    >
      <.hero :if={@resume} item={@resume} />
      <RokiWeb.PageHero.page_hero :if={!@resume} eyebrow="Your manga" title="Manga" hue={300} />
      <div class="px-4 pb-12 sm:px-6 lg:px-12 xl:px-16">
        <.toolbar {assigns} />

        <div
          id="manga-grid"
          phx-hook=".ShelfGrid"
          class={["manga-shelf-grid", @visible == [] && "hidden"]}
          style={"--cols-m: #{@cols_m}; --cols-d: #{@cols_d}"}
        >
          <.card :for={item <- @visible} :key={item.key} item={item} />
        </div>
        <div :if={@visible == []} class="py-16 text-center text-base-content/70">
          <p :if={@items == []}>No saved manga yet. Open a manga and press Save to keep it here.</p>
          <p :if={@items != []}>Nothing here with these choices.</p>
          <.link
            :if={@items != [] and (@chip || @filter != "all" || @status != "any")}
            patch={address(nil, @sort, "all", "any")}
            class="btn btn-sm mt-4 rounded-full"
          >
            Show everything
          </.link>
        </div>
      </div>

      <.bulk_dialog :if={@bulk} bulk={@bulk} items={@items} members={Map.get(@members, @bulk.id)} />

      <div
        :if={@auto_resume && @resume}
        id="manga-auto-resume"
        phx-hook=".AutoResume"
        phx-update="ignore"
        data-url={"/manga/#{@resume.m.source}/#{@resume.m.slug}/#{@resume.m.last_chapter}"}
        data-seconds={@auto_resume_timer}
        hidden
        class="fixed inset-0 z-[60] flex cursor-pointer items-center justify-center bg-black/60 p-4"
      >
        <div
          :if={@auto_resume_art}
          class="absolute inset-0 bg-cover bg-center opacity-50"
          style={"background-image: url('#{@auto_resume_art}')"}
        >
        </div>
        <div class="relative w-full max-w-sm rounded-2xl bg-base-100 p-6 shadow-2xl">
          <h3 class="mb-2 text-lg font-bold">Auto-resume</h3>
          <p>
            Resuming <strong>{@resume.m.title}</strong>
            (Chapter {@resume.m.last_chapter}) in <span data-count>{@auto_resume_timer}</span>
            seconds…
          </p>
          <p class="mt-3 text-sm text-base-content/50">Tap anywhere to cancel</p>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ShelfGrid">
        // The covers glide to their new places when the shelf is re-sorted or narrowed, rather
        // than jumping (FLIP: measure, let LiveView patch, play the difference back). Only the
        // ones near the screen are measured: animating hundreds off-screen costs for nothing.
        // Also keeps this device's choices (sort, chip, covers per row) under the old keys.
        export default {
          mounted() {
            this.handleEvent("manga:prefs", (p) => {
              try {
                localStorage.setItem("manga_sort", p.sort)
                localStorage.setItem("manga_filter", p.filter)
                localStorage.setItem("manga_publication_status", p.status)
                localStorage.setItem("manga_chip_state", JSON.stringify(p.chip || {}))
              } catch (_) {}
            })
            this.handleEvent("manga:cols", (p) => {
              try {
                if (p.mobile) localStorage.setItem("manga_grid_cols_mobile", String(p.mobile))
                if (p.desktop) localStorage.setItem("manga_grid_cols_desktop", String(p.desktop))
              } catch (_) {}
            })
          },
          beforeUpdate() {
            const vh = window.innerHeight
            this.before = {}
            for (const c of this.el.children) {
              const r = c.getBoundingClientRect()
              if (r.bottom < -200 || r.top > vh + 200) continue
              this.before[c.id] = r
            }
          },
          updated() {
            const before = this.before || {}
            this.before = null
            if (!Element.prototype.animate) return
            const vh = window.innerHeight
            for (const c of this.el.children) {
              const r = c.getBoundingClientRect()
              if (r.bottom < 0 || r.top > vh) continue
              const old = before[c.id]
              if (old) {
                const dx = old.left - r.left, dy = old.top - r.top
                if (Math.abs(dx) < 1 && Math.abs(dy) < 1) continue
                c.animate([{transform: `translate(${dx}px, ${dy}px)`}, {transform: "none"}],
                  {duration: 350, easing: "cubic-bezier(0.22, 1, 0.36, 1)"})
              } else {
                c.animate([{opacity: 0, transform: "scale(0.96)"}, {opacity: 1, transform: "none"}],
                  {duration: 250, easing: "ease-out"})
              }
            }
          },
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".AutoResume">
        // Opened from outside the site (a bookmark, the home screen icon), the shelf can go
        // straight on to the chapter last read after a countdown; a tap anywhere cancels. Not
        // when arriving from another page of the site, and only once per visit.
        export default {
          mounted() {
            const external = !document.referrer || new URL(document.referrer).host !== location.host
            if (!external || window.__rokiLiveNavigated || window.__rokiAutoResumed) return
            window.__rokiAutoResumed = true
            let n = parseInt(this.el.dataset.seconds, 10) || 5
            const count = this.el.querySelector("[data-count]")
            this.el.hidden = false
            this.timer = setInterval(() => {
              n -= 1
              if (n <= 0) { clearInterval(this.timer); window.location = this.el.dataset.url }
              else if (count) count.textContent = n
            }, 1000)
            this.el.addEventListener("click", () => { clearInterval(this.timer); this.el.hidden = true })
          },
          destroyed() { clearInterval(this.timer) },
        }
      </script>
    </Layouts.app>
    """
  end

  # The title last read, as the top of the page: its cover blurred into a wide picture under the
  # floating header (the look of the site's title pages), the chapter and how far, Continue and
  # the way to its page.
  attr :item, :map, required: true

  defp hero(assigns) do
    m = assigns.item.m

    tail =
      cond do
        assigns.item.chapter_pct -> " · #{assigns.item.chapter_pct}% left"
        m.last_page -> " · Page #{m.last_page}"
        true -> ""
      end

    assigns =
      assign(assigns,
        m: m,
        tail: tail,
        pct: assigns.item.chapter_pct || assigns.item.pct,
        rereading?: m.max_chapter && m.max_chapter != m.last_chapter,
        read_url: "/manga/#{m.source}/#{m.slug}/#{m.last_chapter}"
      )

    ~H"""
    <section
      class="group relative z-20 flex min-h-[clamp(20rem,46svh,30rem)] flex-col justify-end text-white"
      aria-label={"Continue #{@m.title}"}
    >
      <div class="absolute inset-0 -z-10 overflow-hidden bg-neutral-900">
        <img
          src={@item.cover}
          alt=""
          aria-hidden="true"
          decoding="async"
          class="h-full w-full scale-110 object-cover blur-2xl brightness-[0.5] saturate-150 transition-[filter] duration-300 group-hover:brightness-[0.6]"
        />
        <div class="absolute inset-0 bg-gradient-to-r from-black/80 via-black/45 to-black/15"></div>
        <div class="absolute inset-0 bg-gradient-to-t from-black/75 via-transparent to-black/50">
        </div>
      </div>
      <a href={@read_url} class="absolute inset-0 z-10" aria-label={"Continue #{@m.title}"}></a>
      <div class="pointer-events-none relative z-20 flex items-end gap-5 px-4 pb-6 pt-28 sm:gap-6 sm:px-6 lg:px-12 xl:px-16">
        <img
          src={@item.cover}
          alt={@m.title}
          decoding="async"
          class="aspect-[3/4] w-24 shrink-0 rounded-xl object-cover shadow-2xl ring-1 ring-white/15 transition group-hover:ring-white/40 sm:w-36"
        />
        <div class="min-w-0 flex-1">
          <p class="text-xs font-semibold uppercase tracking-[0.25em] text-white/70">
            Continue reading
          </p>
          <h1 class="mt-1 line-clamp-2 text-3xl font-bold leading-[1.04] tracking-tight drop-shadow-lg sm:text-5xl">
            {@m.title}
          </h1>
          <p class="mt-2 text-sm text-white/75">
            <%= if @rereading? do %>
              Rereading Ch. {@m.last_chapter}{@tail}
              <span class="text-white/45">· Read up to Ch. {@m.max_chapter}</span>
            <% else %>
              Chapter {@m.last_chapter}{@tail}
            <% end %>
          </p>
          <div class="pointer-events-auto mt-4 flex flex-wrap items-center gap-2 sm:gap-3">
            <a href={@read_url} class="btn btn-primary h-12 gap-2 rounded-full px-6 text-lg shadow-md">
              <.icon name="hero-play-solid" class="h-5 w-5" /> Continue
            </a>
            <a
              href={"/manga/manga2/#{@m.source}/#{@m.slug}"}
              class="inline-flex h-12 items-center gap-1.5 rounded-full border border-white/25 bg-black/35 px-5 text-sm font-medium backdrop-blur-md transition hover:border-white/60 hover:bg-black/55"
            >
              <.icon name="hero-information-circle" class="h-4 w-4" /> Details
            </a>
          </div>
        </div>
      </div>
      <div
        :if={@pct}
        class="pointer-events-none absolute bottom-0 left-0 z-20 h-1 rounded-r-full bg-primary"
        style={"width: #{@pct}%"}
      >
      </div>
    </section>
    """
  end

  # The chips (built-in, then the account's categories) and the sort menu, in one bar that stays
  # under the header while the shelf scrolls.
  defp toolbar(assigns) do
    ~H"""
    <div class="sticky top-14 z-30 -mx-4 mb-4 flex items-center gap-2 border-b border-base-300/50 bg-base-100/90 px-4 py-2 backdrop-blur sm:-mx-6 sm:px-6 lg:-mx-12 lg:px-12 xl:-mx-16 xl:px-16">
      <div
        id="manga-chips"
        class="flex min-w-0 flex-1 items-center gap-1.5 overflow-x-auto pr-6 [mask-image:linear-gradient(to_right,black_calc(100%-2rem),transparent)] [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
      >
        <.chip
          label="All"
          state={if(@chip == nil, do: :on, else: :off)}
          count={if(@chip == nil, do: length(@visible))}
          title={"#{length(@items)} titles"}
          patch={address(nil, @sort, "all", @status)}
        />
        <.chip
          :for={{id, label, hidden?} <- @builtins}
          :if={not hidden?}
          label={label}
          state={chip_state(@chip, {:mode, id})}
          count={chip_state(@chip, {:mode, id}) != :off && length(@visible)}
          title={"#{@counts[id]} titles"}
          patch={to(assigns, chip: Shelf.next_chip(@chip, {:mode, id}))}
        />
        <%= for cat <- @categories do %>
          <.chip
            label={cat.name}
            state={chip_state(@chip, {:category, cat.id})}
            count={chip_state(@chip, {:category, cat.id}) != :off && length(@visible)}
            title={"#{Map.get(@category_counts, cat.id, 0)} titles"}
            patch={to(assigns, chip: Shelf.next_chip(@chip, {:category, cat.id}))}
          />
          <button
            :if={@chip == {:category, cat.id}}
            type="button"
            phx-click="bulk_open"
            class="btn btn-circle btn-ghost btn-sm shrink-0"
            title={"Add titles to #{cat.name}"}
            aria-label={"Add titles to #{cat.name}"}
          >
            <.icon name="hero-plus" class="h-4 w-4" />
          </button>
        <% end %>
        <.link
          href={~p"/manga/categories"}
          class="btn btn-circle btn-ghost btn-sm shrink-0 text-base-content/60"
          title="Edit chips and categories"
          aria-label="Edit chips and categories"
        >
          <.icon name="hero-pencil-square" class="h-4 w-4" />
        </.link>
      </div>

      <button
        :if={@chip == {:mode, "caughtup"}}
        type="button"
        phx-click="sync"
        disabled={@syncing?}
        class="btn btn-sm h-9 shrink-0 gap-1 rounded-full border-0 bg-base-200"
        title="Look for new chapters of every caught-up title"
      >
        <span :if={@syncing?} class="loading loading-spinner loading-xs"></span>
        <.icon :if={!@syncing?} name="hero-arrow-path" class="h-4 w-4" />
        <span class="hidden sm:inline">{if @syncing?, do: "Syncing…", else: "Sync"}</span>
      </button>

      <.link
        href={~p"/manga/explore"}
        class="btn btn-sm h-9 shrink-0 gap-1 rounded-full border-0 bg-base-200 px-3 font-medium"
        title="Find new manga"
        aria-label="Explore"
      >
        <.icon name="hero-globe-alt" class="h-4 w-4" />
        <span class="hidden sm:inline">Explore</span>
      </.link>

      <div class="dropdown dropdown-end shrink-0">
        <div
          tabindex="0"
          role="button"
          class="btn btn-sm h-9 gap-1 rounded-full border-0 bg-base-200 px-3 font-medium"
          aria-label="Sort and filter"
        >
          <.icon name="hero-adjustments-horizontal" class="h-4 w-4" />
          <span class="hidden sm:inline">{sort_label(@sort)}</span>
          <span :if={filters_on(@filter, @status) > 0} class="badge badge-primary badge-xs">
            {filters_on(@filter, @status)}
          </span>
        </div>
        <div
          tabindex="0"
          class="dropdown-content z-40 mt-2 w-72 rounded-box border border-base-300 bg-base-100 p-3 shadow-xl"
        >
          <.menu_section title="Sort">
            <.pill
              :for={{s, label} <- Shelf.sorts()}
              label={label}
              on={@sort == s}
              patch={to(assigns, sort: s)}
            />
          </.menu_section>
          <.menu_section title="Show">
            <.pill
              :for={{f, label} <- Shelf.filters()}
              label={label}
              on={@filter == f}
              patch={to(assigns, filter: f)}
            />
          </.menu_section>
          <.menu_section title="Series status">
            <.pill
              :for={{s, label} <- Shelf.statuses()}
              label={label}
              on={@status == s}
              patch={to(assigns, status: s)}
            />
          </.menu_section>
          <.menu_section title="Covers per row">
            <div class="col-span-2 flex gap-1 lg:hidden">
              <.cols_button :for={n <- 2..4} n={n} on={@cols_m == n} device="mobile" />
            </div>
            <div class="col-span-2 hidden gap-1 lg:flex">
              <.cols_button :for={n <- 3..7} n={n} on={@cols_d == n} device="desktop" />
            </div>
          </.menu_section>
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :state, :atom, required: true
  attr :count, :any, default: nil
  attr :title, :string, default: nil
  attr :patch, :string, required: true

  defp chip(assigns) do
    ~H"""
    <.link
      patch={@patch}
      replace
      title={@title}
      aria-pressed={to_string(@state == :on)}
      class={[
        "flex h-9 shrink-0 items-center gap-1.5 whitespace-nowrap rounded-full px-3.5 text-sm font-medium transition",
        @state == :on && "bg-primary text-primary-content shadow-sm",
        @state == :excluded && "bg-error/10 text-error line-through ring-1 ring-error/40",
        @state == :off && "bg-base-200 text-base-content/75 hover:text-base-content"
      ]}
    >
      {@label}
      <span
        :if={is_integer(@count)}
        class={[
          "rounded-full px-1.5 text-xs tabular-nums no-underline",
          @state == :on && "bg-primary-content/20",
          @state != :on && "bg-base-content/10"
        ]}
      >
        {@count}
      </span>
    </.link>
    """
  end

  defp chip_state({:mode, m}, {:mode, m}), do: :on
  defp chip_state({:exclude_mode, m}, {:mode, m}), do: :excluded
  defp chip_state({:category, id}, {:category, id}), do: :on
  defp chip_state({:exclude, id}, {:category, id}), do: :excluded
  defp chip_state(_, _), do: :off

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp menu_section(assigns) do
    ~H"""
    <p class="px-1 pb-1.5 pt-2 text-xs font-semibold uppercase tracking-wide text-base-content/50 first:pt-0">
      {@title}
    </p>
    <div class="grid grid-cols-2 gap-1.5">{render_slot(@inner_block)}</div>
    """
  end

  attr :label, :string, required: true
  attr :on, :boolean, default: false
  attr :patch, :string, required: true

  defp pill(assigns) do
    ~H"""
    <.link
      patch={@patch}
      replace
      onclick="document.activeElement.blur()"
      class={["btn btn-sm rounded-full border-0", @on && "btn-primary", !@on && "bg-base-200"]}
    >
      {@label}
    </.link>
    """
  end

  attr :n, :integer, required: true
  attr :on, :boolean, default: false
  attr :device, :string, required: true

  defp cols_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="cols"
      phx-value-n={@n}
      phx-value-device={@device}
      class={[
        "btn btn-sm btn-square flex-1 rounded-full border-0",
        @on && "btn-primary",
        !@on && "bg-base-200"
      ]}
    >
      {@n}
    </button>
    """
  end

  defp sort_label(sort), do: Shelf.sorts() |> Map.new() |> Map.get(sort, "Sort")

  defp filters_on(filter, status),
    do: Enum.count([filter != "all", status != "any"], & &1)

  # A saved title: the cover is the card. Its chapter and comments in the top corners, the title
  # and the way in (carry on, start, or done) at the foot, and how far along a line at the bottom.
  attr :item, :map, required: true

  defp card(assigns) do
    m = assigns.item.m

    assigns =
      assign(assigns,
        m: m,
        id: "manga-" <> Base.url_encode64(assigns.item.key, padding: false),
        rereading?: m.max_chapter && m.last_chapter && m.max_chapter != m.last_chapter,
        total: m.last_chapter_number || m.total_chapters
      )

    ~H"""
    <div
      id={@id}
      class="group relative aspect-[3/4] overflow-hidden rounded-xl bg-base-300 shadow-sm transition-all duration-200 hover:-translate-y-1 hover:shadow-xl"
    >
      <img
        src={@item.cover}
        alt={@m.title}
        loading="lazy"
        decoding="async"
        class="absolute inset-0 h-full w-full object-cover transition-transform duration-300 group-hover:scale-105"
      />
      <a
        href={"/manga/manga2/#{@m.source}/#{@m.slug}"}
        class="absolute inset-0 z-10"
        aria-label={@m.title}
      ></a>
      <div class="pointer-events-none absolute left-1 right-1 top-1 z-20 flex items-center gap-1">
        <span
          :if={Shelf.started?(@m)}
          class="badge badge-sm border-white/15 bg-black/45 font-semibold text-white/90 backdrop-blur-md"
        >
          {@m.last_chapter}
          <span :if={@rereading?} class="opacity-50">&nbsp;/ {@m.max_chapter}</span>
          <span :if={!@rereading? && @total} class="opacity-50">&nbsp;/ {@total}</span>
        </span>
        <span :if={@item.comments > 0} class="badge badge-primary badge-sm ml-auto gap-1">
          <.icon name="hero-chat-bubble-left" class="h-3 w-3" />{@item.comments}
        </span>
      </div>
      <div class="pointer-events-none absolute inset-x-0 bottom-0 z-20 bg-gradient-to-t from-black/90 via-black/40 to-transparent px-2.5 pb-2.5 pt-10">
        <h2 class="line-clamp-2 text-sm font-bold text-white drop-shadow-lg">{@m.title}</h2>
        <div class="mt-1.5 flex items-center justify-end gap-2">
          <span :if={@m.completed} class="badge badge-success badge-sm flex-shrink-0 gap-1">
            <.icon name="hero-check" class="h-3 w-3" /> Done
          </span>
          <a
            :if={!@m.completed && Shelf.started?(@m)}
            href={"/manga/#{@m.source}/#{@m.slug}/#{@m.last_chapter}"}
            class={[
              "btn btn-xs pointer-events-auto flex-shrink-0 gap-1 rounded-full px-3 shadow-md",
              (@rereading? && "btn-secondary") || "btn-primary"
            ]}
            aria-label={"Continue #{@m.title} at chapter #{@m.last_chapter}"}
          >
            <.icon name="hero-play-solid" class="h-3 w-3" />{@m.last_chapter}
          </a>
          <a
            :if={!@m.completed && !Shelf.started?(@m)}
            href={"/manga/#{@m.source}/#{@m.slug}"}
            class="btn btn-primary btn-xs pointer-events-auto flex-shrink-0 rounded-full px-3 shadow-md"
          >
            Start
          </a>
        </div>
      </div>
      <div
        :if={@item.pct}
        class={[
          "pointer-events-none absolute bottom-0 left-0 z-30 h-[3px]",
          (@m.completed && "bg-success") || "bg-primary"
        ]}
        style={"width: #{@item.pct}%"}
      >
      </div>
    </div>
    """
  end

  # Add titles to the category that is on: every saved title, a tick on those already in it.
  attr :bulk, :map, required: true
  attr :items, :list, required: true
  attr :members, :any, default: nil

  defp bulk_dialog(assigns) do
    assigns = assign(assigns, :members, assigns.members || MapSet.new())

    ~H"""
    <div
      id="manga-bulk"
      class="fixed inset-0 z-[60] flex items-end justify-center bg-black/50 sm:items-center sm:p-4"
      phx-window-keydown="bulk_close"
      phx-key="Escape"
    >
      <div class="absolute inset-0" phx-click="bulk_close"></div>
      <div class="relative flex max-h-[85svh] w-full max-w-4xl flex-col rounded-t-2xl bg-base-100 shadow-2xl sm:rounded-2xl">
        <div class="flex items-center justify-between gap-3 border-b border-base-300 px-5 py-4">
          <h3 class="text-lg font-bold">Add to {@bulk.name}</h3>
          <button
            type="button"
            phx-click="bulk_close"
            class="btn btn-circle btn-ghost btn-sm"
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="h-5 w-5" />
          </button>
        </div>
        <div class="grid grid-cols-3 gap-3 overflow-y-auto p-4 sm:grid-cols-4 lg:grid-cols-6">
          <button
            :for={item <- @items}
            type="button"
            phx-click="bulk_toggle"
            phx-value-key={item.key}
            aria-pressed={to_string(MapSet.member?(@members, item.key))}
            class="group relative aspect-[3/4] overflow-hidden rounded-lg bg-base-300 text-left"
          >
            <img
              src={item.cover}
              alt=""
              loading="lazy"
              class="absolute inset-0 h-full w-full object-cover"
            />
            <span class={[
              "absolute right-1 top-1 inline-flex h-6 w-6 items-center justify-center rounded-full",
              (MapSet.member?(@members, item.key) && "bg-primary text-primary-content") ||
                "bg-black/50 text-white/60"
            ]}>
              <.icon name="hero-check" class="h-4 w-4" />
            </span>
            <span class="absolute inset-x-0 bottom-0 line-clamp-2 bg-gradient-to-t from-black/85 to-transparent px-2 pb-2 pt-6 text-xs font-bold text-white">
              {item.m.title}
            </span>
          </button>
        </div>
      </div>
    </div>
    """
  end
end
