defmodule RokiWeb.StatsLive do
  @moduledoc """
  `/:username/stats` — everything this account has spent time on, watched and read, as one
  thing: a total, the split across films, shows, anime and manga, a window to look through,
  and the list those numbers are the sum of.

  It used to be two pages stacked on one: laev's watching on top, the reader's own tally
  underneath, each with its own total and its own table. `Roki.Spent` is what made them one —
  the page is a filter over its list, so the big number and the rows always agree.

  A window means "what you were on, and all the time you have spent on it" — a series read for
  a year counts its year, in the window it was last opened in. The heatmap below places the
  same entries on the same dates, so the two halves of the page are one thing seen twice.

  The first measurement looks up a runtime for every film and show — a minute for a
  big library, once; after that it is cached and the page is instant.
  """
  use RokiWeb, :live_view

  alias Roki.{Detail, Laev, Spent, Stats}

  @page 50

  @impl true
  def mount(%{"username" => username}, _session, socket) do
    case RokiWeb.UserGuard.check(socket, username) do
      {:redirect, to} ->
        {:ok, push_navigate(socket, to: to)}

      {:ok, uuid} ->
        socket =
          socket
          |> assign(:page_title, "Stats")
          |> assign(:username, username)
          |> assign(:uuid, uuid)
          |> assign(:state, :loading)
          |> assign(:data, nil)
          |> assign(:detail, nil)
          |> assign(:range, :all)
          |> assign(:only, [])
          |> assign(:hidden, [])
          |> assign(:together, Roki.Link.together(uuid))
          |> assign(:shown, @page)
          |> assign_reading()

        {:ok,
         if(connected?(socket),
           do: start_async(socket, :stats, fn -> load(uuid) end),
           else: socket
         )}
    end
  end

  # Reading comes from the manga tables, not from laev, so this half of the page is here
  # whether or not the terminal app is connected — and the page is worth opening either way.
  # Two queries, both small, so no async.
  defp assign_reading(socket) do
    uuid = socket.assigns.uuid
    read = Roki.Manga.Library.list_reading_stats(uuid)

    assign(socket,
      read: read,
      # A manga cover is fetched through the reader's proxy, or signed when the file is this
      # site's own, so the web layer resolves it and `Roki.Spent` carries no art for reading.
      covers: Map.new(read, &{{&1.source, &1.slug}, manga_cover(&1)}),
      arc_parts: Roki.Manga.ArcDates.parts(uuid, read),
      reading_activity: Roki.Manga.Library.list_reading_activity(uuid),
      watch_dates: Roki.Profile.watch_dates(uuid),
      season_dates: Roki.Profile.season_dates(uuid),
      # Watching that has days of its own, from the sessions the player records as it goes.
      stint_days: Roki.Stints.by_title(uuid, offset(socket)),
      offset: offset(socket)
    )
  end

  # A day is the viewer's day, not UTC — the same offset the reader's history page uses.
  defp offset(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %{user: %{user_timezone: tz}} when is_binary(tz) and tz != "" ->
        Roki.Manga.Library.timezone_offset_seconds(tz)

      _ ->
        0
    end
  end

  defp load(uuid) do
    if Laev.connected?(uuid), do: Stats.for_user(uuid), else: :not_connected
  end

  # What the popup is given: the detail itself, and the few things about the title the detail
  # does not hold (its name, its cover, what the list counts it as).
  defp detail_for({:watching, {type, id} = key}, assigns) do
    with %{titles: titles} <- assigns.data,
         t when not is_nil(t) <- Enum.find(titles, &(&1.type == type and &1.id == id)) do
      key
      |> then(&Detail.watching(assigns.uuid, &1))
      |> Map.merge(%{
        title: t.title,
        poster: t.poster,
        kind_label: kind_label(type),
        counted: t.seconds,
        assumed: t.off,
        believable_from: Stats.believable_from()
      })
    else
      _ -> nil
    end
  end

  defp detail_for({:reading, source, slug}, assigns) do
    with m when not is_nil(m) <-
           Enum.find(assigns.read, &(&1.source == source and &1.slug == slug)),
         %{} = detail <- Detail.reading(assigns.uuid, source, slug) do
      Map.merge(detail, %{
        title: m.title,
        poster: assigns.covers[{source, slug}],
        kind_label: "Manga",
        counted: detail.on_site + detail.off_site
      })
    else
      _ -> nil
    end
  end

  defp detail_for(nil, _assigns), do: nil

  defp kind_label("movie"), do: "Film"
  defp kind_label("tv"), do: "Show"
  defp kind_label("mal"), do: "Anime"

  @impl true
  # Both live in the address, so a view of this page is a link someone can be sent.
  def handle_params(params, _uri, socket) do
    # `kind` is the kinds to show only, `hide` the kinds to leave out. A kind named in both is
    # left out: that is what the address was hand-edited to mean at its most cautious.
    hidden = Spent.kinds_from(params["hide"])
    only = Spent.kinds_from(params["kind"]) -- hidden

    {:noreply,
     assign(socket,
       range: Spent.range(params["range"]),
       only: only,
       hidden: hidden,
       shown: @page
     )}
  end

  @impl true
  def handle_event("more", _params, socket), do: {:noreply, update(socket, :shown, &(&1 + @page))}

  # The number on the right of a row opens everything recorded about it. Always all time, and
  # said to be: a window is a way of looking at the list, and the popup is about the thing.
  def handle_event("inspect", %{"key" => encoded}, socket) do
    {:noreply, assign(socket, :detail, detail_for(Detail.decode(encoded), socket.assigns))}
  end

  def handle_event("close_detail", _params, socket), do: {:noreply, assign(socket, :detail, nil)}

  @impl true
  def handle_async(:stats, {:ok, {:ok, data}}, socket),
    do: {:noreply, assign(socket, state: :ready, data: data)}

  def handle_async(:stats, {:ok, :not_connected}, socket),
    do: {:noreply, assign(socket, :state, :not_connected)}

  def handle_async(:stats, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, :state, {:error, reason})}

  def handle_async(:stats, {:exit, reason}, socket),
    do: {:noreply, assign(socket, :state, {:error, reason})}

  # ── view ───────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns = assign_view(assigns)

    ~H"""
    <Layouts.app
      socket={@socket}
      flash={@flash}
      wide
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path={"/u/#{@username}/stats"}
    >
      <div class="space-y-10">
        <.totals
          username={@username}
          range={@range}
          only={@only}
          hidden={@hidden}
          total={@total}
          split={@split}
          count={length(@visible_all)}
          loading={@state == :loading}
        />

        <.notice :if={@state == :not_connected} username={@username}>
          Connect laev in your corner and what you watch is counted here too.
        </.notice>
        <.notice :if={@state == {:error, :no_tmdb_key}} username={@username}>
          Watching needs your TMDB key to look up how long films and shows run. Connect laev and
          bring your API keys.
        </.notice>
        <p
          :if={
            match?({:error, r} when r != :no_tmdb_key, @state) and
              not match?({:error, {:rate_limited, _}}, @state)
          }
          class="alert alert-error text-sm"
        >
          Couldn't measure your watching just now. Try again in a minute.
        </p>
        <p :if={match?({:error, {:rate_limited, _}}, @state)} class="alert alert-warning text-sm">
          You're refreshing a little fast — try again in a few seconds.
        </p>

        <.waiting :if={@state == :loading} />

        <.spent_list
          :if={@state != :loading}
          entries={@visible}
          all={@visible_all}
          shown={@shown}
          max_seconds={@max_seconds}
          range={@range}
          covers={@covers}
        />

        <.detail_dialog :if={@detail} detail={@detail} offset={@offset} />

        <.together :if={@together.episodes > 0} data={@together} />

        <.activity
          :if={@state != :loading and @days != %{}}
          days={@days}
          windows={@windows}
          streak={@streak}
        />

        <p :if={@unknown > 0} class="text-sm text-base-content/60">
          {@unknown} finished {if @unknown == 1, do: "entry", else: "entries"} had no runtime on
          TMDB, so {if @unknown == 1, do: "it is", else: "they are"} counted as watched but not
          timed.
        </p>
      </div>
    </Layouts.app>
    """
  end

  # What the page draws, worked out once per render: one list, filtered two ways.
  defp assign_view(assigns) do
    now = System.os_time(:second)

    days_back = days_of(assigns.range)
    watched = Spent.watched(assigns[:data], assigns.watch_dates, assigns.season_dates)

    # The two halves are narrowed differently because they are known differently: reading has a
    # day-by-day log, so a window over it is exact; watching is one number per title, so a
    # window holds the titles touched in it, whole.
    in_window =
      Spent.sort(
        Spent.narrow(watched, days_back, now, assigns.stint_days) ++
          Spent.read(assigns.read, assigns.reading_activity, days_back, now, assigns.arc_parts)
      )

    visible_all = Spent.of_kinds(in_window, assigns.only, assigns.hidden)

    days = Spent.days(watched, assigns.reading_activity, assigns.arc_parts, assigns.stint_days)
    today = Date.utc_today()

    assign(assigns,
      total: Spent.total(visible_all),
      split: Spent.by_kind(in_window),
      visible_all: visible_all,
      visible: Enum.take(visible_all, assigns.shown),
      max_seconds: visible_all |> Enum.map(& &1.seconds) |> Enum.max(fn -> 1 end) |> max(1),
      days: days,
      windows: Spent.windows(days, today),
      streak: Spent.streak(days, today),
      unknown: (assigns[:data] && assigns.data.totals.unknown) || 0
    )
  end

  defp days_of(range) do
    Enum.find_value(Spent.ranges(), fn {id, _, n} -> id == range && n end)
  end

  attr :username, :string, required: true
  slot :inner_block, required: true

  defp notice(assigns) do
    ~H"""
    <div class="alert">
      <span>{render_slot(@inner_block)}</span>
      <.link navigate={~p"/u/#{@username}/corner"} class="btn btn-sm">Go to your corner</.link>
    </div>
    """
  end

  # ── the numbers, and the two ways to narrow them ───────────────────

  attr :username, :string, required: true
  attr :range, :atom, required: true
  attr :only, :list, required: true
  attr :hidden, :list, required: true
  attr :total, :integer, required: true
  attr :split, :map, required: true
  attr :count, :integer, required: true
  attr :loading, :boolean, default: false

  defp totals(assigns) do
    ~H"""
    <section class="space-y-4">
      <%!-- Reading is two small queries and watching is a measurement, so one arrives long
           before the other. A number that counts only the half that is in is wrong, and
           watching it jump is worse than waiting for it, so until both halves are here the
           page shows the shape of the answer and none of its digits. --%>
      <div :if={@loading}>
        <div class="skeleton h-12 w-48 sm:h-14"></div>
        <div class="skeleton mt-2 h-5 w-64"></div>
      </div>

      <div :if={!@loading}>
        <div class="text-4xl font-bold tracking-tight sm:text-5xl">{Laev.duration(@total)}</div>
        <p class="text-base-content/70">
          across {@count} {if @count == 1, do: "title", else: "titles"}{scope_note(@only, @hidden)}{range_note(
            @range
          )}
        </p>
      </div>

      <%!-- The split, and the filter: each one is its own share of the window above. --%>
      <div class="flex flex-wrap gap-2">
        <.link
          patch={stats_path(@username, @range, [], [])}
          class={["btn btn-sm", (@only == [] and @hidden == []) && "btn-neutral"]}
        >
          All
        </.link>
        <%!-- Every kind keeps one colour, here and on its bars below, so the chips are the
             legend for the list and nothing has to be labelled twice. A chip is pressed once to
             show only that kind, again to leave it out (red, struck through, and out of the
             number above), and a third time to put it back; any number can be in either state,
             which is how "everything but anime and manga" is made. --%>
        <% states =
          Map.new(Spent.kinds(), fn {id, _} -> {id, Spent.kind_state(id, @only, @hidden)} end) %>
        <% next = Map.new(Spent.kinds(), fn {id, _} -> {id, Spent.cycle(id, @only, @hidden)} end) %>
        <.link
          :for={{id, label} <- Spent.kinds()}
          patch={stats_path(@username, @range, elem(next[id], 0), elem(next[id], 1))}
          title={chip_hint(states[id], label)}
          aria-label={chip_hint(states[id], label)}
          class={[
            "btn btn-sm gap-2",
            chip_class(id, states[id], @only)
          ]}
        >
          <span class={states[id] == :hidden && "line-through"}>{label}</span>
          <span :if={@loading} class="skeleton h-3 w-10"></span>
          <span
            :if={!@loading}
            class={[
              "font-mono text-xs",
              states[id] == :hidden && "line-through",
              states[id] == :off && "opacity-60"
            ]}
          >
            {Laev.duration(@split[id] || 0)}
          </span>
        </.link>
      </div>

      <div class="tabs tabs-box w-fit max-w-full overflow-x-auto" role="tablist">
        <.link
          :for={{id, label, _} <- Spent.ranges()}
          patch={stats_path(@username, id, @only, @hidden)}
          class={["tab", @range == id && "tab-active"]}
        >
          {label}
        </.link>
      </div>
    </section>
    """
  end

  @doc false
  # The list's own shape while the measurement runs, so the page does not grow under the
  # reader's hands when it arrives.
  defp waiting(assigns) do
    ~H"""
    <section class="space-y-3">
      <div class="flex items-center gap-3">
        <h2 class="text-xl font-semibold">Where the time went</h2>
        <span class="loading loading-spinner loading-xs text-base-content/40"></span>
      </div>

      <p class="text-sm text-base-content/60">
        Measuring what you watched — the first time takes a minute, then it is instant.
      </p>

      <ol class="divide-y divide-base-300">
        <li :for={i <- 1..6} class="flex items-center gap-3 py-2">
          <span class="w-6 shrink-0 text-right text-sm text-base-content/30 sm:w-8">{i}</span>
          <div class="skeleton aspect-2/3 w-8 shrink-0 rounded sm:w-10"></div>
          <div class="min-w-0 flex-1 space-y-1.5">
            <div class="flex items-baseline justify-between gap-3">
              <span class={["skeleton h-4", widths(i)]}></span>
              <span class="skeleton h-4 w-14 shrink-0"></span>
            </div>
            <div class="skeleton h-1.5 w-full"></div>
          </div>
        </li>
      </ol>
    </section>
    """
  end

  # Rows of one length read as a loading bar rather than as a list of titles.
  defp widths(i), do: Enum.at(~w(w-48 w-40 w-56 w-36 w-44 w-32), rem(i - 1, 6))

  # The address of this page for a window and a filter. Only what is set is in it, so the
  # unfiltered page is still `?range=all` and the links people have already are still right.
  defp stats_path(username, range, only, hidden) do
    params =
      [range: range, kind: Spent.kinds_param(only), hide: Spent.kinds_param(hidden)]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    ~p"/u/#{username}/stats?#{params}"
  end

  # What the sentence under the number says about the filter: "of films & shows" for the kinds
  # shown alone, "without anime & manga" for the ones left out, and both when both are set.
  defp scope_note(only, hidden) do
    [
      only != [] && " of " <> kind_names(only),
      hidden != [] && " without " <> kind_names(hidden)
    ]
    |> Enum.filter(& &1)
    |> Enum.join()
  end

  defp range_note(:all), do: ""
  defp range_note(range), do: " you were on in the last " <> String.downcase(range_label(range))

  defp kind_names(kinds) do
    case Enum.map(kinds, &String.downcase(label_of(&1))) do
      [one] -> one
      names -> Enum.join(Enum.drop(names, -1), ", ") <> " & " <> List.last(names)
    end
  end

  # Shown: the kind's own colour, solid. Left out: red, outlined. Not asked about: outlined in
  # its own colour, and dimmed too while something else is being shown alone, because then it is
  # not in the number either.
  defp chip_class(id, :only, _only), do: chip(id)
  defp chip_class(_id, :hidden, _only), do: "btn-outline btn-error"
  defp chip_class(id, :off, []), do: [chip(id), "btn-outline"]
  defp chip_class(id, :off, _only), do: [chip(id), "btn-outline opacity-60"]

  # What pressing it would do, since there are three states and the colour only says which one
  # it is in now.
  defp chip_hint(:off, label), do: "Show only #{String.downcase(label)}"
  defp chip_hint(:only, label), do: "Leave #{String.downcase(label)} out of the numbers"
  defp chip_hint(:hidden, label), do: "Put #{String.downcase(label)} back"

  defp label_of(kind), do: Keyword.get(Spent.kinds(), kind, "")

  defp range_label(range) do
    Enum.find_value(Spent.ranges(), "", fn {id, label, _} -> id == range && label end)
  end

  # ── the list those numbers are the sum of ──────────────────────────

  attr :entries, :list, required: true
  attr :all, :list, required: true
  attr :shown, :integer, required: true
  attr :max_seconds, :integer, required: true
  attr :range, :atom, required: true
  attr :covers, :map, required: true

  defp spent_list(assigns) do
    ~H"""
    <section class="space-y-3">
      <h2 class="text-xl font-semibold">Where the time went</h2>

      <p :if={@range != :all} class="text-sm text-base-content/60">
        Reading is counted from its day-by-day log, and so is anything watched here since the
        player started keeping sessions, so for those this is exactly what these days hold.
        Older watching, and anything watched in the terminal app, is one number per title, so a
        title you were on in this window brings all of its time with it. Hours entered by hand
        have no day of their own — give an arc a date on the series page and its share counts
        then.
      </p>

      <p :if={@all == []} class="py-8 text-center text-base-content/60">Nothing in this window.</p>

      <ol class="divide-y divide-base-300">
        <li :for={{t, i} <- Enum.with_index(@entries, 1)} class="flex items-center gap-3 py-2">
          <span class="w-6 shrink-0 text-right text-sm text-base-content/50 sm:w-8">{i}</span>

          <%!-- The cover, because a list of names is harder to read than a shelf. A title with
               no art keeps the space and shows its kind's colour, so the rows stay in line. --%>
          <img
            :if={poster_of(t, @covers)}
            src={poster_of(t, @covers)}
            alt=""
            loading="lazy"
            class="aspect-2/3 w-8 shrink-0 rounded bg-base-300 object-cover sm:w-10"
          />
          <div
            :if={!poster_of(t, @covers)}
            class={[
              "aspect-2/3 w-8 shrink-0 rounded sm:w-10",
              "flex items-center justify-center text-[0.6rem] font-semibold uppercase",
              tint(t.kind)
            ]}
          >
            {String.first(one(t.kind))}
          </div>

          <div class="min-w-0 flex-1">
            <div class="flex items-baseline justify-between gap-3">
              <span class="truncate font-medium" title={t.title}>{t.title}</span>
              <%!-- The number opens everything recorded about it. A dotted underline, because a
                   bare number does not look like something to press. --%>
              <button
                :if={t[:key]}
                type="button"
                phx-click="inspect"
                phx-value-key={Detail.encode(t)}
                aria-label={"Details for #{t.title}"}
                class="shrink-0 cursor-pointer font-mono text-sm underline decoration-base-content/30 decoration-dotted underline-offset-4 transition hover:text-primary hover:decoration-primary"
              >
                {Laev.duration(t.seconds)}
              </button>
              <span :if={!t[:key]} class="shrink-0 font-mono text-sm">
                {Laev.duration(t.seconds)}
              </span>
            </div>
            <div class="mt-1 h-1.5 overflow-hidden rounded-full bg-base-300">
              <div
                class={["h-full rounded-full", bar(t.kind)]}
                style={"width: #{Float.round(t.seconds * 100 / @max_seconds, 1)}%"}
              >
              </div>
            </div>
            <div class="mt-0.5 text-xs text-base-content/50">
              {one(t.kind)}{skipped_note(t)}
            </div>
          </div>
        </li>
      </ol>

      <button :if={length(@all) > @shown} phx-click="more" class="btn btn-sm btn-ghost">
        Show more ({length(@all) - @shown} left)
      </button>
    </section>
    """
  end

  # The one thing worth saying under a name besides what it is: how much of it was skipped
  # past. Only where the figure can be believed (`Roki.Stats.plays/0`), and only when it is big
  # enough to mean something — a few seconds of seeking is not worth a line.
  @doc false
  def skipped_note(%{skipped: skipped}) when is_integer(skipped) and skipped >= 60,
    do: " · skipped #{Laev.duration(skipped)}"

  def skipped_note(_entry), do: ""

  # ── the popup ──────────────────────────────────────────────────────

  attr :detail, :map, required: true
  attr :offset, :integer, default: 0

  @doc false
  def detail_dialog(assigns) do
    ~H"""
    <dialog
      id="detail-dialog"
      class="modal modal-open"
      phx-window-keydown="close_detail"
      phx-key="escape"
      aria-labelledby="detail-title"
    >
      <div class="modal-box max-w-xl space-y-5">
        <button
          type="button"
          phx-click="close_detail"
          class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
          aria-label="Close"
        >
          ✕
        </button>

        <div class="flex items-center gap-4 pr-8">
          <img
            :if={@detail.poster}
            src={@detail.poster}
            alt=""
            class="aspect-2/3 w-14 shrink-0 rounded bg-base-300 object-cover"
          />
          <div class="min-w-0">
            <h3 id="detail-title" class="line-clamp-2 text-lg font-semibold leading-snug">
              {@detail.title}
            </h3>
            <p class="text-sm text-base-content/60">
              {@detail.kind_label} · <span class="font-mono">{Laev.duration(@detail.counted)}</span>
              all time
            </p>
          </div>
        </div>

        <.watching_detail :if={@detail.kind == :watching} detail={@detail} offset={@offset} />
        <.reading_detail :if={@detail.kind == :reading} detail={@detail} offset={@offset} />
      </div>
      <div class="modal-backdrop" phx-click="close_detail"></div>
    </dialog>
    """
  end

  attr :detail, :map, required: true
  attr :offset, :integer, default: 0

  defp watching_detail(assigns) do
    ~H"""
    <.facts title="Time">
      <.fact label="Timed by a player" value={Laev.duration(@detail.counted - @detail.assumed)} />
      <.fact
        :if={@detail.assumed > 0}
        label="Counted without timing"
        value={Laev.duration(@detail.assumed)}
        note="Marked watched or finished, so the full length counts; nothing measured it."
      />
      <.fact
        :if={is_integer(@detail.skipped)}
        label="Skipped past"
        value={Laev.duration(@detail.skipped)}
        note={
          @detail.unsure > 0 &&
            "Not counting up to #{Laev.duration(@detail.unsure)} from earlier plays, which cannot be trusted."
        }
      />
      <.fact
        :if={is_nil(@detail.skipped) and @detail.unsure > 0}
        label="Skipped past"
        value="not known"
        note={"Earlier plays show up to #{Laev.duration(@detail.unsure)}, but that cannot be told apart from progress reports that never arrived. Skipping is recorded reliably for plays from #{day(@detail.believable_from, @offset)}."}
      />
    </.facts>

    <.facts title="When">
      <%!-- A film has one date. Saying it three times, as started, last watched and marked, is
           noise, and "started" would really be the time it finished. --%>
      <.fact
        :if={!film?(@detail)}
        label="Started watching"
        value={moment(@detail.started, @offset)}
        note={how(@detail.started, :first)}
      />
      <.fact
        :if={!film?(@detail)}
        label="Last watched"
        value={moment(@detail.last, @offset)}
        note={how(@detail.last, :last)}
      />
      <.fact
        label={marked_label(@detail)}
        value={moment(@detail.marked, @offset)}
        note={how_marked(@detail.marked)}
      />
      <.fact
        :if={@detail.your_date}
        label="Filed under"
        value={day(@detail.your_date, @offset)}
        note="The date this list counts it on."
      />
    </.facts>

    <.facts
      :if={@detail.session_count > 0}
      title={"Sessions · #{@detail.session_count}, longest #{Laev.duration(@detail.longest)}"}
    >
      <.fact
        :for={s <- @detail.sessions}
        label={"#{day(s.started_at, @offset)}, #{clock(s.started_at, @offset)}–#{clock(s.ended_at, @offset)}"}
        value={Laev.duration(s.seconds)}
      />
    </.facts>

    <details :if={length(@detail.episodes) > 1} class="rounded-box border border-base-300">
      <summary class="cursor-pointer px-4 py-3 text-sm font-medium">
        Episodes · {@detail.played_count} timed, {@detail.marked_count} marked
      </summary>
      <ul class="divide-y divide-base-300 px-4 pb-2 text-sm">
        <li
          :for={e <- Enum.take(@detail.episodes, 60)}
          class="flex items-baseline justify-between gap-3 py-1.5"
        >
          <span>{e.label}</span>
          <span class="text-base-content/60">
            {episode_state(e)}
          </span>
        </li>
      </ul>
      <p :if={length(@detail.episodes) > 60} class="px-4 pb-3 text-xs text-base-content/50">
        and {length(@detail.episodes) - 60} more
      </p>
    </details>
    """
  end

  attr :detail, :map, required: true
  attr :offset, :integer, default: 0

  defp reading_detail(assigns) do
    ~H"""
    <.facts title="Time">
      <.fact label="Read here" value={Laev.duration(@detail.on_site)} />
      <.fact
        :if={@detail.off_site > 0}
        label="Added by hand"
        value={(if @detail.approximate?, do: "~", else: "") <> Laev.duration(@detail.off_site)}
        note="Time you entered on the series page for reading done elsewhere."
      />
    </.facts>

    <.facts title="Progress">
      <.fact
        label="Chapter"
        value={chapters(@detail)}
      />
      <.fact
        :if={@detail.days_read > 0}
        label="Read on"
        value={"#{@detail.days_read} #{if @detail.days_read == 1, do: "day", else: "days"}"}
        note={"#{date(@detail.first_day)} to #{date(@detail.last_day)}"}
      />
    </.facts>

    <.facts title="When">
      <.fact
        label="Started reading"
        value={
          if @detail.started,
            do: moment_at(@detail.started, @offset),
            else: if(@detail.first_day, do: date(@detail.first_day), else: "not recorded")
        }
        note={!@detail.started && @detail.first_day && "The first day reading was recorded."}
      />
      <.fact :if={@detail.last_day} label="Last read" value={date(@detail.last_day)} />
      <.fact label="Caught up" value={moment_at(@detail.caught_up_at, @offset)} />
      <.fact
        label="Completed"
        value={
          if @detail.completed?,
            do: moment_at(@detail.completed_at, @offset) || "yes",
            else: "not yet"
        }
      />
    </.facts>

    <.facts
      :if={@detail.session_count > 0}
      title={"Sessions · #{@detail.session_count}, longest #{Laev.duration(@detail.longest)}"}
    >
      <.fact
        :for={s <- @detail.sessions}
        label={"#{day(s.started_at, @offset)}, #{clock(s.started_at, @offset)}–#{clock(s.ended_at, @offset)}"}
        value={Laev.duration(s.seconds)}
        note={chapter_note(s)}
      />
    </.facts>
    """
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp facts(assigns) do
    ~H"""
    <section>
      <h4 class="mb-1 text-xs font-semibold uppercase tracking-wide text-base-content/50">
        {@title}
      </h4>
      <dl class="divide-y divide-base-300 rounded-box border border-base-300 px-4">
        {render_slot(@inner_block)}
      </dl>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :note, :string, default: nil

  defp fact(assigns) do
    ~H"""
    <div class="py-2 text-sm">
      <div class="flex items-baseline justify-between gap-4">
        <dt class="text-base-content/70">{@label}</dt>
        <dd class="text-right font-mono">{@value}</dd>
      </div>
      <p :if={@note} class="mt-0.5 text-xs text-base-content/50">{@note}</p>
    </div>
    """
  end

  # ── how the popup writes a time ──
  # A date that was not recorded says so, rather than being left blank or guessed.
  defp moment(nil, _offset), do: "not recorded"
  defp moment(%{at: at}, offset), do: "#{day(at, offset)}, #{clock(at, offset)}"

  defp moment_at(nil, _offset), do: "not recorded"
  defp moment_at(at, offset), do: "#{day(at, offset)}, #{clock(at, offset)}"

  defp day(at, offset),
    do: at |> local(offset) |> Calendar.strftime("%-d %b %Y")

  defp clock(at, offset),
    do: at |> local(offset) |> Calendar.strftime("%H:%M")

  defp local(at, offset), do: at |> DateTime.from_unix!() |> DateTime.add(offset, :second)

  defp date(nil), do: "—"
  defp date(%Date{} = d), do: Calendar.strftime(d, "%-d %b %Y")

  # Where a date came from, because a session and a mark are not the same kind of fact.
  defp how(%{how: :session}, _which), do: "From the sessions recorded."

  defp how(%{how: :finish}, :first),
    do: "From the first episode finished; no session was recorded."

  defp how(%{how: :finish}, :last),
    do: "From the last episode finished; no session was recorded."

  defp how(_none, _which), do: nil

  defp film?(%{key: {"movie", _id}}), do: true
  defp film?(_detail), do: false

  defp marked_label(%{key: {"movie", _}, marked: %{state: :finished}}), do: "Finished"
  defp marked_label(%{key: {"movie", _}}), do: "Marked watched"
  defp marked_label(_detail), do: "Marked complete"

  defp how_marked(%{how: :title, state: :marked}), do: "The whole title was marked watched."
  defp how_marked(%{how: :title, state: :finished}), do: "Finished in a player."
  defp how_marked(%{how: :episode}), do: "The last episode marked or finished."
  defp how_marked(_none), do: nil

  defp episode_state(%{state: :finished, timed: t}) when t > 0,
    do: "played · #{Laev.duration(t)} timed"

  defp episode_state(%{state: :finished}), do: "finished"

  defp episode_state(%{state: :marked, timed: t}) when t > 0,
    do: "marked · #{Laev.duration(t)} timed"

  defp episode_state(%{state: :marked}), do: "marked watched"
  defp episode_state(%{state: {:partway, secs}}), do: "stopped at #{Laev.duration(secs)}"

  defp chapters(%{last_chapter: nil}), do: "—"
  defp chapters(%{last_chapter: ch, total_chapters: nil}), do: "#{ch}"
  defp chapters(%{last_chapter: ch, total_chapters: total}), do: "#{ch} of #{total}"

  defp chapter_note(%{keys: [ch | _]}) when is_binary(ch) and ch != "", do: "Chapter #{ch}"
  defp chapter_note(_session), do: nil

  # Where a row's art comes from: watching brings a TMDB poster with it (`Roki.Stats.posters/1`),
  # reading is looked up here, because a cover is fetched through the reader's own proxy — or
  # signed, when the file was uploaded to this site.
  defp poster_of(%{kind: :manga, key: key}, covers), do: covers[key]
  defp poster_of(entry, _covers), do: entry[:poster]

  defp manga_cover(%{cover_file_uuid: uuid}) when is_binary(uuid) and uuid != "",
    do: PhoenixKit.Modules.Storage.URLSigner.signed_url(uuid, "small")

  defp manga_cover(%{cover_url: url}) when is_binary(url) and url != "",
    do: ~p"/manga/proxy/image?#{%{url: url}}"

  defp manga_cover(_manga), do: nil

  # One colour per kind, three ways: the bar in the list, the chip that filters it, and the
  # placeholder where a title has no cover. Films take the theme's own colour; the rest are
  # far enough apart in hue to be told apart at a glance and in either theme.
  defp bar(:movie), do: "bg-primary/70"
  defp bar(:tv), do: "bg-info/70"
  defp bar(:anime), do: "bg-secondary/70"
  defp bar(:manga), do: "bg-success/70"
  defp bar(_kind), do: "bg-base-content/40"

  defp chip(:movie), do: "btn-primary"
  defp chip(:tv), do: "btn-info"
  defp chip(:anime), do: "btn-secondary"
  defp chip(:manga), do: "btn-success"
  defp chip(_kind), do: "btn-neutral"

  defp tint(:movie), do: "bg-primary/20 text-primary"
  defp tint(:tv), do: "bg-info/20 text-info"
  defp tint(:anime), do: "bg-secondary/20 text-secondary"
  defp tint(:manga), do: "bg-success/20 text-success"
  defp tint(_kind), do: "bg-base-300 text-base-content/60"

  defp one(:movie), do: "film"
  defp one(:tv), do: "show"
  defp one(:anime), do: "anime"
  defp one(:manga), do: "manga"

  # ── the day-by-day half, which is exact ────────────────────────────

  attr :days, :map, required: true
  attr :windows, :list, required: true
  attr :streak, :map, required: true

  defp activity(assigns) do
    ~H"""
    <section class="space-y-3">
      <h2 class="text-xl font-semibold">Day by day</h2>
      <p class="text-sm text-base-content/60">
        Watching on the date you gave it, so a whole series lands on one day. Reading on the
        days it was logged.
      </p>

      <div class="grid grid-cols-2 gap-3 sm:grid-cols-5">
        <div :for={w <- @windows} class="rounded-box bg-base-200 p-3">
          <div class="text-xs text-base-content/60">Last {w.label}</div>
          <div class="text-lg font-bold">{Laev.duration(w.seconds)}</div>
        </div>
        <div class="rounded-box bg-base-200 p-3">
          <div class="text-xs text-base-content/60">Streak</div>
          <div class="text-lg font-bold">{@streak.current} days</div>
          <div class="text-xs text-base-content/60">longest {@streak.longest}</div>
        </div>
      </div>

      <%!-- A phone shows the last six months, wider screens the year. Today is the
            bottom-right square either way. --%>
      <div class="md:hidden"><.heatmap weeks={Stats.heatmap(@days, 26)} /></div>
      <div class="hidden md:block"><.heatmap weeks={Stats.heatmap(@days, 53)} /></div>

      <div class="flex items-center gap-1 text-xs text-base-content/60">
        less
        <span
          :for={
            c <- ~w(bg-base-300 bg-success/20 bg-success/40 bg-success/60 bg-success/80 bg-success)
          }
          class={["h-3 w-3 rounded-sm", c]}
        ></span>
        more
      </div>
    </section>
    """
  end

  attr :data, :map, required: true

  # Watching that was marked for two or more people through a linked show (Roki.Link).
  defp together(assigns) do
    ~H"""
    <section class="space-y-3">
      <h2 class="text-xl font-semibold">Together</h2>
      <div class="grid grid-cols-3 gap-3">
        <div class="rounded-box bg-base-200 p-3">
          <div class="text-xs text-base-content/60">Time together</div>
          <div class="text-lg font-bold">{Laev.duration(@data.minutes * 60)}</div>
        </div>
        <div class="rounded-box bg-base-200 p-3">
          <div class="text-xs text-base-content/60">Episodes</div>
          <div class="text-lg font-bold">{@data.episodes}</div>
        </div>
        <div class="rounded-box bg-base-200 p-3">
          <div class="text-xs text-base-content/60">
            {if @data.shows == 1, do: "Show", else: "Shows"}
          </div>
          <div class="text-lg font-bold">{@data.shows}</div>
        </div>
      </div>

      <div :if={@data.partners != []} class="flex flex-wrap gap-2">
        <span
          :for={p <- @data.partners}
          class="rounded-full bg-base-200 px-3 py-1 text-sm"
          title={"#{p.name}: #{Laev.duration(p.minutes * 60)}"}
        >
          <.link navigate={~p"/u/#{p.name}/profile"} class="font-medium hover:underline">{p.name}</.link>
          <span class="text-base-content/60">{Laev.duration(p.minutes * 60)}</span>
        </span>
      </div>

      <ul :if={@data.titles != []} class="space-y-1 text-sm">
        <li :for={t <- @data.titles} class="flex items-center justify-between gap-3">
          <.link navigate={~p"/title/tv/#{t.tmdb_id}"} class="min-w-0 truncate hover:underline">
            {t.name}
          </.link>
          <span class="shrink-0 tabular-nums text-base-content/60">{Laev.duration(t.minutes * 60)}</span>
        </li>
      </ul>
      <p class="text-xs text-base-content/50">
        Counted from episodes marked for two or more of you through a linked show.
      </p>
    </section>
    """
  end

  attr :weeks, :list, required: true

  defp heatmap(assigns) do
    ~H"""
    <div class="overflow-x-auto pb-1">
      <div class="inline-flex gap-[3px]">
        <div :for={week <- @weeks} class="flex flex-col gap-[3px]">
          <span
            :for={{date, seconds} <- week}
            class={["h-3 w-3 rounded-sm", cell(seconds)]}
            title={cell_title(date, seconds)}
          ></span>
        </div>
      </div>
    </div>
    """
  end

  # Fixed steps, not quantiles: half an hour and a film mean the same thing every
  # week, where a quantile scale would repaint the year after one long evening.
  defp cell(nil), do: "invisible"
  defp cell(0), do: "bg-base-300"
  defp cell(s) when s < 30 * 60, do: "bg-success/20"
  defp cell(s) when s < 90 * 60, do: "bg-success/40"
  defp cell(s) when s < 3 * 3600, do: "bg-success/60"
  defp cell(s) when s < 5 * 3600, do: "bg-success/80"
  defp cell(_), do: "bg-success"

  defp cell_title(_date, nil), do: nil

  defp cell_title(date, seconds),
    do: "#{Calendar.strftime(date, "%b %-d")} · #{Laev.duration(seconds)}"
end
