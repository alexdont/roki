defmodule RokiWeb.StatsLive do
  @moduledoc """
  `/:username/stats` — what this user has watched, the way laev's stats screen
  shows it: the total and what it is made of, the shelf counts, an activity
  heatmap, and the titles that took the most time, narrowed by when you last
  watched them (last week, month, 6 months, or all time).

  The first measurement looks up a runtime for every film and show — a minute for a
  big library, once; after that it is cached and the page is instant.
  """
  use RokiWeb, :live_view

  import RokiWeb.UserTabs

  alias Roki.{Laev, Stats}

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
          |> assign(:range, nil)
          |> assign(:shown, @page)

        {:ok,
         if(connected?(socket),
           do: start_async(socket, :stats, fn -> load(uuid) end),
           else: socket
         )}
    end
  end

  defp load(uuid) do
    if Laev.connected?(uuid), do: Stats.for_user(uuid), else: :not_connected
  end

  @impl true
  def handle_params(params, _uri, socket) do
    range = Enum.find(Stats.ranges(), fn {id, _, _} -> Atom.to_string(id) == params["range"] end)
    {:noreply, assign(socket, range: range && elem(range, 0), shown: @page)}
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
      flash={@flash}
      wide
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path={"/#{@username}/stats"}
    >
      <div class="space-y-6">
        <.user_tabs username={@username} active={:stats} />

        <div
          :if={@state == :loading}
          class="flex flex-col items-center gap-3 py-24 text-center text-base-content/60"
        >
          <span class="loading loading-spinner"></span>
          <span>Measuring your history…</span>
          <span class="max-w-sm text-sm">
            The first time looks up a length for every film and show, which can take a minute.
            After that it's instant.
          </span>
        </div>

        <.notice :if={@state == :not_connected} username={@username}>
          Connect laev on your shelf to see your stats.
        </.notice>
        <.notice :if={@state == {:error, :no_tmdb_key}} username={@username}>
          Stats need your TMDB key to look up how long films and shows run. Connect laev and bring
          your API keys.
        </.notice>
        <p
          :if={
            match?({:error, r} when r != :no_tmdb_key, @state) and
              not match?({:error, {:rate_limited, _}}, @state)
          }
          class="alert alert-error text-sm"
        >
          Couldn't measure your history just now. Try again in a minute.
        </p>
        <p :if={match?({:error, {:rate_limited, _}}, @state)} class="alert alert-warning text-sm">
          You're refreshing a little fast — try again in a few seconds.
        </p>

        <div :if={@state == :ready} class="space-y-10">
          <.headline d={@data} />
          <.split d={@data} />
          <.activity d={@data} windows={@data.windows} />
          <.most_time
            d={@data}
            username={@username}
            range={@range}
            ranges={@ranges}
            titles={@titles}
            visible={@visible}
            shown={@shown}
            max_seconds={@max_seconds}
          />
          <p :if={@data.totals.unknown > 0} class="text-sm text-base-content/60">
            {@data.totals.unknown} finished {if @data.totals.unknown == 1,
              do: "entry",
              else: "entries"} had no runtime on TMDB, so {if @data.totals.unknown == 1,
              do: "it's",
              else: "they're"} counted as watched but not timed.
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # What the page draws, worked out once per render.
  defp assign_view(%{state: :ready, data: d} = assigns) do
    now = System.os_time(:second)
    default = if Stats.within(d.titles, 7, now) != [], do: :week, else: :all
    range = assigns.range || default

    {_, _, days} = List.keyfind(Stats.ranges(), range, 0)
    titles = Stats.within(d.titles, days, now)

    ranges =
      for {id, label, n} <- Stats.ranges(),
          do: %{id: id, label: label, count: length(Stats.within(d.titles, n, now))}

    assign(assigns,
      range: range,
      ranges: ranges,
      titles: titles,
      visible: Enum.take(titles, assigns.shown),
      max_seconds: titles |> Enum.map(& &1.seconds) |> Enum.max(fn -> 1 end) |> max(1)
    )
  end

  defp assign_view(assigns),
    do: assign(assigns, ranges: [], titles: [], visible: [], max_seconds: 1)

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

  attr :d, :map, required: true

  defp headline(assigns) do
    ~H"""
    <section class="space-y-3">
      <div>
        <div class="text-4xl font-bold tracking-tight sm:text-5xl">
          {Laev.duration(@d.totals.seconds)}
        </div>
        <p class="text-base-content/70">
          across {length(@d.titles)} titles · {@d.totals.films} films · {@d.totals.episodes} episodes
          from {@d.totals.shows} {if @d.totals.shows == 1, do: "show", else: "shows"}
        </p>
      </div>
      <p class="flex flex-wrap gap-x-3 gap-y-1 text-sm text-base-content/70">
        <span :if={@d.tally.series_finished > 0}>
          <b>{@d.tally.series_finished}</b> series finished
        </span>
        <span :if={@d.tally.anime_finished > 0}>
          <b>{@d.tally.anime_finished}</b> anime finished
        </span>
        <span :if={@d.tally.behind > 0}><b>{@d.tally.behind}</b> watching</span>
        <span :if={@d.tally.caught_up > 0}><b>{@d.tally.caught_up}</b> caught up</span>
        <span :if={@d.tally.held > 0}><b>{@d.tally.held}</b> on hold</span>
      </p>
    </section>
    """
  end

  attr :d, :map, required: true

  defp split(assigns) do
    t = assigns.d.totals
    total = max(t.seconds, 1)

    assigns =
      assign(assigns,
        t: t,
        rows:
          Enum.reject(
            [
              {"Films & TV", t.other.seconds, kind_note(t.other, "show"), total},
              {"Anime", t.anime.seconds, kind_note(t.anime, "anime"), total},
              {"In laev", t.in_laev, "played here", total},
              {"Off laev", t.off_laev, "#{t.marked} marked watched, counted at full runtime",
               total}
            ],
            fn {_, s, _, _} -> s == 0 end
          )
      )

    ~H"""
    <section class="space-y-3">
      <h2 class="text-xl font-semibold">Where the time went</h2>
      <div class="space-y-3">
        <div :for={{label, seconds, note, total} <- @rows} class="space-y-1">
          <div class="flex items-baseline justify-between gap-3">
            <span class="font-medium">{label}</span>
            <span class="font-mono text-sm">{Laev.duration(seconds)}</span>
          </div>
          <div class="h-2 overflow-hidden rounded-full bg-base-300">
            <div
              class="h-full rounded-full bg-primary"
              style={"width: #{Float.round(seconds * 100 / total, 1)}%"}
            >
            </div>
          </div>
          <div class="text-xs text-base-content/60">{note}</div>
        </div>
      </div>
      <p :if={@t.measured > 0} class="text-sm text-base-content/70">
        <b>{Laev.duration(@t.skipped)}</b>
        skipped past
        <span class="text-base-content/50">
          (measured on {@t.measured} {if @t.measured == 1, do: "play", else: "plays"} — laev only counts what it watched you watch)
        </span>
      </p>
    </section>
    """
  end

  defp kind_note(%{films: films, episodes: episodes, shows: shows}, unit) do
    [
      films > 0 && "#{films} #{if films == 1, do: "film", else: "films"}",
      episodes > 0 && "#{episodes} episodes from #{shows} #{plural(unit, shows)}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
    |> case do
      "" -> "nothing yet"
      note -> note
    end
  end

  defp plural("anime", _), do: "anime"
  defp plural(unit, 1), do: unit
  defp plural(unit, _), do: unit <> "s"

  # ── activity ───────────────────────────────────────────────────────

  attr :d, :map, required: true
  attr :windows, :list, required: true

  defp activity(assigns) do
    ~H"""
    <section class="space-y-3">
      <h2 class="text-xl font-semibold">Activity</h2>

      <div class="grid grid-cols-2 gap-3 sm:grid-cols-5">
        <div :for={w <- @windows} class="rounded-box bg-base-200 p-3">
          <div class="text-xs text-base-content/60">Last {w.label}</div>
          <div class="text-lg font-bold">{Laev.duration(w.seconds)}</div>
        </div>
        <div class="rounded-box bg-base-200 p-3">
          <div class="text-xs text-base-content/60">Streak</div>
          <div class="text-lg font-bold">{@d.streak.current} days</div>
          <div class="text-xs text-base-content/60">longest {@d.streak.longest}</div>
        </div>
      </div>

      <%!-- A phone shows the last six months, wider screens the year. Today is the
            bottom-right square either way. --%>
      <div class="md:hidden"><.heatmap weeks={Stats.heatmap(@d.days, 26)} /></div>
      <div class="hidden md:block"><.heatmap weeks={Stats.heatmap(@d.days, 53)} /></div>

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

  # ── most time spent ────────────────────────────────────────────────

  attr :d, :map, required: true
  attr :username, :string, required: true
  attr :range, :atom, required: true
  attr :ranges, :list, required: true
  attr :titles, :list, required: true
  attr :visible, :list, required: true
  attr :shown, :integer, required: true
  attr :max_seconds, :integer, required: true

  defp most_time(assigns) do
    ~H"""
    <section class="space-y-3">
      <h2 class="text-xl font-semibold">Most time spent</h2>

      <div class="tabs tabs-box w-fit max-w-full overflow-x-auto" role="tablist">
        <.link
          :for={r <- @ranges}
          patch={~p"/#{@username}/stats?#{[range: r.id]}"}
          class={["tab gap-1", @range == r.id && "tab-active"]}
        >
          {r.label} <span class="text-xs opacity-60">{r.count}</span>
        </.link>
      </div>

      <p :if={@range != :all} class="text-sm text-base-content/60">
        Titles you last watched in this window, with their all-time hours. Hand-marked
        and imported titles have no date, so they appear only in All time.
      </p>

      <p :if={@titles == []} class="py-8 text-center text-base-content/60">Nothing in this window.</p>

      <ol class="divide-y divide-base-300">
        <li :for={{t, i} <- Enum.with_index(@visible, 1)} class="flex items-center gap-3 py-2">
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
              {kind(t)}{if t.off > 0 and t.off == t.seconds, do: " · marked, not measured", else: ""}
            </div>
          </div>
        </li>
      </ol>

      <button :if={length(@titles) > @shown} phx-click="more" class="btn btn-sm btn-ghost">
        Show more ({length(@titles) - @shown} left)
      </button>
    </section>
    """
  end

  defp kind(%{anime: true}), do: "anime"
  defp kind(%{type: "movie"}), do: "film"
  defp kind(_), do: "show"
end
