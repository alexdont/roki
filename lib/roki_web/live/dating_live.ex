defmodule RokiWeb.DatingLive do
  @moduledoc """
  `/:username/dating` — the owner's dating assistant, for a list whose dates are mostly the day it
  was imported.

  A catalogue brought across from IMDb or elsewhere arrives with one day on hundreds of titles,
  which is when it was added, not when anything was watched. Those titles are the *pool*: the ones
  with no date, and the ones whose date is a day with an implausible pile-up (`@bulk_day`). A title
  in the pool cannot have been watched after the day it was imported, nor before it came out, nor
  before its watcher was old enough (the birth year and `@first_age`), and the page uses all three:

  * a year to *sweep up to* — only titles released by then are shown, so the pool grows year by
    year as the sweep moves on, and what has been placed leaves it;
  * a title that came out in 2011 is shown above one from 1985: what came out lately was most
    likely seen lately;
  * a year (and, if known, a month) to put a ticked block in, between the earliest and the latest
    that could be true for all of it. Without a month it is put in the middle of the year.

  Nothing here is linked from the site yet: it is a page to try. A title put on a day goes through
  `Roki.Profile.set_watched_at/3`, like the watched page's own date editor.
  """
  use RokiWeb, :live_view

  import RokiWeb.PageHero
  import RokiWeb.PosterComponents

  alias PhoenixKit.Users.Auth.Scope
  alias Roki.Profile

  # A day with this many titles on it is an import, not a day of watching.
  @bulk_day 40
  # How old someone is before the first thing they watched that they remember.
  @first_age 5
  @per_page 60
  @months ~w(January February March April May June July August September October November December)

  @impl true
  def mount(%{"username" => username}, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    viewer = if scope && Scope.authenticated?(scope), do: Scope.user_uuid(scope)
    user = Profile.user(username)

    if user == nil or viewer != user.uuid do
      {:ok, push_navigate(socket, to: "/#{username}/watched")}
    else
      socket =
        assign(socket,
          page_title: "Dating assistant",
          user: user,
          username: user.username,
          uuid: user.uuid,
          history: nil,
          born: nil,
          up_to: 2010,
          kind: :all,
          selected: MapSet.new(),
          placed: MapSet.new(),
          skipped: MapSet.new(),
          shown: @per_page,
          year: nil,
          month: "mid",
          notice: nil,
          error: nil
        )

      {:ok,
       if(connected?(socket),
         do: start_async(socket, :history, fn -> Profile.history_all(user.uuid) end),
         else: socket
       )}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    this_year = Date.utc_today().year

    {:noreply,
     assign(socket,
       born: int(params["born"], 1920, this_year),
       up_to: int(params["up_to"], 1900, this_year) || socket.assigns.up_to,
       kind:
         Profile.kind(params["kind"])
         |> then(&if(&1 in [:all, :movie, :tv, :anime], do: &1, else: :all)),
       shown: @per_page
     )}
  end

  defp int(value, min, max) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n >= min and n <= max -> n
      _ -> nil
    end
  end

  @impl true
  def handle_async(:history, {:ok, items}, socket) when is_list(items),
    do: {:noreply, assign(socket, :history, items)}

  def handle_async(:history, _other, socket), do: {:noreply, assign(socket, :history, [])}

  # ── events ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("set", params, socket) do
    {:noreply,
     push_patch(socket,
       to:
         address(socket.assigns,
           born: int(params["born"], 1920, Date.utc_today().year),
           up_to: int(params["up_to"], 1900, Date.utc_today().year) || socket.assigns.up_to,
           kind: Profile.kind(params["kind"])
         ),
       replace: true
     )}
  end

  def handle_event("toggle", %{"key" => key}, socket) do
    sel = socket.assigns.selected

    {:noreply,
     assign(socket,
       selected:
         if(MapSet.member?(sel, key), do: MapSet.delete(sel, key), else: MapSet.put(sel, key)),
       error: nil
     )}
  end

  def handle_event("select_all", _params, socket),
    do:
      {:noreply,
       assign(socket, selected: MapSet.new(Enum.map(visible(socket.assigns), & &1.key)))}

  def handle_event("select_none", _params, socket),
    do: {:noreply, assign(socket, selected: MapSet.new(), error: nil)}

  def handle_event("more", _params, socket),
    do: {:noreply, update(socket, :shown, &(&1 + @per_page))}

  def handle_event("form", params, socket),
    do:
      {:noreply,
       assign(socket,
         year: int(params["year"], 1900, Date.utc_today().year),
         month: if(params["month"] in ["mid" | @months], do: params["month"], else: "mid")
       )}

  # Put the ticked titles in the chosen year (and month).
  def handle_event("place", params, socket) do
    a = socket.assigns
    chosen = Enum.filter(pool(a), &MapSet.member?(a.selected, &1.key))
    {lo, hi} = window(chosen, a)
    year = int(params["year"], 1900, Date.utc_today().year)
    month = params["month"] || "mid"

    cond do
      chosen == [] ->
        {:noreply, socket}

      year == nil or year < lo or year > hi ->
        {:noreply, assign(socket, error: "Pick a year between #{lo} and #{hi} for these.")}

      true ->
        date = date_for(year, month)
        {:ok, n} = Profile.set_watched_at(a.uuid, Enum.map(chosen, & &1.key), date)

        {:noreply,
         assign(socket,
           placed: MapSet.union(a.placed, MapSet.new(Enum.map(chosen, & &1.key))),
           selected: MapSet.new(),
           error: nil,
           notice:
             "#{n} #{if n == 1, do: "title", else: "titles"} put in #{label_date(year, month)}."
         )}
    end
  end

  # "I can't tell": leaves the ticked titles as they are and out of the list for this visit.
  def handle_event("skip", _params, socket) do
    a = socket.assigns

    {:noreply,
     assign(socket,
       skipped: MapSet.union(a.skipped, a.selected),
       selected: MapSet.new(),
       notice: "#{MapSet.size(a.selected)} left as they were."
     )}
  end

  # ── what is in the pool ────────────────────────────────────────────

  # `[%{... , bound: Date}]`: the titles whose date cannot be trusted, each with the latest day it
  # can have been watched.
  defp pool(%{history: items} = a) when is_list(items) do
    today = Date.utc_today()

    bulk =
      items
      |> Enum.filter(& &1.dated?)
      |> Enum.frequencies_by(&DateTime.to_date(DateTime.from_unix!(&1.at)))
      |> Enum.filter(fn {_day, n} -> n >= @bulk_day end)
      |> Map.new()

    for i <- items,
        not MapSet.member?(a.placed, i.key),
        bound = bound_of(i, bulk, today),
        bound != nil do
      Map.put(i, :bound, bound)
    end
  end

  defp pool(_), do: []

  defp bound_of(%{dated?: false}, _bulk, today), do: today

  defp bound_of(%{dated?: true, at: at}, bulk, _today) do
    day = DateTime.to_date(DateTime.from_unix!(at))
    if Map.has_key?(bulk, day), do: day
  end

  defp release_year(%{year: y}) when is_integer(y), do: y

  defp release_year(%{year: y}) when is_binary(y) do
    case Integer.parse(y) do
      {n, _} when n > 1800 -> n
      _ -> nil
    end
  end

  defp release_year(_), do: nil

  # The pool as the controls ask for it: released by the year swept up to, of the kind, not set
  # aside, newest release first (titles with no year last).
  defp visible(a) do
    pool(a)
    |> Profile.arrange(%{}, a.kind, :latest)
    |> Enum.reject(&MapSet.member?(a.skipped, &1.key))
    |> Enum.filter(fn i -> (release_year(i) || 0) <= a.up_to end)
    |> Enum.sort_by(
      &{if(release_year(&1), do: 0, else: 1), -(release_year(&1) || 0), &1.title || ""}
    )
  end

  # The years a ticked block can be put in: no earlier than the latest release of any of it (or
  # than the year its watcher was old enough), no later than the earliest import day among it.
  defp window(chosen, a) do
    lo =
      chosen
      |> Enum.map(&(release_year(&1) || 0))
      |> Enum.max(fn -> 0 end)
      |> max(if(a.born, do: a.born + @first_age, else: 1900))

    hi = chosen |> Enum.map(& &1.bound.year) |> Enum.min(fn -> Date.utc_today().year end)
    {lo, max(hi, lo)}
  end

  defp date_for(year, "mid"), do: Date.new!(year, 6, 30) |> clamp()

  defp date_for(year, month) do
    n = Enum.find_index(@months, &(&1 == month)) + 1
    Date.new!(year, n, 15) |> clamp()
  end

  # Never a day that has not happened.
  defp clamp(date),
    do: if(Date.compare(date, Date.utc_today()) == :gt, do: Date.utc_today(), else: date)

  defp label_date(year, "mid"), do: "#{year}"
  defp label_date(year, month), do: "#{month} #{year}"

  defp address(a, overrides) do
    v = Map.merge(%{born: a.born, up_to: a.up_to, kind: a.kind}, Map.new(overrides))

    query =
      [
        if(v.born, do: {:born, v.born}),
        {:up_to, v.up_to},
        if(v.kind != :all, do: {:kind, v.kind})
      ]
      |> Enum.reject(&is_nil/1)

    "/#{a.username}/dating?" <> URI.encode_query(query)
  end

  defp import_day(%{bound: bound, dated?: true}), do: Calendar.strftime(bound, "%-d %b %Y")
  defp import_day(_), do: "no date"

  # ── view ───────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    pool = pool(assigns)
    items = visible(assigns)
    chosen = Enum.filter(pool, &MapSet.member?(assigns.selected, &1.key))
    this_year = Date.utc_today().year

    assigns =
      assign(assigns,
        pool_size: length(pool),
        items: items,
        shown_items: Enum.take(items, assigns.shown),
        chosen: chosen,
        window: if(chosen == [], do: nil, else: window(chosen, assigns)),
        this_year: this_year,
        months: @months,
        min_year: (assigns.born || 1940) + @first_age
      )

    ~H"""
    <Layouts.app
      socket={@socket}
      flash={@flash}
      flush
      bleed
      overlay
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path={"/#{@username}/dating"}
    >
      <.page_hero eyebrow="Try-out page" title="Dating assistant" hue={200}>
        <p class="max-w-2xl text-white/80">
          Put the titles of an imported list back where they were watched. Slide to a year: only what
          had come out by then is here. Tick what belongs to that time and give it a year.
        </p>
      </.page_hero>

      <div class={[content_class(), @chosen != [] && "pb-40"]}>
        <p :if={@history == nil} class="text-base-content/60">
          <span class="loading loading-spinner loading-sm"></span> Reading your list…
        </p>

        <div :if={@history != nil} class="space-y-5">
          <form
            id="sweep-form"
            phx-change="set"
            class="sticky top-14 z-30 -mx-4 flex flex-wrap items-center gap-x-6 gap-y-3 border-b border-base-300/60 bg-base-100/95 px-4 py-3 sm:-mx-6 sm:px-6 lg:-mx-12 lg:px-12 xl:-mx-16 xl:px-16"
          >
            <label class="flex items-center gap-2 text-sm">
              <span class="font-medium">Born</span>
              <input
                type="number"
                name="born"
                value={@born}
                min="1920"
                max={@this_year}
                placeholder="year"
                phx-debounce="500"
                class="input input-bordered input-sm w-24"
              />
            </label>
            <label class="flex min-w-[16rem] flex-1 items-center gap-3 text-sm">
              <span class="whitespace-nowrap font-medium">Up to</span>
              <input
                type="range"
                name="up_to"
                value={@up_to}
                min={@min_year}
                max={@this_year}
                step="1"
                class="range range-primary range-sm flex-1"
              />
              <span class="w-12 text-lg font-semibold tabular-nums">{@up_to}</span>
              <span :if={@born} class="whitespace-nowrap text-xs text-base-content/60">
                aged {@up_to - @born}
              </span>
            </label>
            <select name="kind" class="select select-bordered select-sm">
              <option
                :for={{k, label} <- Profile.kinds()}
                :if={k in [:all, :movie, :tv, :anime]}
                value={k}
                selected={@kind == k}
              >
                {label}
              </option>
            </select>
            <div class="text-sm text-base-content/70">
              <span class="font-semibold">{length(@items)}</span>
              {if length(@items) == 1, do: "title", else: "titles"} out by {@up_to} · {@pool_size} still to place
            </div>
          </form>

          <p :if={@notice} class="alert alert-success text-sm">{@notice}</p>

          <p :if={@pool_size == 0} class="text-base-content/60">
            Nothing to place: no title here has a missing date or an import day on it.
          </p>
          <p :if={@pool_size > 0 and @items == []} class="text-base-content/60">
            Nothing to place by {@up_to}. Slide the year on.
          </p>

          <ul class="grid grid-cols-3 gap-4 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-8">
            <li :for={i <- @shown_items} class="space-y-1">
              <div class="relative">
                <.poster
                  item={Map.put(i, :badge, nil)}
                  compact
                  title?={false}
                  mark?={false}
                />
                <button
                  type="button"
                  phx-click="toggle"
                  phx-value-key={i.key}
                  aria-pressed={to_string(MapSet.member?(@selected, i.key))}
                  aria-label={"Select #{i.title}"}
                  class="absolute inset-0 z-10 cursor-pointer"
                ></button>
                <div
                  :if={MapSet.member?(@selected, i.key)}
                  class="pointer-events-none absolute inset-x-0 top-0 z-20 aspect-[2/3] rounded-box ring-4 ring-primary"
                >
                  <span class="absolute right-1.5 top-1.5 grid h-6 w-6 place-items-center rounded-full bg-primary text-primary-content">
                    <.icon name="hero-check-mini" class="h-4 w-4" />
                  </span>
                </div>
              </div>
              <div class="truncate text-xs font-medium" title={i.title}>{i.title}</div>
              <div class="text-[0.7rem] leading-tight text-base-content/50">
                {release_year(i) || "year unknown"} · was {import_day(i)}
              </div>
            </li>
          </ul>

          <div :if={length(@items) > @shown} class="flex justify-center">
            <button phx-click="more" class="btn btn-wide">Show more</button>
          </div>
        </div>
      </div>

      <%!-- The bar: what is ticked, and the year to put it in. --%>
      <form
        :if={@chosen != []}
        id="place-form"
        phx-submit="place"
        phx-change="form"
        class="fixed inset-x-0 bottom-0 z-40 border-t border-base-300 bg-base-100/95 px-4 py-3 shadow-[0_-8px_24px_-12px_rgba(0,0,0,0.3)] backdrop-blur sm:px-6 lg:px-12"
      >
        <div class="mx-auto flex max-w-6xl flex-wrap items-center gap-x-4 gap-y-2">
          <div class="text-sm">
            <span class="font-semibold">{length(@chosen)}</span>
            ticked
            <span :if={@window} class="block text-xs text-base-content/60">
              could have been watched {elem(@window, 0)}–{elem(@window, 1)}
            </span>
          </div>
          <div class="ml-auto flex flex-wrap items-center gap-2">
            <button type="button" phx-click="select_all" class="btn btn-ghost btn-sm">
              All {length(@items)}
            </button>
            <button type="button" phx-click="select_none" class="btn btn-ghost btn-sm">None</button>
            <select name="year" class="select select-bordered select-sm" required>
              <option value="" disabled selected={@year == nil}>Year</option>
              <option
                :for={y <- elem(@window, 0)..elem(@window, 1)//1}
                value={y}
                selected={@year == y}
              >
                {y}
              </option>
            </select>
            <select name="month" class="select select-bordered select-sm">
              <option value="mid" selected={@month == "mid"}>Not sure which month</option>
              <option :for={m <- @months} value={m} selected={@month == m}>{m}</option>
            </select>
            <button type="submit" class="btn btn-primary btn-sm">Put there</button>
            <button type="button" phx-click="skip" class="btn btn-ghost btn-sm">Can't tell</button>
          </div>
          <p :if={@error} class="w-full text-sm text-error">{@error}</p>
        </div>
      </form>
    </Layouts.app>
    """
  end
end
