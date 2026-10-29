defmodule RokiWeb.Live.HistoryLive do
  @moduledoc """
  The reading-history page (`/manga/history`), built on
  `phoenix_live_calendar`.

  The month grid renders through `PhoenixLiveCalendar.CalendarComponent`
  (heatmap of daily reading seconds + a custom `:day_cell` slot
  reproducing our cover thumbnails, milestone badges and rich hover
  tooltip, and a `:header` slot for the month nav). Everything below the
  calendar — the time-of-day card, milestone list and history feed — is
  our own markup, ported from the dead view.

  Replaced the dead-view implementation (`MangaController.history/2` +
  `manga_html/history.html.heex`), which is still reachable at
  `/manga/legacy/history` as a fallback. Day-cell entry collapsing is
  shared with it through `MangaHTML.collapse_day_entries/1`, so the two
  can't drift.
  """
  use RokiWeb, :live_view

  alias Roki.Manga.Library
  alias RokiWeb.MangaHTML
  alias PhoenixLiveCalendar.Heatmap

  @impl true
  def mount(params, _session, socket) do
    case RokiWeb.UserGuard.check(socket, params["username"] || whoami(socket)) do
      {:redirect, to} -> {:ok, push_navigate(socket, to: to)}
      {:ok, _uuid} -> mounted(socket)
    end
  end

  # The address carries the name now (`/:username/history`); the reader's own address sent
  # people here without one.
  defp whoami(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      nil -> nil
      scope -> scope |> PhoenixKit.Users.Auth.Scope.user() |> Map.get(:username)
    end
  end

  defp mounted(socket) do
    user = socket.assigns.phoenix_kit_current_scope.user
    today = Date.utc_today()
    month = Date.beginning_of_month(today)
    offset_seconds = Library.timezone_offset_seconds(user.user_timezone)

    {all_activity, watched_meta} = activity(user.uuid, offset_seconds)

    saved_all = Library.list_saved_manga(user.uuid)
    meta_cover_uuids = Library.list_cover_file_uuids(Enum.map(saved_all, &{&1.source, &1.slug}))

    manga_meta =
      Map.new(saved_all, fn m ->
        {{m.source, m.slug},
         %{
           title: m.title,
           cover_url: m.cover_url,
           cover_uuid: m.cover_file_uuid || Map.get(meta_cover_uuids, {m.source, m.slug})
         }}
      end)
      |> Map.merge(watched_meta)

    stint_titles = Map.new(saved_all, fn m -> {"manga:#{m.source}/#{m.slug}", m.title} end)

    socket =
      socket
      |> assign(
        page_title: "History",
        # The manga layout's navigation row marks where you are; a live page has no conn
        # to read the path from.
        current_path: "/#{user.username}/history",
        user: user,
        offset_seconds: offset_seconds,
        all_activity: all_activity,
        manga_meta: manga_meta,
        stint_titles: stint_titles,
        stint_tz: offset_seconds,
        hourly_averages: Library.list_hourly_averages(user.uuid),
        month: month,
        today: today,
        manga_filter: nil,
        resume_manga: Enum.find(saved_all, & &1.last_chapter)
      )
      |> apply_filter(nil)
      |> load_month_events(month)
      |> select_date(today)

    {:ok, socket}
  end

  # ── calendar callbacks ────────────────────────────────────────────────

  @impl true
  def handle_info({:date_selected, %Date{} = date}, socket) do
    {:noreply, select_date(socket, date)}
  end

  @impl true
  def handle_info({:range_changed, %{date: %Date{} = anchor}}, socket) do
    month = Date.beginning_of_month(anchor)

    socket =
      socket
      |> assign(:month, month)
      |> load_month_events(month)
      # the dropdown is scoped to the visible month, so it moves with it
      |> assign_manga_list()

    {:noreply, socket}
  end

  def handle_info({:range_changed, _other}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("filter_manga", %{"manga" => filter}, socket) do
    filter = if filter in [nil, ""], do: nil, else: filter
    {:noreply, socket |> assign(:manga_filter, filter) |> apply_filter(filter)}
  end

  # Remove a series' reading activity for the selected day (feed + heatmap +
  # chapter reads). Library milestone events are removed separately.
  def handle_event("remove_activity", %{"source" => source, "slug" => slug}, socket) do
    Library.delete_day_activity(
      socket.assigns.user.uuid,
      socket.assigns.selected_date,
      source,
      slug,
      socket.assigns.offset_seconds
    )

    {:noreply, reload(socket)}
  end

  # Remove a single milestone event (started / caught_up / completed).
  def handle_event("remove_event", %{"id" => id}, socket) do
    Library.delete_library_event(socket.assigns.user.uuid, String.to_integer(id))
    {:noreply, reload(socket)}
  end

  # Re-pull everything a delete can touch: all-time activity (→ markers +
  # dropdown), the visible month's milestone badges, and the selected day.
  defp reload(socket) do
    socket
    |> then(fn s ->
      {activity, _meta} = activity(s.assigns.user.uuid, s.assigns.offset_seconds)
      assign(s, :all_activity, activity)
    end)
    |> apply_filter(socket.assigns.manga_filter)
    |> load_month_events(socket.assigns.month)
    |> select_date(socket.assigns.selected_date)
  end

  # ── data loading ──────────────────────────────────────────────────────

  @doc false
  # A day holds whatever was done that day: chapters read, and films, shows and anime finished.
  # Reading is the one that is timed, so it is the one the heatmap is drawn from — a finished
  # film counts as something done, not as an amount of time.
  defp activity(uuid, offset_seconds) do
    reading = Library.list_reading_activity(uuid)
    watched = Roki.Profile.history(uuid)

    by_day =
      Enum.group_by(
        watched,
        fn t ->
          t.at
          |> DateTime.from_unix!()
          |> DateTime.add(offset_seconds, :second)
          |> DateTime.to_date()
        end,
        fn t ->
          %{
            title: t.title,
            source: "watch",
            slug: "#{t.type}:#{t.id}",
            seconds: 0,
            chapters_read: nil
          }
        end
      )

    meta =
      Map.new(watched, fn t ->
        {{"watch", "#{t.type}:#{t.id}"}, %{title: t.title, poster: t.poster, cover_uuid: nil}}
      end)

    {Map.merge(reading, by_day, fn _day, read, seen -> read ++ seen end), meta}
  end

  # Filter the all-time activity to a single series (or not), then rebuild
  # the heatmap markers and the filter dropdown's option list off it.
  defp apply_filter(socket, filter) do
    activity =
      case filter do
        nil ->
          socket.assigns.all_activity

        filter ->
          [fsource, fslug] = String.split(filter, "/", parts: 2)

          socket.assigns.all_activity
          |> Enum.map(fn {date, entries} ->
            {date, Enum.filter(entries, fn e -> e.source == fsource and e.slug == fslug end)}
          end)
          |> Enum.reject(fn {_date, entries} -> entries == [] end)
          |> Map.new()
      end

    socket
    |> assign(:activity, activity)
    |> assign_markers(activity)
    |> assign_manga_list()
  end

  # Dropdown options are the series read inside the VISIBLE month's
  # calendar range, not all-time — dead-view parity, so the list changes
  # as you page months. Always built from the unfiltered activity,
  # otherwise picking a series would collapse the list to just itself.
  defp assign_manga_list(socket) do
    {cal_first, cal_last} = calendar_range(socket.assigns.month)

    manga_list =
      socket.assigns.all_activity
      |> Enum.filter(fn {date, _entries} ->
        Date.compare(date, cal_first) != :lt and Date.compare(date, cal_last) != :gt
      end)
      |> Enum.flat_map(fn {_date, entries} -> entries end)
      |> Enum.reject(fn e -> is_nil(e.title) or e.title == "" end)
      |> Enum.group_by(fn e -> {e.title, e.source, e.slug} end)
      |> Enum.map(fn {{title, source, slug}, entries} ->
        %{
          title: title,
          source: source,
          slug: slug,
          seconds: Enum.sum(Enum.map(entries, & &1.seconds))
        }
      end)
      |> Enum.sort_by(& &1.seconds, :desc)

    assign(socket, :manga_list, manga_list)
  end

  # The padded Mon-first grid the month view actually renders: the month
  # plus the leading/trailing days that fill its first and last weeks.
  defp calendar_range(month) do
    last_day = Date.end_of_month(month)
    start_pad = Date.day_of_week(month) - 1
    end_pad = 7 - Date.day_of_week(last_day)
    {Date.add(month, -start_pad), Date.add(last_day, end_pad)}
  end

  # Heatmap markers from daily reading seconds. The library tints each cell
  # background via a :fill marker; we still read the raw value in the slot.
  defp assign_markers(socket, activity) do
    seconds_by_day =
      activity
      |> Map.new(fn {date, entries} -> {date, Enum.sum(Enum.map(entries, & &1.seconds))} end)
      |> Map.reject(fn {_date, seconds} -> seconds == 0 end)

    markers =
      Heatmap.markers(seconds_by_day,
        palette: :success,
        scale: :linear,
        label: &MangaHTML.format_reading_time/1
      )

    assign(socket, :markers, markers)
  end

  # Milestones (completed / caught_up / started) over the visible month,
  # grouped by local day and series — same badge ranking as the dead view.
  defp load_month_events(socket, month) do
    {cal_first, cal_last} = calendar_range(month)
    offset = socket.assigns.offset_seconds

    month_events =
      Library.library_events_between(socket.assigns.user.uuid, cal_first, cal_last, offset)
      |> Enum.group_by(fn e ->
        e.happened_at |> DateTime.add(offset, :second) |> DateTime.to_date()
      end)
      |> Map.new(fn {date, evs} ->
        {date,
         evs
         |> Enum.group_by(fn e -> {e.source, e.slug} end)
         |> Map.new(fn {key, es} ->
           kinds = MapSet.new(es, & &1.event)

           badge =
             cond do
               MapSet.member?(kinds, "completed") -> "completed"
               MapSet.member?(kinds, "caught_up") -> "caught_up"
               true -> "started"
             end

           {key, badge}
         end)}
      end)

    assign(socket, :month_events, month_events)
  end

  # Everything specific to the selected day.
  defp select_date(socket, date) do
    user = socket.assigns.user
    offset = socket.assigns.offset_seconds

    assign(socket,
      selected_date: date,
      user_now: DateTime.utc_now() |> DateTime.add(offset, :second),
      history: Library.list_reading_history_for_date(user.uuid, date),
      hourly_activity: Library.list_hourly_activity_for_date(user.uuid, date),
      stints: Stint.on_date(user.uuid, date, utc_offset: offset),
      chapter_reads: Library.chapter_reads_on_date(user.uuid, date, offset),
      library_events: Library.library_events_on_date(user.uuid, date, offset)
    )
  end

  # ── view helpers ──────────────────────────────────────────────────────

  # Strip a leading-zero pad from a chapter label (dead-view display_chapter/1).
  defp display_chapter(ch), do: String.replace(ch, ~r/^0+(?=\d)/, "")

  defp event_label("completed"), do: "completed"
  defp event_label("started"), do: "started"
  defp event_label(_), do: "caught up"

  # Kebab (⋮) trigger icon for the row option menus.
  defp kebab(assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" viewBox="0 0 24 24" fill="currentColor">
      <path d="M12 6a2 2 0 110-4 2 2 0 010 4zm0 8a2 2 0 110-4 2 2 0 010 4zm0 8a2 2 0 110-4 2 2 0 010 4z" />
    </svg>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path={@current_path}
      flush
    >
      <div class="max-w-6xl mx-auto px-4 py-8">
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-lg font-semibold">History</h2>
          <div class="flex items-center gap-3">
            <form :if={@manga_list != []} phx-change="filter_manga">
              <select name="manga" class="select select-sm select-bordered max-w-[200px] truncate">
                <option value="">All manga</option>
                <option
                  :for={m <- @manga_list}
                  value={"#{m.source}/#{m.slug}"}
                  selected={@manga_filter == "#{m.source}/#{m.slug}"}
                >
                  {m.title}
                </option>
              </select>
            </form>
          </div>
        </div>

        <%!-- Calendar heatmap via phoenix_live_calendar. The library owns the
           cell chrome (heatmap fill, selected/today rings, out-of-month
           dimming); our :day_cell slot adds thumbnails, badges and the
           rich hover tooltip.

           cell_height "40px" reproduces the dead view's h-10 cells (the
           built-in tiers start at 80px — twice as tall). cell_overflow
           :visible drops the cell clip so the hover tooltip escapes, and
           also stops the view container from re-swallowing it; it
           replaces the expand_cells hack, which only avoided the clip by
           letting cells grow.

           The library's root is its own card (bg-base-100, border,
           rounded-lg, shadow) — inside our base-200 panel that reads as a
           card in a card, which the dead view never had, and it changes
           what the base-300 tooltip sits against. Flattened here so the
           panel stays the only card. Tailwind v4 important SUFFIX (`!`
           after the utility); class order alone wouldn't win. --%>
        <div class="bg-base-200 rounded-xl p-4 mb-6">
          <.live_component
            module={PhoenixLiveCalendar.CalendarComponent}
            id="reading-history"
            class="bg-transparent! border-0! shadow-none! rounded-none!"
            view={:month}
            views={[:month]}
            week_start={1}
            show_legend={false}
            cell_height="40px"
            cell_overflow={:visible}
            day_markers={@markers}
            selected_date={@selected_date}
            today={@today}
            on_date_select={fn d -> send(self(), {:date_selected, d}) end}
            on_date_range_change={fn r -> send(self(), {:range_changed, r}) end}
          >
            <%!-- Month nav in the dead view's shape: centered label between
               two ghost arrows, with "next" held as invisible (not
               removed) on the current month so the title stays centered.
               The commands arrive pre-targeted at the component — slot
               content renders in this LiveView's scope, so a plain
               phx-click here would never reach it. --%>
            <:header :let={h}>
              <div class="flex items-center justify-between gap-3 px-1 py-2 mb-2">
                <button
                  type="button"
                  phx-click={h.on_prev}
                  class="btn btn-ghost btn-sm btn-square"
                  aria-label="Previous month"
                >
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    class="h-5 w-5"
                    fill="none"
                    viewBox="0 0 24 24"
                    stroke="currentColor"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M15 19l-7-7 7-7"
                    />
                  </svg>
                </button>
                <span class="font-semibold text-base">{h.title}</span>
                <button
                  type="button"
                  phx-click={h.on_next}
                  disabled={h.today_visible}
                  class={["btn btn-ghost btn-sm btn-square", h.today_visible && "invisible"]}
                  aria-label="Next month"
                >
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    class="h-5 w-5"
                    fill="none"
                    viewBox="0 0 24 24"
                    stroke="currentColor"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M9 5l7 7-7 7"
                    />
                  </svg>
                </button>
              </div>
            </:header>

            <:day_cell :let={%{date: date}}>
              <%!-- Padding days from the neighbouring months carry real
                 activity (@activity is all-time, @month_events covers the
                 padded range), so the slot has to gate on in-month itself
                 — otherwise a greyed-out cell sprouts covers and a hover
                 tooltip the dead view never showed. --%>
              <% in_month = date.year == @month.year and date.month == @month.month %>
              <% day_events = if in_month, do: Map.get(@month_events, date, %{}), else: %{} %>
              <%!-- Collapsed to one row per series — @activity holds a row
                 per reading session, so a series read three times in a
                 day would otherwise draw three covers and three
                 identical tooltip lines. --%>
              <% entries =
                if in_month,
                  do: MangaHTML.collapse_day_entries(Map.get(@activity, date, [])),
                  else: [] %>
              <% covers = MangaHTML.calendar_day_covers(entries, day_events, @manga_meta) %>
              <%!-- One row at 40px, like the dead view: day number left,
                 cover thumbnails right. The daily total lives in the
                 tooltip — there's no room for it beside the covers.
                 No `relative` here on purpose: the tooltip below anchors
                 to `.cal-day-cell` (which the library positions), so it
                 centres on the true cell instead of this padded box. --%>
              <div class="group h-full">
                <%!-- cell_overflow :visible (needed so the tooltip can
                   escape) also dropped the clip the dead view had on the
                   cell itself, letting up to 3 covers spill into the next
                   day on narrow screens. Clip them HERE instead: the
                   tooltip is a sibling of this wrapper, so it still
                   escapes while the covers stay inside their day. --%>
                <div class="h-full px-1 flex items-center justify-between gap-0.5 overflow-hidden">
                  <span class={[
                    "text-xs flex-shrink-0",
                    if(in_month, do: "text-base-content/70", else: "text-base-content/30")
                  ]}>{date.day}</span>
                  <%!-- Covers and their milestone badges scale down on
                     phone-width cells (~45px) and take the dead view's
                     sizes from `sm:` up, so three of them fit the row
                     instead of being clipped away. --%>
                  <div
                    :if={covers != []}
                    class="flex gap-px sm:gap-0.5 items-center justify-end min-w-0"
                  >
                    <div :for={c <- covers} class="relative flex-shrink min-w-0">
                      <img
                        :if={c.src}
                        src={c.src}
                        alt={c.title}
                        loading="lazy"
                        class="h-5 max-w-[13px] sm:h-7 sm:max-w-[20px] aspect-[2/3] object-cover rounded-[2px] sm:rounded-[3px] ring-1 ring-base-100/40"
                      />
                      <div
                        :if={!c.src}
                        class="h-5 max-w-[13px] sm:h-7 sm:max-w-[20px] aspect-[2/3] rounded-[2px] sm:rounded-[3px] bg-base-content/20"
                      >
                      </div>
                      <span
                        :if={c.event == "completed"}
                        class="absolute -top-0.5 -right-0.5 w-2 h-2 sm:w-2.5 sm:h-2.5 rounded-full bg-success text-success-content text-[6px] sm:text-[7px] flex items-center justify-center shadow"
                      >✓</span>
                      <span
                        :if={c.event == "caught_up"}
                        class="absolute -top-0.5 -right-0.5 w-2 h-2 sm:w-2.5 sm:h-2.5 rounded-full bg-warning text-warning-content text-[6px] sm:text-[7px] flex items-center justify-center shadow"
                      >⚡</span>
                      <span
                        :if={c.event == "started"}
                        class="absolute -top-0.5 -right-0.5 w-2 h-2 sm:w-2.5 sm:h-2.5 rounded-full bg-info text-info-content text-[6px] sm:text-[7px] flex items-center justify-center shadow"
                      >▶</span>
                    </div>
                  </div>
                </div>

                <%!-- rich hover tooltip: one row per series read that day --%>
                <div
                  :if={entries != [] or day_events != %{}}
                  class="absolute bottom-full left-1/2 -translate-x-1/2 mb-2 hidden group-hover:block z-50 pointer-events-none"
                >
                  <div class="bg-base-300 border border-base-content/10 rounded-lg shadow-lg px-3 py-2 text-xs whitespace-nowrap">
                    <div class="font-semibold mb-1">{Calendar.strftime(date, "%b %-d, %Y")}</div>
                    <% row_event = fn entry -> Map.get(day_events, {entry.source, entry.slug}) end %>
                    <div
                      :for={entry <- entries}
                      class={[
                        "flex justify-between gap-4",
                        case row_event.(entry) do
                          "completed" -> "text-success font-medium"
                          "caught_up" -> "text-warning font-medium"
                          "started" -> "text-info font-medium"
                          _ -> "text-base-content/70"
                        end
                      ]}
                    >
                      <span class="flex items-center gap-1 min-w-0">
                        <span
                          :if={row_event.(entry) == "completed"}
                          class="flex-shrink-0"
                          title="Completed"
                        >✓</span>
                        <span
                          :if={row_event.(entry) == "caught_up"}
                          class="flex-shrink-0"
                          title="Caught up"
                        >⚡</span>
                        <span
                          :if={row_event.(entry) == "started"}
                          class="flex-shrink-0"
                          title="Started"
                        >▶</span>
                        <span class="truncate max-w-[150px]">{entry.title}</span>
                      </span>
                      <span class={[
                        "tabular-nums",
                        if(row_event.(entry), do: "opacity-70", else: "text-base-content/50")
                      ]}>
                        <span :if={entry.chapters_read > 0}>{entry.chapters_read} ch · </span>{MangaHTML.format_reading_time(
                          entry.seconds
                        )}
                      </span>
                    </div>
                    <% event_only =
                      Enum.reject(day_events, fn {key, _} ->
                        Enum.any?(entries, fn e -> {e.source, e.slug} == key end)
                      end) %>
                    <div
                      :for={{key, ev} <- event_only}
                      class={[
                        "flex items-center gap-1 font-medium",
                        case ev do
                          "completed" -> "text-success"
                          "caught_up" -> "text-warning"
                          _ -> "text-info"
                        end
                      ]}
                    >
                      <span>{case ev do
                        "completed" -> "✓"
                        "caught_up" -> "⚡"
                        _ -> "▶"
                      end}</span>
                      <span class="truncate max-w-[150px]">{get_in(@manga_meta, [key, :title]) ||
                        elem(key, 1)}</span>
                    </div>
                    <div
                      :if={length(entries) > 1}
                      class="border-t border-base-content/10 mt-1 pt-1 flex justify-between gap-4 font-semibold"
                    >
                      <span>Total</span>
                      <span class="tabular-nums">{MangaHTML.format_reading_time(
                        Enum.sum(Enum.map(entries, & &1.seconds))
                      )}</span>
                    </div>
                    <div class="absolute top-full left-1/2 -translate-x-1/2 border-4 border-transparent border-t-base-300">
                    </div>
                  </div>
                </div>
              </div>
            </:day_cell>
          </.live_component>

          <%!-- Heatmap legend, ported from the dead view. Sits outside the
             calendar component (the library's own show_legend is for
             event layers, not intensity). --%>
          <div class="flex items-center justify-end gap-1 mt-3 text-[10px] text-base-content/50">
            <span>Less</span>
            <div class="w-[11px] h-[11px] rounded-sm bg-base-300"></div>
            <div class="w-[11px] h-[11px] rounded-sm bg-success/30"></div>
            <div class="w-[11px] h-[11px] rounded-sm bg-success/50"></div>
            <div class="w-[11px] h-[11px] rounded-sm bg-success/70"></div>
            <div class="w-[11px] h-[11px] rounded-sm bg-success"></div>
            <span>More</span>
          </div>
        </div>

        <h3 class="text-base font-semibold mb-3">
          {MangaHTML.selected_date_label(@selected_date)}
          <span
            :if={Date.compare(@selected_date, DateTime.to_date(@user_now)) == :eq}
            class="text-sm font-normal text-base-content/50"
          >
            {Calendar.strftime(@user_now, "%-I:%M %p")}
          </span>
        </h3>

        {time_of_day_card(assigns)}

        <%!-- Library milestones for the day: marked complete / caught up. --%>
        <div :if={@library_events != []} class="flex flex-col gap-2 mb-4">
          <div
            :for={ev <- @library_events}
            class="flex items-center gap-3 bg-base-200 rounded-xl px-4 py-2.5"
          >
            <span class={[
              "flex-shrink-0 text-lg",
              case ev.event do
                "completed" -> "text-success"
                "started" -> "text-info"
                _ -> "text-warning"
              end
            ]}>
              {case ev.event do
                "completed" -> "✓"
                "started" -> "▶"
                _ -> "⚡"
              end}
            </span>
            <div class="flex-1 min-w-0 text-sm">
              <span class="font-semibold">{case ev.event do
                "completed" -> "Completed"
                "started" -> "Started"
                _ -> "Caught up"
              end}</span>
              <span class="text-base-content/70 truncate">{ev.title || "#{ev.source}/#{ev.slug}"}</span>
            </div>
            <span class="text-xs text-base-content/40 flex-shrink-0">
              <span :if={ev.chapter}>ch {display_chapter(ev.chapter)} · </span>{MangaHTML.stint_local_time(
                ev.happened_at,
                @stint_tz
              )}
            </span>
            <div class="dropdown dropdown-end flex-shrink-0">
              <div
                tabindex="0"
                role="button"
                class="btn btn-ghost btn-xs btn-square"
                aria-label="Event options"
              >
                <.kebab />
              </div>
              <ul
                tabindex="0"
                class="dropdown-content menu bg-base-100 rounded-box z-40 w-48 p-2 shadow-lg"
              >
                <li>
                  <button
                    type="button"
                    class="text-error"
                    phx-click="remove_event"
                    phx-value-id={ev.id}
                    data-confirm={"Remove this #{event_label(ev.event)} event for #{ev.title || ev.slug}?"}
                  >
                    Remove this event
                  </button>
                </li>
              </ul>
            </div>
          </div>
        </div>

        <%= if @history != [] do %>
          <div class="flex flex-col gap-3">
            <div
              :for={manga <- @history}
              class="flex items-center gap-4 bg-base-200 rounded-xl p-3"
            >
              <a
                href={
                  if manga.last_chapter,
                    do: ~p"/manga/#{manga.source}/#{manga.slug}/#{manga.last_chapter}",
                    else: ~p"/manga/#{manga.source}/#{manga.slug}"
                }
                class="flex items-center gap-4 flex-1 min-w-0 hover:opacity-80 transition-opacity"
              >
                <img
                  :if={
                    src =
                      MangaHTML.history_cover_src(manga.source, manga.slug, @manga_meta, "small") ||
                        (manga.cover_url && ~p"/manga/proxy/image?#{%{url: manga.cover_url}}")
                  }
                  src={src}
                  alt={manga.title}
                  class="w-14 h-20 rounded-lg object-cover flex-shrink-0"
                />
                <div class="flex-1 min-w-0">
                  <p class="font-semibold truncate">{manga.title}</p>
                  <p :if={manga.last_chapter} class="text-sm text-base-content/60">
                    Chapter {manga.last_chapter}<span :if={manga.last_page}>, Page {manga.last_page}</span>
                  </p>
                  <p
                    :if={line = MangaHTML.history_stat_line(manga, @chapter_reads, @stints)}
                    class="text-xs text-base-content/40 mt-1"
                  >
                    {line}
                  </p>
                </div>
              </a>
              <div class="dropdown dropdown-end flex-shrink-0">
                <div
                  tabindex="0"
                  role="button"
                  class="btn btn-ghost btn-sm btn-square"
                  aria-label="Activity options"
                >
                  <.kebab />
                </div>
                <ul
                  tabindex="0"
                  class="dropdown-content menu bg-base-100 rounded-box z-40 w-56 p-2 shadow-lg"
                >
                  <li>
                    <button
                      type="button"
                      class="text-error"
                      phx-click="remove_activity"
                      phx-value-source={manga.source}
                      phx-value-slug={manga.slug}
                      data-confirm={"Remove all reading activity for #{manga.title} on this day?"}
                    >
                      Remove activity for this day
                    </button>
                  </li>
                </ul>
              </div>
            </div>
          </div>
        <% else %>
          <div class="text-center py-8">
            <p class="text-base-content/50 text-sm">No reading activity on this day.</p>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # The time-of-day card, ported from history.html.heex. Its interactive JS
  # (zoom, format switcher, live now-marker) runs as a colocated hook so it
  # survives LiveView DOM patches; date changes re-run relayout via updated().
  defp time_of_day_card(assigns) do
    ~H"""
    <% max_hour_seconds = @hourly_activity |> Enum.map(& &1.seconds) |> Enum.max(fn -> 0 end) %>
    <% has_multiple_hours = Enum.count(@hourly_activity, &(&1.seconds > 0)) > 1 %>
    <% avg_max = @hourly_averages |> Enum.map(& &1.avg_seconds) |> Enum.max(fn -> 0 end) %>
    <% show_hours = max_hour_seconds > 0 and has_multiple_hours %>
    <% show_avg = avg_max > 0 %>
    <% show_sessions = @stints != [] %>
    <% peak_hour = show_avg && Enum.max_by(@hourly_averages, & &1.avg_seconds) %>
    <div
      :if={show_hours or show_sessions or show_avg}
      class="bg-base-200 rounded-xl p-4 mb-4"
      id="timeday-card"
      phx-hook=".TimeDayCard"
      data-date={Date.to_iso8601(@selected_date)}
    >
      <div class="flex items-center justify-between gap-2 mb-3">
        <div class="text-xs text-base-content/50 truncate">
          <span :if={show_hours} class="timeday-title hidden" data-view="hours">
            {MangaHTML.selected_date_label(@selected_date)} by hour
          </span>
          <span :if={show_sessions} class="timeday-title hidden" data-view="sessions">
            Sessions <span class="badge badge-ghost badge-xs align-middle">beta</span>
          </span>
          <span :if={show_sessions} class="timeday-title hidden" data-view="clock">
            Session clock <span class="badge badge-ghost badge-xs align-middle">beta</span>
          </span>
          <span :if={show_avg} class="timeday-title hidden" data-view="avg">Avg. reading by hour</span>
          <span :if={show_avg} class="timeday-title hidden" data-view="avgclock">
            When you usually read<span :if={peak_hour && peak_hour.avg_seconds > 0}> · peak {String.pad_leading(
              Integer.to_string(peak_hour.hour),
              2,
              "0"
            )}:00</span>
          </span>
        </div>
        <div class="flex items-center gap-2 shrink-0">
          <div
            :if={show_sessions}
            id="stint-meta"
            class="flex items-center gap-2"
            style="display: none"
          >
            <div class="text-xs text-base-content/40">
              {length(@stints)} {if length(@stints) == 1, do: "session", else: "sessions"}
            </div>
            <div id="stint-zoomctl" class="flex items-center">
              <button
                type="button"
                id="stint-zoom-out"
                class="btn btn-ghost btn-xs w-6 px-0"
                aria-label="Zoom out"
              >−</button>
              <span
                id="stint-zoom-level"
                class="text-[10px] text-base-content/40 tabular-nums w-8 text-center"
              >1×</span>
              <button
                type="button"
                id="stint-zoom-in"
                class="btn btn-ghost btn-xs w-6 px-0"
                aria-label="Zoom in"
              >+</button>
            </div>
          </div>
          <div
            :if={
              if(show_hours, do: 1, else: 0) + if(show_sessions, do: 2, else: 0) +
                if(show_avg, do: 2, else: 0) > 1
            }
            class="join"
          >
            <button
              :if={show_hours}
              type="button"
              class="btn btn-xs join-item timeday-tab"
              data-view="hours"
            >Hours</button>
            <button
              :if={show_sessions}
              type="button"
              class="btn btn-xs join-item timeday-tab"
              data-view="sessions"
            >Sessions</button>
            <button
              :if={show_sessions}
              type="button"
              class="btn btn-xs join-item timeday-tab"
              data-view="clock"
            >Clock</button>
            <button
              :if={show_avg}
              type="button"
              class="btn btn-xs join-item timeday-tab"
              data-view="avg"
            >Avg</button>
            <button
              :if={show_avg}
              type="button"
              class="btn btn-xs join-item timeday-tab"
              data-view="avgclock"
            >Avg Clock</button>
          </div>
        </div>
      </div>

      <%!-- format: hour-by-hour bars for the selected day --%>
      <div :if={show_hours} class="timeday-view hidden" data-view="hours">
        <div class="flex items-end h-24">
          <div class="flex flex-col justify-between h-full text-[10px] text-base-content/50 pr-2 tabular-nums shrink-0 leading-none">
            <span>{MangaHTML.format_reading_time(max_hour_seconds)}</span>
            <span>{MangaHTML.format_reading_time(div(max_hour_seconds, 2))}</span>
            <span></span>
          </div>
          <div class="flex items-end gap-[3px] h-full flex-1">
            <div
              :for={h <- @hourly_activity}
              class="flex-1 flex flex-col items-center justify-end h-full relative group"
            >
              <div
                class={[
                  "w-full rounded-t-sm transition-colors",
                  if(h.seconds > 0, do: "bg-primary hover:bg-primary-focus", else: "bg-base-300")
                ]}
                style={
                  if h.seconds > 0,
                    do: "height: #{max(round(h.seconds / max_hour_seconds * 100), 4)}%",
                    else: "height: 4%"
                }
              >
              </div>
              <div
                :if={h.seconds > 0}
                class="absolute bottom-full left-1/2 -translate-x-1/2 mb-2 hidden group-hover:block z-50 pointer-events-none"
              >
                <div class="bg-base-300 border border-base-content/10 rounded-lg shadow-lg px-3 py-2 text-xs whitespace-nowrap">
                  <div class="font-semibold mb-1">
                    {h.hour |> Integer.to_string() |> String.pad_leading(2, "0")}:00 &ndash; {h.hour
                    |> Integer.to_string()
                    |> String.pad_leading(2, "0")}:59
                  </div>
                  <div
                    :for={entry <- h.entries}
                    class="flex justify-between gap-4 text-base-content/70"
                  >
                    <span class="truncate max-w-[150px]">{entry.title}</span>
                    <span class="text-base-content/50 tabular-nums">
                      <span :if={entry.chapters_read > 0}>{entry.chapters_read} ch · </span>{MangaHTML.format_reading_time(
                        entry.seconds
                      )}
                    </span>
                  </div>
                  <div
                    :if={length(h.entries) > 1}
                    class="border-t border-base-content/10 mt-1 pt-1 flex justify-between gap-4 font-semibold"
                  >
                    <span>Total</span>
                    <span class="tabular-nums">{MangaHTML.format_reading_time(h.seconds)}</span>
                  </div>
                  <div class="absolute top-full left-1/2 -translate-x-1/2 border-4 border-transparent border-t-base-300">
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
        <div class="flex gap-[3px] mt-1" style="padding-left: calc(2rem + 0.5rem)">
          <div :for={h <- @hourly_activity} class="flex-1 text-center">
            <span :if={h.hour in [0, 6, 12, 18]} class="text-[10px] text-base-content/50">{h.hour}</span>
          </div>
        </div>
      </div>

      <%!-- format: all-time average hourly heatmap --%>
      <div :if={show_avg} class="timeday-view hidden" data-view="avg">
        <div class="flex gap-[2px]">
          <div :for={h <- @hourly_averages} class="flex-1 relative group">
            <div class={[
              "h-6 rounded-sm w-full",
              cond do
                h.avg_seconds == 0 -> "bg-base-300"
                h.avg_seconds <= avg_max * 0.25 -> "bg-primary/25"
                h.avg_seconds <= avg_max * 0.50 -> "bg-primary/50"
                h.avg_seconds <= avg_max * 0.75 -> "bg-primary/75"
                true -> "bg-primary"
              end
            ]}>
            </div>
            <div
              :if={h.avg_seconds > 0}
              class="absolute bottom-full left-1/2 -translate-x-1/2 mb-2 hidden group-hover:block z-50 pointer-events-none"
            >
              <div class="bg-base-300 border border-base-content/10 rounded-lg shadow-lg px-3 py-2 text-xs whitespace-nowrap">
                <div class="font-semibold">
                  {String.pad_leading(Integer.to_string(h.hour), 2, "0")}:00
                </div>
                <div class="text-base-content/70">
                  avg {MangaHTML.format_reading_time(h.avg_seconds)}/day
                </div>
                <div class="absolute top-full left-1/2 -translate-x-1/2 border-4 border-transparent border-t-base-300">
                </div>
              </div>
            </div>
          </div>
        </div>
        <div class="flex gap-[2px] mt-1">
          <div :for={h <- @hourly_averages} class="flex-1 text-center">
            <span :if={h.hour in [0, 6, 12, 18]} class="text-[10px] text-base-content/50">{h.hour}</span>
          </div>
        </div>
      </div>

      <%!-- format: all-time average heatmap on one continuous 24h spiral. --%>
      <div :if={show_avg} class="timeday-view hidden" data-view="avgclock">
        <svg
          viewBox="0 0 240 240"
          class="mx-auto w-full max-w-xs"
          role="img"
          aria-label="Average reading by hour on a 24-hour spiral"
        >
          <line
            :for={i <- 0..11}
            x1="120"
            y1="17"
            x2="120"
            y2="55"
            transform={"rotate(#{i * 30} 120 120)"}
            stroke="var(--color-base-content)"
            stroke-opacity="0.08"
          />
          <path
            d={MangaHTML.clock_spiral_path(0, 86_400)}
            fill="none"
            stroke="var(--color-base-300)"
            stroke-opacity="0.6"
            stroke-width="11"
          />
          <path
            :for={seg <- MangaHTML.avg_clock_arcs(@hourly_averages, avg_max)}
            d={MangaHTML.clock_spiral_path(seg.start_sec, seg.end_sec)}
            fill="none"
            stroke="var(--color-primary)"
            stroke-opacity={seg.opacity}
            stroke-width="11"
          />
          <%= for h <- @hourly_averages, h.avg_seconds > 0 do %>
            <path
              d={MangaHTML.clock_spiral_path(h.hour * 3600, (h.hour + 1) * 3600)}
              fill="none"
              stroke="transparent"
              stroke-width="11"
            >
              <title>
                {String.pad_leading(Integer.to_string(h.hour), 2, "0")}:00 · avg {MangaHTML.format_reading_time(
                  h.avg_seconds
                )}/day
              </title>
            </path>
          <% end %>
          <text
            x="127"
            y="22"
            font-size="7"
            fill="var(--color-base-content)"
            fill-opacity="0.45"
            dominant-baseline="central"
          >
            00
          </text>
          <text
            x="127"
            y="37"
            font-size="7"
            fill="var(--color-base-content)"
            fill-opacity="0.45"
            dominant-baseline="central"
          >
            12
          </text>
          <text
            x="127"
            y="52"
            font-size="7"
            fill="var(--color-base-content)"
            fill-opacity="0.45"
            dominant-baseline="central"
          >
            24
          </text>
          <circle cx="120" cy="120" r="60" fill="var(--color-base-300)" fill-opacity="0.5" />
          <line
            :for={i <- 0..11}
            x1="120"
            y1="62"
            x2="120"
            y2="67"
            transform={"rotate(#{i * 30} 120 120)"}
            stroke="var(--color-base-content)"
            stroke-opacity="0.25"
          />
          <text
            :for={{n, x, y} <- [{"12", 120, 73}, {"3", 167, 120}, {"6", 120, 167}, {"9", 73, 120}]}
            x={x}
            y={y}
            font-size="10"
            fill="var(--color-base-content)"
            fill-opacity="0.5"
            text-anchor="middle"
            dominant-baseline="central"
          >
            {n}
          </text>
        </svg>
        <p
          :if={peak_hour && peak_hour.avg_seconds > 0}
          class="text-center text-xs text-base-content/50 mt-1"
        >
          You read most around {String.pad_leading(Integer.to_string(peak_hour.hour), 2, "0")}:00
          <span class="text-base-content/40">({MangaHTML.format_reading_time(peak_hour.avg_seconds)}/day)</span>
        </p>
      </div>

      <%!-- format: minute-resolution session timeline --%>
      <%= if show_sessions do %>
        <% stint_groups =
          @stints
          |> Enum.group_by(& &1.item)
          |> Enum.sort_by(
            fn {_item, sts} -> Enum.min_by(sts, & &1.started_at, DateTime).started_at end,
            DateTime
          ) %>
        <div class="timeday-view hidden" data-view="sessions">
          <div class="flex gap-2 mb-1">
            <div class="w-24 sm:w-40 shrink-0 flex flex-col gap-1.5">
              <div
                :for={{item, _sts} <- stint_groups}
                class="h-4 flex items-center text-[11px] truncate text-base-content/70"
                title={Map.get(@stint_titles, item, item)}
              >
                {Map.get(@stint_titles, item, String.replace_prefix(item, "manga:", ""))}
              </div>
              <div class="h-3"></div>
            </div>
            <div id="stint-scroll" class="flex-1 min-w-0 overflow-x-auto overflow-y-hidden">
              <div id="stint-zoom" class="flex flex-col gap-1.5" style="width: 100%">
                <div
                  :for={{_item, sts} <- stint_groups}
                  class="relative h-4 rounded bg-base-300/60 overflow-hidden"
                >
                  <div
                    :for={s <- sts}
                    class="stint-bar absolute top-0.5 bottom-0.5 rounded-sm bg-primary/80 overflow-hidden"
                    style={MangaHTML.stint_bar_style(s, @selected_date, @stint_tz)}
                    data-t1={MangaHTML.stint_local_time(s.started_at, @stint_tz)}
                    data-t2={MangaHTML.stint_local_time(s.ended_at, @stint_tz)}
                    data-dur={MangaHTML.format_reading_time(s.seconds) || "<1m"}
                    title={"#{MangaHTML.stint_local_time(s.started_at, @stint_tz)}–#{MangaHTML.stint_local_time(s.ended_at, @stint_tz)} · #{MangaHTML.format_reading_time(s.seconds) || "<1m"}"}
                  >
                    <span class="stint-bar-label hidden absolute inset-0 flex items-center px-1 text-[9px] leading-none whitespace-nowrap text-primary-content/90"></span>
                  </div>
                </div>
                <div class="relative h-3">
                  <span
                    :for={h <- 0..24}
                    class={"stint-hour absolute text-[9px] text-base-content/40 tabular-nums whitespace-nowrap #{if h == 24, do: "-translate-x-full"} #{if h not in [0, 6, 12, 18, 24], do: "hidden"}"}
                    style={"left: #{h / 24 * 100}%"}
                    data-h={h}
                  >
                    {h}
                  </span>
                  <div class="stint-now hidden absolute inset-y-0 w-px bg-error"></div>
                </div>
              </div>
            </div>
          </div>

          <div class="flex flex-col gap-1 border-t border-base-content/10 pt-2">
            <div :for={s <- @stints} class="flex items-baseline gap-2 text-xs">
              <span class="tabular-nums text-base-content/70 shrink-0">
                {MangaHTML.stint_local_time(s.started_at, @stint_tz)}–{MangaHTML.stint_local_time(
                  s.ended_at,
                  @stint_tz
                )}
              </span>
              <span class="text-base-content/50 shrink-0">{MangaHTML.format_reading_time(s.seconds) ||
                "<1m"}</span>
              <span class="truncate text-base-content/60">
                {Map.get(@stint_titles, s.item, String.replace_prefix(s.item, "manga:", ""))}
                <% read = MangaHTML.chapters_in_stint(@chapter_reads, s) %>
                <span :if={read != []} class="text-success/80">· read ch {Enum.join(read, ", ")}</span>
                <span :if={read == [] and s.meta["chapter"]} class="text-base-content/40">· ch {s.meta[
                  "chapter"
                ]}</span>
              </span>
            </div>
          </div>
        </div>
      <% end %>

      <%!-- format: session clock — 24h spiral around the analog clock. --%>
      <div :if={show_sessions} class="timeday-view hidden" data-view="clock">
        <svg
          viewBox="0 0 240 240"
          class="mx-auto w-full max-w-xs"
          role="img"
          aria-label="Reading sessions on a 24-hour spiral"
        >
          <line
            :for={i <- 0..11}
            x1="120"
            y1="17"
            x2="120"
            y2="55"
            transform={"rotate(#{i * 30} 120 120)"}
            stroke="var(--color-base-content)"
            stroke-opacity="0.08"
          />
          <path
            d={MangaHTML.clock_spiral_path(0, 86_400)}
            fill="none"
            stroke="var(--color-base-300)"
            stroke-opacity="0.6"
            stroke-width="11"
          />
          <%= for s <- @stints, span <- [MangaHTML.stint_day_seconds(s, @selected_date, @stint_tz)], span != nil do %>
            <path
              d={MangaHTML.clock_spiral_path(elem(span, 0), elem(span, 1))}
              fill="none"
              stroke="var(--color-primary)"
              stroke-opacity="0.85"
              stroke-width="9"
              stroke-linecap="butt"
            >
              <title>
                {Map.get(@stint_titles, s.item, String.replace_prefix(s.item, "manga:", ""))} · {MangaHTML.stint_local_time(
                  s.started_at,
                  @stint_tz
                )}–{MangaHTML.stint_local_time(s.ended_at, @stint_tz)} · {MangaHTML.format_reading_time(
                  s.seconds
                ) || "<1m"}
              </title>
            </path>
          <% end %>
          <text
            x="127"
            y="22"
            font-size="7"
            fill="var(--color-base-content)"
            fill-opacity="0.45"
            dominant-baseline="central"
          >
            00
          </text>
          <text
            x="127"
            y="37"
            font-size="7"
            fill="var(--color-base-content)"
            fill-opacity="0.45"
            dominant-baseline="central"
          >
            12
          </text>
          <text
            x="127"
            y="52"
            font-size="7"
            fill="var(--color-base-content)"
            fill-opacity="0.45"
            dominant-baseline="central"
          >
            24
          </text>
          <line
            id="clock-now"
            stroke="var(--color-error)"
            stroke-width="2"
            stroke-linecap="round"
            display="none"
          />
          <circle cx="120" cy="120" r="60" fill="var(--color-base-300)" fill-opacity="0.5" />
          <line
            :for={i <- 0..11}
            x1="120"
            y1="62"
            x2="120"
            y2="67"
            transform={"rotate(#{i * 30} 120 120)"}
            stroke="var(--color-base-content)"
            stroke-opacity="0.25"
          />
          <text
            :for={{n, x, y} <- [{"12", 120, 73}, {"3", 167, 120}, {"6", 120, 167}, {"9", 73, 120}]}
            x={x}
            y={y}
            font-size="10"
            fill="var(--color-base-content)"
            fill-opacity="0.5"
            text-anchor="middle"
            dominant-baseline="central"
          >
            {n}
          </text>
          <line
            id="clock-hand-h"
            x1="120"
            y1="126"
            x2="120"
            y2="92"
            stroke="var(--color-base-content)"
            stroke-opacity="0.75"
            stroke-width="3.5"
            stroke-linecap="round"
          />
          <line
            id="clock-hand-m"
            x1="120"
            y1="128"
            x2="120"
            y2="76"
            stroke="var(--color-base-content)"
            stroke-opacity="0.55"
            stroke-width="2.5"
            stroke-linecap="round"
          />
          <circle cx="120" cy="120" r="3" fill="var(--color-base-content)" fill-opacity="0.75" />
        </svg>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".TimeDayCard">
        export default {
          mounted() {
            this.setup();
            this.applyView();
          },
          updated() {
            // date changed: re-fit the (possibly new) bars and re-assert the view
            this.relayout && this.relayout();
            this.applyView();
          },
          destroyed() {
            if (this._timer) clearInterval(this._timer);
          },
          setup() {
            const card = this.el;
            const scroll = card.querySelector("#stint-scroll");
            const zoomEl = card.querySelector("#stint-zoom");
            const levelEl = card.querySelector("#stint-zoom-level");
            const MAX_ZOOM = 64;
            let zoom = 1;

            const relayout = () => {
              if (!zoomEl) return;
              const pxPerHour = zoomEl.offsetWidth / 24;
              const step = [1, 2, 3, 6].find((s) => s * pxPerHour >= 40) || 6;
              zoomEl.querySelectorAll(".stint-hour").forEach((el) => {
                const h = +el.dataset.h;
                el.classList.toggle("hidden", h % step !== 0);
                el.textContent = step === 1 ? h + ":00" : h;
              });
              zoomEl.querySelectorAll(".stint-bar").forEach((bar) => {
                const label = bar.querySelector(".stint-bar-label");
                const w = bar.offsetWidth;
                const d = bar.dataset;
                let text = null;
                if (w >= 130) text = d.t1 + "–" + d.t2 + " · " + d.dur;
                else if (w >= 76) text = d.t1 + "–" + d.t2;
                else if (w >= 34) text = d.t1;
                label.classList.toggle("hidden", !text);
                if (text) label.textContent = text;
              });
            };
            this.relayout = relayout;

            const setZoom = (next, anchorClientX) => {
              next = Math.min(MAX_ZOOM, Math.max(1, next));
              if (next === zoom) return;
              const rect = scroll.getBoundingClientRect();
              const anchor = anchorClientX == null ? rect.width / 2 : anchorClientX - rect.left;
              const frac = (scroll.scrollLeft + anchor) / zoomEl.offsetWidth;
              zoom = next;
              zoomEl.style.width = zoom * 100 + "%";
              scroll.scrollLeft = frac * zoomEl.offsetWidth - anchor;
              levelEl.textContent = zoom + "×";
              relayout();
            };

            // delegated clicks: format tabs + zoom buttons (survive patches)
            card.addEventListener("click", (e) => {
              const tab = e.target.closest(".timeday-tab");
              if (tab) {
                this.applyView(tab.dataset.view);
                try { localStorage.setItem("reader-history-timeview", tab.dataset.view); } catch (_e) {}
                return;
              }
              if (e.target.closest("#stint-zoom-in")) setZoom(zoom * 2);
              else if (e.target.closest("#stint-zoom-out")) setZoom(zoom / 2);
            });

            if (scroll) {
              scroll.addEventListener("wheel", (e) => {
                if (!e.ctrlKey) return;
                e.preventDefault();
                setZoom(e.deltaY < 0 ? zoom * 2 : zoom / 2, e.clientX);
              }, { passive: false });
            }

            const tickNow = () => {
              const now = new Date();
              const localDate =
                now.getFullYear() + "-" +
                String(now.getMonth() + 1).padStart(2, "0") + "-" +
                String(now.getDate()).padStart(2, "0");
              const isToday = card.dataset.date === localDate;
              const frac = (now.getHours() * 3600 + now.getMinutes() * 60 + now.getSeconds()) / 86400;
              card.querySelectorAll(".stint-now").forEach((el) => {
                el.classList.toggle("hidden", !isToday);
                el.style.left = frac * 100 + "%";
              });
              const handH = card.querySelector("#clock-hand-h");
              const handM = card.querySelector("#clock-hand-m");
              const clockNow = card.querySelector("#clock-now");
              if (handH && handM) {
                const hDeg = ((now.getHours() % 12) + now.getMinutes() / 60) * 30;
                const mDeg = now.getMinutes() * 6 + now.getSeconds() * 0.1;
                handH.setAttribute("transform", "rotate(" + hDeg + " 120 120)");
                handM.setAttribute("transform", "rotate(" + mDeg + " 120 120)");
              }
              if (clockNow) {
                const angle = frac * Math.PI * 4 - Math.PI / 2;
                const radius = 98 - 30 * frac;
                const point = (r, axis) => 120 + r * (axis === "x" ? Math.cos(angle) : Math.sin(angle));
                clockNow.setAttribute("x1", point(radius - 7, "x"));
                clockNow.setAttribute("y1", point(radius - 7, "y"));
                clockNow.setAttribute("x2", point(radius + 7, "x"));
                clockNow.setAttribute("y2", point(radius + 7, "y"));
                clockNow.setAttribute("display", isToday ? "" : "none");
              }
            };
            this._tickNow = tickNow;
            tickNow();
            this._timer = setInterval(tickNow, 30000);
          },
          applyView(v) {
            const card = this.el;
            const views = Array.from(card.querySelectorAll(".timeday-view"));
            const names = views.map((el) => el.dataset.view);
            if (v == null) {
              try { v = localStorage.getItem("reader-history-timeview"); } catch (_e) {}
            }
            if (!names.includes(v)) v = names[0];
            this.current = v;
            views.forEach((el) => el.classList.toggle("hidden", el.dataset.view !== v));
            card.querySelectorAll(".timeday-tab").forEach((el) => el.classList.toggle("btn-active", el.dataset.view === v));
            card.querySelectorAll(".timeday-title").forEach((el) => el.classList.toggle("hidden", el.dataset.view !== v));
            const meta = card.querySelector("#stint-meta");
            if (meta) meta.style.display = v === "sessions" || v === "clock" ? "" : "none";
            const zoomctl = card.querySelector("#stint-zoomctl");
            if (zoomctl) zoomctl.style.display = v === "sessions" ? "" : "none";
            if (v === "sessions" && this.relayout) this.relayout();
          }
        }
      </script>
    </div>
    """
  end
end
