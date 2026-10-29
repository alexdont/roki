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

  alias Roki.{Laev, Spent, Stats}

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
          |> assign(:range, :all)
          |> assign(:kind, :all)
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
      arc_parts: Roki.Manga.ArcDates.parts(uuid, read),
      reading_activity: Roki.Manga.Library.list_reading_activity(uuid),
      watch_dates: Roki.Profile.watch_dates(uuid),
      season_dates: Roki.Profile.season_dates(uuid)
    )
  end

  defp load(uuid) do
    if Laev.connected?(uuid), do: Stats.for_user(uuid), else: :not_connected
  end

  @impl true
  # Both live in the address, so a view of this page is a link someone can be sent.
  def handle_params(params, _uri, socket) do
    {:noreply,
     assign(socket,
       range: Spent.range(params["range"]),
       kind: Spent.kind(params["kind"]),
       shown: @page
     )}
  end

  @impl true
  def handle_event("more", _params, socket), do: {:noreply, update(socket, :shown, &(&1 + @page))}

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
      current_path={"/#{@username}/stats"}
    >
      <div class="space-y-10">
        <.totals
          username={@username}
          range={@range}
          kind={@kind}
          total={@total}
          split={@split}
          count={length(@visible_all)}
        />

        <p
          :if={@state == :loading}
          class="flex items-center gap-3 text-sm text-base-content/60"
        >
          <span class="loading loading-spinner loading-sm"></span>
          Measuring what you watched — the first time takes a minute.
        </p>

        <.notice :if={@state == :not_connected} username={@username}>
          Connect laev on your shelf and what you watch is counted here too.
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

        <.spent_list
          entries={@visible}
          all={@visible_all}
          shown={@shown}
          max_seconds={@max_seconds}
          range={@range}
        />

        <.activity :if={@days != %{}} days={@days} windows={@windows} streak={@streak} />

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
        Spent.within(watched, days_back, now) ++
          Spent.read(assigns.read, assigns.reading_activity, days_back, now, assigns.arc_parts)
      )

    visible_all = Spent.of_kind(in_window, assigns.kind)

    days = Spent.days(watched, assigns.reading_activity, assigns.arc_parts)
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
      <.link navigate={~p"/#{@username}/home"} class="btn btn-sm">Go to your shelf</.link>
    </div>
    """
  end

  # ── the numbers, and the two ways to narrow them ───────────────────

  attr :username, :string, required: true
  attr :range, :atom, required: true
  attr :kind, :atom, required: true
  attr :total, :integer, required: true
  attr :split, :map, required: true
  attr :count, :integer, required: true

  defp totals(assigns) do
    ~H"""
    <section class="space-y-4">
      <div>
        <div class="text-4xl font-bold tracking-tight sm:text-5xl">{Laev.duration(@total)}</div>
        <p class="text-base-content/70">
          across {@count} {if @count == 1, do: "title", else: "titles"}{if @kind != :all,
            do: " of " <> String.downcase(label_of(@kind))}{if @range != :all,
            do: " you were on in the last " <> String.downcase(range_label(@range))}
        </p>
      </div>

      <%!-- The split, and the filter: each one is its own share of the window above. --%>
      <div class="flex flex-wrap gap-2">
        <.link
          patch={~p"/#{@username}/stats?#{[range: @range, kind: :all]}"}
          class={["btn btn-sm", @kind == :all && "btn-primary"]}
        >
          All
        </.link>
        <.link
          :for={{id, label} <- Spent.kinds()}
          patch={~p"/#{@username}/stats?#{[range: @range, kind: id]}"}
          class={["btn btn-sm gap-2", @kind == id && "btn-primary"]}
        >
          {label}
          <span class={["font-mono text-xs", @kind != id && "opacity-60"]}>
            {Laev.duration(@split[id] || 0)}
          </span>
        </.link>
      </div>

      <div class="tabs tabs-box w-fit max-w-full overflow-x-auto" role="tablist">
        <.link
          :for={{id, label, _} <- Spent.ranges()}
          patch={~p"/#{@username}/stats?#{[range: id, kind: @kind]}"}
          class={["tab", @range == id && "tab-active"]}
        >
          {label}
        </.link>
      </div>
    </section>
    """
  end

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

  defp spent_list(assigns) do
    ~H"""
    <section class="space-y-3">
      <h2 class="text-xl font-semibold">Where the time went</h2>

      <p :if={@range != :all} class="text-sm text-base-content/60">
        Reading is counted from its day-by-day log, so this is exactly what these days hold.
        Watching is one number per title, so a title you were on in this window brings all of
        its time with it. Hours entered by hand have no day of their own — give an arc a date
        on the series page and its share counts then.
      </p>

      <p :if={@all == []} class="py-8 text-center text-base-content/60">Nothing in this window.</p>

      <ol class="divide-y divide-base-300">
        <li :for={{t, i} <- Enum.with_index(@entries, 1)} class="flex items-center gap-3 py-2">
          <span class="w-8 shrink-0 text-right text-sm text-base-content/50">{i}</span>
          <div class="min-w-0 flex-1">
            <div class="flex items-baseline justify-between gap-3">
              <span class="truncate font-medium" title={t.title}>{t.title}</span>
              <span class="shrink-0 font-mono text-sm">{Laev.duration(t.seconds)}</span>
            </div>
            <div class="mt-1 h-1.5 overflow-hidden rounded-full bg-base-300">
              <div
                class="h-full rounded-full bg-primary/70"
                style={"width: #{Float.round(t.seconds * 100 / @max_seconds, 1)}%"}
              >
              </div>
            </div>
            <div class="mt-0.5 text-xs text-base-content/50">
              {one(t.kind)}{if t.off > 0 and t.off == t.seconds,
                do: " · marked, not measured",
                else: ""}
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
