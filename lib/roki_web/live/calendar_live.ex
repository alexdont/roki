defmodule RokiWeb.CalendarLive do
  @moduledoc """
  `/:username/calendar` — when the things on this user's Saved list drop: episodes
  of shows and anime, and films reaching theaters or digital. A month at a time,
  this month by default, so what has just dropped and what is coming are on one
  page; below the grid, the month as an agenda, each line a poster, a title and
  how far away (or how long ago) it is.

  Built from `Roki.Calendar`, which fetches a title's whole schedule once and
  shares it (six hours) between everyone who saved it.
  """
  use RokiWeb, :live_view

  import RokiWeb.UserTabs

  alias Roki.Calendar, as: Cal

  @impl true
  def mount(%{"username" => username}, _session, socket) do
    case RokiWeb.UserGuard.check(socket, username) do
      {:redirect, to} ->
        {:ok, push_navigate(socket, to: to)}

      {:ok, uuid} ->
        client = RokiWeb.Client.key(socket, uuid)

        socket =
          socket
          |> assign(:page_title, "Calendar")
          |> assign(:username, username)
          |> assign(:uuid, uuid)
          |> assign(:state, :loading)
          |> assign(:data, nil)
          |> assign(:month, month_of(Date.utc_today()))
          |> assign(:selected, nil)

        {:ok,
         if(connected?(socket),
           do: start_async(socket, :calendar, fn -> load(client, uuid) end),
           else: socket
         )}
    end
  end

  defp load(client, uuid) do
    if Roki.Laev.connected?(uuid), do: Cal.load(client, uuid), else: :not_connected
  end

  defp month_of(%Date{year: y, month: m}), do: Date.new!(y, m, 1)

  @impl true
  def handle_params(params, _uri, socket) do
    month =
      with m when is_binary(m) <- params["m"],
           {:ok, date} <- Date.from_iso8601(m <> "-01") do
        date
      else
        _ -> month_of(Date.utc_today())
      end

    {:noreply, assign(socket, month: month, selected: nil)}
  end

  @impl true
  def handle_event("select", %{"date" => date}, socket) do
    selected =
      case Date.from_iso8601(date) do
        {:ok, d} when d != socket.assigns.selected -> d
        _ -> nil
      end

    {:noreply, assign(socket, :selected, selected)}
  end

  @impl true
  def handle_async(:calendar, {:ok, {:ok, data}}, socket),
    do: {:noreply, assign(socket, state: :ready, data: data)}

  def handle_async(:calendar, {:ok, :not_connected}, socket),
    do: {:noreply, assign(socket, :state, :not_connected)}

  def handle_async(:calendar, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, :state, {:error, reason})}

  def handle_async(:calendar, {:exit, reason}, socket),
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
      current_path={"/#{@username}/calendar"}
    >
      <div class="space-y-6">
        <.user_tabs username={@username} active={:calendar} />

        <div
          :if={@state == :loading}
          class="flex flex-col items-center gap-3 py-24 text-center text-base-content/60"
        >
          <span class="loading loading-spinner"></span>
          <span>Checking release dates for your Saved list…</span>
          <span class="max-w-sm text-sm">The first visit looks each title up; after that it's instant.</span>
        </div>

        <div :if={@state == :not_connected} class="alert">
          <span>Connect laev on your shelf, then save titles to see when they drop.</span>
          <.link navigate={~p"/#{@username}/home"} class="btn btn-sm">Go to your shelf</.link>
        </div>
        <p :if={match?({:error, {:rate_limited, _}}, @state)} class="alert alert-warning text-sm">
          You're loading the calendar a little fast — try again in a few seconds.
        </p>
        <p
          :if={
            match?({:error, r} when r != :no_tmdb_key, @state) and
              not match?({:error, {:rate_limited, _}}, @state)
          }
          class="alert alert-error text-sm"
        >
          Couldn't reach the release-date sources just now. Try again in a minute.
        </p>
        <p :if={@state == {:error, :no_tmdb_key}} class="alert text-sm">
          The calendar needs your TMDB key — connect laev and bring your API keys.
        </p>

        <div :if={@state == :ready} class="space-y-8">
          <div class="flex items-center gap-2">
            <.link
              patch={month_path(@username, Date.shift(@month, month: -1))}
              class="btn btn-sm btn-square"
              aria-label="Previous month"
            >
              <.icon name="hero-chevron-left" class="h-4 w-4" />
            </.link>
            <h1 class="flex-1 text-center text-xl font-bold tracking-tight sm:text-2xl">
              {Calendar.strftime(@month, "%B %Y")}
            </h1>
            <.link
              patch={month_path(@username, Date.shift(@month, month: 1))}
              class="btn btn-sm btn-square"
              aria-label="Next month"
            >
              <.icon name="hero-chevron-right" class="h-4 w-4" />
            </.link>
            <.link patch={~p"/#{@username}/calendar"} class="btn btn-sm">Today</.link>
          </div>

          <p :if={@data.saved == %{}} class="py-10 text-center text-base-content/60">
            Nothing saved yet. Save titles (ctrl-s in laev) and their release dates appear here.
          </p>

          <div :if={@data.saved != %{}} class="space-y-8">
            <.grid cells={@cells} selected={@selected} today={@today} />

            <section class="space-y-3">
              <div class="flex items-center gap-3">
                <h2 class="flex-1 text-xl font-semibold">
                  {if @selected, do: Calendar.strftime(@selected, "%A, %B %-d"), else: "This month"}
                </h2>
                <button
                  :if={@selected}
                  phx-click="select"
                  phx-value-date={@selected}
                  class="btn btn-xs btn-ghost"
                >
                  Show whole month
                </button>
              </div>

              <p :if={@agenda == []} class="py-6 text-center text-base-content/60">
                Nothing {if @selected, do: "on this day", else: "dropping this month"}.
              </p>

              <ul class="divide-y divide-base-300">
                <li
                  :for={e <- @agenda}
                  class={[
                    "flex items-center gap-3 py-3",
                    Date.compare(e.date, @today) == :lt && "opacity-60"
                  ]}
                >
                  <.thumb poster={@data.saved[{e.type, e.id}][:poster]} title={e.title} />
                  <div class="min-w-0 flex-1">
                    <div class="truncate font-medium" title={e.label}>{e.label}</div>
                    <div class="text-sm text-base-content/60">
                      {Calendar.strftime(e.date, "%a %b %-d")} · {when_text(e.date, @today)}
                    </div>
                  </div>
                  <span class={["badge badge-sm shrink-0", kind_class(e)]}>{kind_text(e)}</span>
                </li>
              </ul>
            </section>

            <section :if={@data.waiting != []} class="space-y-3">
              <h2 class="text-xl font-semibold">Waiting on a date</h2>
              <ul class="divide-y divide-base-300">
                <li :for={e <- @data.waiting} class="flex items-center gap-3 py-3">
                  <.thumb poster={@data.saved[{e.type, e.id}][:poster]} title={e.title} />
                  <div class="min-w-0 flex-1 truncate" title={e.label}>{e.label}</div>
                </li>
              </ul>
            </section>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp assign_view(%{state: :ready, data: data, month: month, selected: selected} = assigns) do
    today = Date.utc_today()
    by_date = Enum.group_by(data.events, & &1.date)

    in_month =
      Enum.filter(data.events, &(&1.date.year == month.year and &1.date.month == month.month))

    agenda = if selected, do: Map.get(by_date, selected, []), else: in_month

    assign(assigns, today: today, agenda: agenda, cells: cells(month, by_date))
  end

  defp assign_view(assigns), do: assign(assigns, today: Date.utc_today(), agenda: [], cells: [])

  # Weeks, Monday first, covering the whole month: [[{date, in_month?, events}]].
  defp cells(month, by_date) do
    first = Date.beginning_of_month(month)
    start = Date.add(first, -(Date.day_of_week(first) - 1))
    last = Date.end_of_month(month)
    weeks = div(Date.diff(last, start), 7) + 1

    for w <- 0..(weeks - 1) do
      for d <- 0..6 do
        date = Date.add(start, w * 7 + d)
        {date, date.month == month.month, Map.get(by_date, date, [])}
      end
    end
  end

  attr :cells, :list, required: true
  attr :selected, :any, default: nil
  attr :today, :any, required: true

  defp grid(assigns) do
    ~H"""
    <div>
      <div class="grid grid-cols-7 gap-1 pb-1 text-center text-xs text-base-content/50">
        <span :for={d <- ~w(Mon Tue Wed Thu Fri Sat Sun)}>{d}</span>
      </div>
      <div class="grid grid-cols-7 gap-1">
        <%= for week <- @cells, {date, in_month?, events} <- week do %>
          <button
            type="button"
            phx-click="select"
            phx-value-date={date}
            disabled={events == []}
            class={[
              "flex min-h-14 flex-col items-center rounded-lg p-1 text-sm transition sm:min-h-20 sm:items-start sm:p-2",
              in_month? && "bg-base-200",
              !in_month? && "opacity-30",
              events != [] && "cursor-pointer hover:bg-base-300",
              @selected == date && "ring-2 ring-primary",
              date == @today && "border border-primary"
            ]}
          >
            <span class={["font-medium", date == @today && "text-primary"]}>{date.day}</span>
            <%!-- A phone has room for dots; wider screens get the first title too. --%>
            <span :if={events != []} class="mt-1 flex flex-wrap justify-center gap-0.5 sm:hidden">
              <span :for={e <- Enum.take(events, 4)} class={["h-1.5 w-1.5 rounded-full", dot(e)]}></span>
            </span>
            <span
              :if={events != []}
              class="mt-1 hidden w-full space-y-0.5 text-left text-[11px] leading-tight sm:block"
            >
              <span :for={e <- Enum.take(events, 2)} class="block truncate" title={e.label}>{e.title}</span>
              <span :if={length(events) > 2} class="block text-base-content/50">+{length(events) - 2} more</span>
            </span>
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  attr :poster, :any, default: nil
  attr :title, :string, required: true

  defp thumb(assigns) do
    ~H"""
    <div class="h-14 w-10 shrink-0 overflow-hidden rounded bg-base-300">
      <img :if={@poster} src={@poster} alt={@title} loading="lazy" class="h-full w-full object-cover" />
    </div>
    """
  end

  defp month_path(username, date),
    do: ~p"/#{username}/calendar?#{[m: Calendar.strftime(date, "%Y-%m")]}"

  defp when_text(date, today) do
    diff = Date.diff(date, today)
    if diff < 0, do: "dropped #{Cal.relative(diff)}", else: "drops #{Cal.relative(diff)}"
  end

  defp kind_text(%{kind: :episode, anime: true}), do: "Anime"
  defp kind_text(%{kind: :episode}), do: "Episode"
  defp kind_text(%{kind: :digital}), do: "Digital"
  defp kind_text(%{kind: :theatrical}), do: "Theatrical"

  defp kind_class(%{kind: :episode, anime: true}), do: "badge-secondary"
  defp kind_class(%{kind: :episode}), do: "badge-primary"
  defp kind_class(%{kind: :digital}), do: "badge-success"
  defp kind_class(%{kind: :theatrical}), do: "badge-info"

  defp dot(%{kind: :episode, anime: true}), do: "bg-secondary"
  defp dot(%{kind: :episode}), do: "bg-primary"
  defp dot(%{kind: :digital}), do: "bg-success"
  defp dot(%{kind: :theatrical}), do: "bg-info"
end
