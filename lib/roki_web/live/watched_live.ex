defmodule RokiWeb.WatchedLive do
  @moduledoc """
  `/:username/watched` — everything a user finished, as a grid of posters or as rows (title,
  kind, year, their rating, when), newest first or by their own ratings (`?sort=top`,
  `?kind=anime`, `?genre=horror` for one genre, `?status=progress` (or `up_to_date`, `on_hold`, `finished`) for one kind of entry, `?months=0` for one list without month headings, `?dated=no` for the titles with no watch date (the owner's), `?rating=9` for the titles rated 9 (`?tens=1` still means 10), `?q=` to search, `?view=rows`). Open to
  everyone, like the profile; everything is read from this server (`Roki.Profile`).

  The owner has a button that turns on *select mode* (and off again): tick any number of
  titles, then give them a watch date — a film found years after it was seen goes back where it
  belongs instead of topping the list — or take them off the list.
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
      {:ok,
       assign(socket,
         page_title: "Watched",
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
        assign(socket,
          page_title: "#{user.username} · watched",
          user: user,
          username: user.username,
          uuid: user.uuid,
          owner?: owner?,
          profile: profile,
          visible?: true,
          history: nil,
          ratings: %{},
          season_notes: %{},
          sort: :latest,
          kind: :all,
          q: "",
          view: :grid,
          rating: nil,
          status: nil,
          genre: nil,
          undated?: false,
          genre_waits: 0,
          months?: true,
          shown: @page,
          page: @page,
          place: if(connected?(socket), do: RokiWeb.Place.from_params(socket, 60)),
          place_y: nil,
          select?: false,
          selected: MapSet.new(),
          dating?: false,
          seasons: %{},
          seasons_all: %{},
          whole_title?: true,
          air: nil,
          single: nil,
          released: nil,
          aired_ok?: false,
          aired_busy?: false,
          date_value: nil,
          season_value: "",
          date_error: nil,
          notice: nil
        )

      {:ok, if(connected?(socket), do: load(socket), else: socket)}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     assign(socket,
       sort: Profile.sort(params["sort"]),
       kind: Profile.kind(params["kind"]),
       view: if(params["view"] == "rows", do: :rows, else: :grid),
       q: params["q"] |> to_string() |> String.trim() |> String.slice(0, 80),
       months?: params["months"] != "0",
       status: status_param(params["status"]),
       genre: Roki.Genres.parse(params["genre"]),
       undated?: params["dated"] == "no",
       rating: Profile.rating_param(params["rating"] || if(params["tens"] == "1", do: "10"))
     )
     |> take_place()}
  end

  # Back from a title: as many of the list's pages as were open, and the place to scroll to. Any
  # other change of the address starts at the top of the first page.
  defp take_place(%{assigns: %{place: %{pages: pages, y: y}}} = socket),
    do: assign(socket, place: nil, place_y: y, shown: pages * socket.assigns.page)

  defp take_place(socket), do: assign(socket, shown: socket.assigns.page, place_y: nil)

  defp load(socket) do
    uuid = socket.assigns.uuid

    socket
    |> start_async(:ratings, fn -> Profile.ratings(uuid) end)
    |> start_async(:season_notes, fn -> Profile.season_notes(uuid) end)
    |> start_async(:history, fn -> Profile.history_all(uuid) end)
    |> refresh_ratings()
  end

  # The ratings shown are the site's copy of the ones on TMDB / MyAnimeList, and a rating made over
  # there (or in the terminal app) is not in it until it is copied again. Opening your own list
  # copies them if that has not happened in the last hour, and draws the new ones when it has.
  defp refresh_ratings(%{assigns: %{owner?: true, uuid: uuid}} = socket),
    do: start_async(socket, :ratings_refresh, fn -> Profile.refresh_ratings(uuid) end)

  defp refresh_ratings(socket), do: socket

  # One show selected, and laev's record says which of its seasons were watched: that is the
  # only time a season can be dated on its own. Looked up when the dialog opens rather than
  # with the page, since most of the time nobody opens it.
  defp seasons_for(%{assigns: %{selected: selected}} = socket) do
    with [key] <- MapSet.to_list(selected),
         %{} = item <- Enum.find(arranged(socket), &(&1.key == key)) do
      seasons_of(item, socket.assigns.seasons_all)
    else
      _ -> %{}
    end
  end

  defp arranged(%{assigns: a}) when is_list(a.history) do
    list =
      Profile.arrange(
        Profile.by_season(a.history, a.season_notes, a.owner? or a.profile.show_ratings),
        if(a.owner? or a.profile.show_ratings, do: a.ratings, else: %{}),
        a.kind,
        a.sort,
        a.rating
      )

    list = if a.status, do: Enum.filter(list, &(&1.status == a.status)), else: list
    list = if a.undated?, do: Enum.reject(list, & &1.dated?), else: list

    list =
      if a.genre,
        do: Enum.filter(list, &Roki.Genres.match?(a.genre, &1.type, &1.genres)),
        else: list

    if a.q == "" do
      list
    else
      q = String.downcase(a.q)
      Enum.filter(list, &String.contains?(String.downcase(&1.title || ""), q))
    end
  end

  defp arranged(_socket), do: []

  @statuses [
    {"finished", "Finished"},
    {"progress", "In progress"},
    {"up_to_date", "Up to date"},
    {"on_hold", "On hold"}
  ]

  defp rating_note(:none), do: " without a rating"
  defp rating_note(nil), do: ""
  defp rating_note(n), do: " rated #{n}"

  defp filters_on(status, rating, genre, undated?),
    do: Enum.count([status, rating, genre, undated? || nil], &(&1 != nil))

  defp status_param(value), do: if(value in Enum.map(@statuses, &elem(&1, 0)), do: value)

  defp status_label(status),
    do: Enum.find_value(@statuses, "Finished", fn {k, v} -> k == status && v end)

  # Only a finished title has a watch date to change or a mark to take off.
  defp status_title(item),
    do: status_label(item.status) <> if(item[:note], do: " · #{item.note}", else: "")

  defp finished?(%{status: status}), do: status == "finished"
  defp finished?(_), do: true

  # What can be picked in select mode. A finished title, because its date and its place on the
  # list can be changed — and a show that is still going if laev has episode records for it,
  # because one of its seasons can be dated even though the show is not done. That was the gap:
  # a show watched a season at a time is never finished, so it could not be touched at all.
  defp air_day(%Date{} = d), do: Calendar.strftime(d, "%-d %b %Y")
  defp air_day(_), do: "?"

  defp selectable?(item, seasons_all), do: finished?(item) or seasons_of(item, seasons_all) != %{}

  defp seasons_of(item, seasons_all) do
    case Roki.Profile.parse_key(item.key) do
      {type, id} -> Map.get(seasons_all, {type, id}, %{})
      _ -> %{}
    end
  end

  defp all_seasons(uuid) do
    case Roki.Laev.run(uuid, &Roki.Stats.season_episodes/0) do
      %{} = counts -> counts
      _ -> %{}
    end
  end

  defp selectable_key?(socket, key) do
    is_list(socket.assigns.history) and
      Enum.any?(
        socket.assigns.history,
        &(&1.key == key and selectable?(&1, socket.assigns.seasons_all))
      )
  end

  defp finished_key?(socket, key) do
    is_list(socket.assigns.history) and
      Enum.any?(socket.assigns.history, &(&1.key == key and finished?(&1)))
  end

  # One show picked: when each of its seasons was on, to date by what is remembered.
  defp look_up_seasons(%{assigns: %{selected: selected, uuid: uuid}} = socket) do
    case MapSet.to_list(selected) do
      [key] ->
        case Roki.Profile.parse_key(key) do
          {"tv", id} ->
            socket
            |> assign(:air, :loading)
            |> start_async(:air, fn -> Roki.AirDates.seasons(id, uuid) end)

          _ ->
            socket
        end

      _ ->
        socket
    end
  end

  defp shows_only?(selected),
    do:
      selected != MapSet.new() and
        Enum.all?(selected, &match?({"tv", _}, Roki.Profile.parse_key(&1)))

  # Each show on its own air dates. A finished show: every season on the day its last episode came
  # out, and the show on the day its last season ended. One still going, or caught up: only the
  # seasons with episodes marked, each on the day the last episode marked came out — a season
  # stopped in the middle is dated by where it stopped, and seasons not got to are left alone.
  defp date_as_aired(uuid, targets) do
    Enum.reduce(targets, {0, 0}, fn {key, id, finished?}, {shows, count} ->
      dated =
        if finished? do
          for s <- Roki.AirDates.seasons(id, uuid), do: %{number: s.number, date: s.last}
        else
          Roki.AirDates.watched_seasons(id, uuid)
        end

      for s <- dated, do: :ok = Profile.set_season_date(uuid, "tv", id, s.number, s.date)

      if finished? and dated != [] do
        Profile.set_watched_at(uuid, [key], Enum.max_by(dated, & &1.date, Date).date)
      end

      if dated == [], do: {shows, count}, else: {shows + 1, count + length(dated)}
    end)
  end

  # What the dialog opens on: the day one title is on now (when it has a date of its own), else today.
  defp open_date(socket) do
    case single_item(socket) do
      %{dated?: true, at: at} ->
        at |> DateTime.from_unix!() |> DateTime.to_date() |> Date.to_iso8601()

      _ ->
        Date.to_iso8601(Date.utc_today())
    end
  end

  # The one title selected, when it is one: the dialog tells what it needs to know about it.
  defp single_item(%{assigns: %{selected: selected}} = socket) do
    with [key] <- MapSet.to_list(selected),
         %{} = item <- Enum.find(arranged(socket), &(&1.key == key)) do
      item
    else
      _ -> nil
    end
  end

  # When it came out — so a date is chosen with that in front of you — read in the background.
  defp look_up_release(%{assigns: %{uuid: uuid}} = socket) do
    case single_item(socket) do
      %{type: type, id: id} when type in ["movie", "tv"] and is_integer(id) ->
        socket
        |> assign(:released, :loading)
        |> start_async(:released, fn ->
          with {:ok, t} <- Roki.Watch.title(type, id, uuid),
               {:ok, date} <- Date.from_iso8601(to_string(t[:date])) do
            %{type: type, date: date}
          else
            _ -> nil
          end
        end)

      _ ->
        socket
    end
  end

  # The date the form holds, whichever way it was typed: a day, a month and a year (the way the
  # dialog asks), or one ISO date. A day the month does not have is the month's last.
  defp form_date(%{"year" => y, "month" => m, "day" => d}) do
    with {year, ""} <- Integer.parse(to_string(y)),
         {month, ""} <- Integer.parse(to_string(m)),
         {day, ""} <- Integer.parse(to_string(d)),
         true <- month in 1..12 and year in 1..9999 and day in 1..31 do
      {:ok, Date.new!(year, month, min(day, Date.days_in_month(Date.new!(year, month, 1))))}
    else
      _ -> :error
    end
  end

  defp form_date(%{"date" => text}) when is_binary(text) do
    case Date.from_iso8601(text) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp form_date(_), do: :error

  defp release_day(%Date{} = d), do: Calendar.strftime(d, "%-d %B %Y")

  # ── events ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("more", _params, socket), do: {:noreply, update(socket, :shown, &(&1 + @page))}

  # The list has been scrolled to where the reader was; the place is not needed again.
  def handle_event("placed", _params, socket), do: {:noreply, assign(socket, :place_y, nil)}

  # Typing in the search box: the address carries it, so a search can be shared too.
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: address(socket.assigns, q: String.trim(q)), replace: true)}
  end

  # Select mode — the owner's.
  def handle_event("select_mode", _params, %{assigns: %{owner?: true}} = socket) do
    on? = not socket.assigns.select?

    {:noreply,
     assign(socket,
       select?: on?,
       selected: MapSet.new(),
       dating?: false,
       notice: nil,
       seasons_all: if(on?, do: all_seasons(socket.assigns.uuid), else: %{})
     )}
  end

  def handle_event(
        "select_toggle",
        %{"key" => key},
        %{assigns: %{owner?: true, select?: true}} = socket
      ) do
    sel = socket.assigns.selected

    cond do
      MapSet.member?(sel, key) -> {:noreply, assign(socket, :selected, MapSet.delete(sel, key))}
      selectable_key?(socket, key) -> {:noreply, assign(socket, :selected, MapSet.put(sel, key))}
      true -> {:noreply, socket}
    end
  end

  # Everything the filters show, not only the page on screen.
  def handle_event("select_all", _params, %{assigns: %{owner?: true, select?: true}} = socket),
    do:
      {:noreply,
       assign(socket, :selected, MapSet.new(for i <- arranged(socket), finished?(i), do: i.key))}

  def handle_event("select_none", _params, %{assigns: %{owner?: true}} = socket),
    do: {:noreply, assign(socket, selected: MapSet.new(), dating?: false)}

  def handle_event("date_open", _params, %{assigns: %{owner?: true, select?: true}} = socket) do
    if MapSet.size(socket.assigns.selected) > 0,
      do:
        {:noreply,
         socket
         |> assign(
           dating?: true,
           date_error: nil,
           seasons: seasons_for(socket),
           whole_title?: Enum.all?(socket.assigns.selected, &finished_key?(socket, &1)),
           date_value: open_date(socket),
           season_value: "",
           aired_ok?: shows_only?(socket.assigns.selected),
           aired_busy?: false,
           air: nil,
           single: single_item(socket),
           released: nil
         )
         |> look_up_release()
         |> look_up_seasons()},
      else: {:noreply, socket}
  end

  # The form's own values are kept while the dialog redraws (a season's date is put in the box).
  def handle_event("date_change", params, %{assigns: %{owner?: true}} = socket) do
    date_value =
      case form_date(params) do
        {:ok, date} -> Date.to_iso8601(date)
        :error -> socket.assigns.date_value
      end

    {:noreply,
     assign(socket,
       date_value: date_value,
       season_value: Map.get(params, "season", socket.assigns.season_value)
     )}
  end

  def handle_event("date_pick", %{"date" => date} = params, %{assigns: %{owner?: true}} = socket) do
    case Date.from_iso8601(date) do
      {:ok, d} ->
        # A show still going can only be dated by season: the one whose date this is is chosen too.
        season = params["season"]

        season_value =
          if is_binary(season) and not socket.assigns.whole_title? and
               Enum.any?(Map.keys(socket.assigns.seasons), &(to_string(&1) == season)),
             do: season,
             else: socket.assigns.season_value

        {:noreply,
         assign(socket,
           date_value: Date.to_iso8601(d),
           season_value: season_value,
           date_error: nil
         )}

      _ ->
        {:noreply, socket}
    end
  end

  # "I watched it as it aired": each season goes on the day its last episode came out. For a show
  # whose seasons are known from the episodes watched only those are dated; a finished show is put
  # on the day its last season ended.
  def handle_event("date_aired", _params, %{assigns: %{owner?: true, aired_ok?: true}} = socket) do
    targets =
      for key <- socket.assigns.selected,
          {"tv", id} <- [Roki.Profile.parse_key(key)],
          item <- [Enum.find(arranged(socket), &(&1.key == key))],
          item != nil do
        {key, id, finished?(item)}
      end

    uuid = socket.assigns.uuid

    {:noreply,
     socket
     |> assign(aired_busy?: true, date_error: nil)
     |> start_async(:aired, fn -> date_as_aired(uuid, targets) end)}
  end

  def handle_event("date_close", _params, socket),
    do:
      {:noreply,
       assign(socket,
         dating?: false,
         date_error: nil,
         seasons: %{},
         air: nil,
         single: nil,
         released: nil
       )}

  # One season of one show, rather than the whole title: its share of the show's time moves to
  # this day and the rest of the show stays where it was.
  def handle_event(
        "date_save",
        %{"season" => season} = params,
        %{assigns: %{owner?: true, select?: true}} = socket
      )
      when season != "" do
    with {:ok, date} <- form_date(params),
         true <- Date.compare(date, Date.utc_today()) != :gt and date.year >= 1900,
         {n, ""} <- Integer.parse(season),
         [key] <- MapSet.to_list(socket.assigns.selected),
         {type, id} <- Roki.Profile.parse_key(key) do
      :ok = Profile.set_season_date(socket.assigns.uuid, type, id, n, date)

      {:noreply,
       socket
       |> assign(dating?: false, selected: MapSet.new(), date_error: nil, seasons: %{})
       |> assign(
         notice:
           "Season #{n} set to #{Calendar.strftime(date, "%B %-d, %Y")}. The rest of the show stays where it was."
       )}
    else
      _ ->
        {:noreply,
         assign(socket, :date_error, "Pick a day that has happened (not in the future).")}
    end
  end

  # The chosen day goes on every title selected, in the order the list shows them.
  def handle_event(
        "date_save",
        params,
        %{assigns: %{owner?: true, select?: true}} = socket
      ) do
    with {:ok, date} <- form_date(params),
         true <- Date.compare(date, Date.utc_today()) != :gt and date.year >= 1900 do
      keys =
        for i <- arranged(socket),
            finished?(i),
            MapSet.member?(socket.assigns.selected, i.key),
            do: i.key

      {:ok, n} = Profile.set_watched_at(socket.assigns.uuid, keys, date)

      {:noreply,
       socket
       |> assign(
         history: Profile.history_all(socket.assigns.uuid),
         dating?: false,
         selected: MapSet.new(),
         date_error: nil
       )
       |> assign(
         notice:
           "#{n} #{if n == 1, do: "title", else: "titles"} set to #{Calendar.strftime(date, "%B %-d, %Y")}."
       )}
    else
      _ ->
        {:noreply,
         assign(socket, :date_error, "Pick a day that has happened (not in the future).")}
    end
  end

  def handle_event("remove", _params, %{assigns: %{owner?: true, select?: true}} = socket) do
    keys = for k <- socket.assigns.selected, finished_key?(socket, k), do: k
    {:ok, n} = Profile.remove_watched(socket.assigns.uuid, keys)

    {:noreply,
     socket
     |> assign(
       history: Profile.history_all(socket.assigns.uuid),
       selected: MapSet.new(),
       dating?: false
     )
     |> assign(
       notice: "#{n} #{if n == 1, do: "title", else: "titles"} taken off your watched list."
     )}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ── async results ──────────────────────────────────────────────────

  @impl true
  def handle_async(:season_notes, {:ok, %{} = notes}, socket),
    do: {:noreply, assign(socket, :season_notes, notes)}

  def handle_async(:season_notes, _other, socket), do: {:noreply, socket}

  def handle_async(:history, {:ok, items}, socket) when is_list(items),
    do: {:noreply, socket |> assign(:history, items) |> wait_for_genres()}

  def handle_async(:history, _other, socket), do: {:noreply, assign(socket, :history, [])}

  def handle_async(:released, {:ok, %{} = released}, socket),
    do: {:noreply, assign(socket, :released, released)}

  def handle_async(:released, _other, socket), do: {:noreply, assign(socket, :released, nil)}

  def handle_async(:air, {:ok, list}, socket) when is_list(list),
    do: {:noreply, assign(socket, :air, list)}

  def handle_async(:air, _other, socket), do: {:noreply, assign(socket, :air, [])}

  def handle_async(:aired, {:ok, {shows, count}}, %{assigns: %{uuid: uuid}} = socket) do
    {:noreply,
     socket
     |> assign(
       history: Profile.history_all(uuid),
       dating?: false,
       selected: MapSet.new(),
       aired_busy?: false,
       air: nil,
       seasons: %{}
     )
     |> assign(
       notice:
         if(count == 0,
           do: "No season of #{if shows == 1, do: "it", else: "them"} had an air date to use.",
           else:
             "#{count} #{if count == 1, do: "season", else: "seasons"} of #{shows} #{if shows == 1, do: "show", else: "shows"} put on the day each one's last episode aired."
         )
     )}
  end

  def handle_async(:aired, _other, socket),
    do:
      {:noreply,
       assign(socket,
         aired_busy?: false,
         date_error: "Could not read the air dates just now. Try again in a minute."
       )}

  def handle_async(:ratings, {:ok, ratings}, socket) when is_map(ratings),
    do: {:noreply, assign(socket, :ratings, ratings)}

  def handle_async(:ratings, _other, socket), do: {:noreply, socket}

  # A copy was just made: read the ratings again. (`:recent` — made within the hour — changes
  # nothing, and neither does an account that is not connected.)
  def handle_async(:ratings_refresh, {:ok, :ok}, %{assigns: %{uuid: uuid}} = socket),
    do: {:noreply, start_async(socket, :ratings, fn -> Profile.ratings(uuid) end)}

  def handle_async(:ratings_refresh, _other, socket), do: {:noreply, socket}

  # Genres are read from TMDB in the background, once for each title. While some are still to come
  # the page looks again every few seconds, so a filtered list fills in by itself.
  @impl true
  def handle_info(:reread_genres, socket) do
    uuid = socket.assigns.uuid
    {:noreply, start_async(socket, :history, fn -> Profile.history_all(uuid) end)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp genres_pending(history) when is_list(history),
    do: Enum.count(history, &(&1.genres == nil and is_integer(&1.id)))

  defp genres_pending(_), do: 0

  defp wait_for_genres(%{assigns: %{history: history, genre_waits: waits}} = socket) do
    if connected?(socket) and genres_pending(history) > 0 and waits < 90 do
      Process.send_after(self(), :reread_genres, 5_000)
      assign(socket, :genre_waits, waits + 1)
    else
      socket
    end
  end

  # ── view ───────────────────────────────────────────────────────────

  # The address of a view: the assigns, with `overrides` (a new search, a new view …) laid on.
  defp address(a, overrides) do
    v =
      %{
        sort: a.sort,
        kind: a.kind,
        rating: a.rating,
        status: a.status,
        genre: a.genre,
        undated?: a.undated?,
        months: a.months?,
        q: a.q,
        view: a.view
      }
      |> Map.merge(Map.new(overrides))

    query =
      Enum.flat_map([:sort, :kind, :rating, :status, :genre, :undated, :months, :q, :view], fn
        :sort ->
          case v.sort do
            :top -> [sort: "top"]
            :oldest -> [sort: "oldest"]
            _ -> []
          end

        :kind ->
          if v.kind != :all, do: [kind: Atom.to_string(v.kind)], else: []

        :rating ->
          if v.rating, do: [rating: v.rating], else: []

        :status ->
          if v.status, do: [status: v.status], else: []

        :genre ->
          if v.genre, do: [genre: v.genre], else: []

        :undated ->
          if v.undated?, do: [dated: "no"], else: []

        :months ->
          if v.months, do: [], else: [months: "0"]

        :q ->
          if v.q != "", do: [q: v.q], else: []

        :view ->
          if v.view == :rows, do: [view: "rows"], else: []
      end)

    base = "/u/#{a.username}/watched"
    if query == [], do: base, else: base <> "?" <> URI.encode_query(query)
  end

  @months ~w(January February March April May June July August September October November December)

  defp day(%{dated?: true, at: at}) do
    d = DateTime.from_unix!(at)
    "#{d.day} #{String.slice(Enum.at(@months, d.month - 1), 0, 3)} #{d.year}"
  end

  defp day(_), do: nil

  # Under a month's name, when the list is in the order things were watched.
  defp group_label(%{dated?: true, at: at}) do
    d = DateTime.from_unix!(at)
    "#{Enum.at(@months, d.month - 1)} #{d.year}"
  end

  defp group_label(_), do: "No date"

  defp groups(items, sort, true) when sort in [:latest, :oldest],
    do: Enum.chunk_by(items, &group_label/1) |> Enum.map(&{group_label(hd(&1)), &1})

  defp groups(items, _sort, _months), do: [{nil, items}]

  # How many titles a list holds: a show listed once per season is still one.
  defp title_count(items), do: items |> Enum.uniq_by(& &1.key) |> length()

  # The seasons shown under a row: those rated but not dated (the dated ones are listings of their own).
  defp undated_seasons(%{season_no: _}, _notes), do: []

  defp undated_seasons(item, notes),
    do: notes |> Map.get(item.key, []) |> Enum.reject(& &1.at)

  defp kind_label(%{anime: true}), do: "Anime"
  defp kind_label(%{type: "movie"}), do: "Movie"
  defp kind_label(%{type: "tv"}), do: "Show"
  defp kind_label(_), do: "Anime"

  @impl true
  def render(assigns) do
    items = arranged(%{assigns: assigns})
    shown = Enum.take(items, assigns.shown)

    assigns =
      assign(assigns,
        items: items,
        groups: groups(shown, assigns.sort, assigns.months?),
        today: Date.utc_today() |> Date.to_iso8601(),
        shown_date: Date.from_iso8601!(assigns.date_value || Date.to_iso8601(Date.utc_today()))
      )

    ~H"""
    <Layouts.app
      socket={@socket}
      flash={@flash}
      flush
      bleed
      overlay
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path={"/u/#{@username}/watched"}
    >
      <p :if={@user == nil} class="px-4 pb-24 pt-40 text-center text-base-content/60">
        There is no one called <strong>{@username}</strong> here.
      </p>

      <%!-- The top: a dark picture under the floating header with whose list it is, and how long. --%>
      <section
        :if={@visible?}
        class="relative z-20 flex min-h-[clamp(14rem,30svh,20rem)] flex-col justify-end text-white"
      >
        <div class="absolute inset-0 -z-10 overflow-hidden bg-neutral-900">
          <div class="absolute inset-0 bg-gradient-to-br from-primary/40 via-neutral-900 to-secondary/30">
          </div>
          <div class="absolute inset-0 bg-gradient-to-t from-black/60 via-transparent to-black/40">
          </div>
        </div>
        <div class="flex flex-col gap-3 px-4 pb-6 pt-28 sm:px-6 lg:px-12 xl:px-16">
          <.link
            navigate={"/u/#{@username}/profile"}
            class="flex w-fit items-center gap-2 text-white/80 hover:text-white"
          >
            <.user_avatar user={@user} size="sm" />
            <span class="font-semibold">{@user.username}</span>
          </.link>
          <div class="flex items-baseline gap-3">
            <h1 class="text-4xl font-bold tracking-tight drop-shadow-lg sm:text-5xl xl:text-6xl">
              Watched
            </h1>
            <span :if={is_list(@history)} class="text-lg tabular-nums text-white/70">
              {title_count(@items)}
            </span>
          </div>
        </div>
      </section>

      <div
        :if={@visible?}
        class={[
          "space-y-6 px-4 pb-12 pt-4 [overflow-x:clip] sm:px-6 lg:px-12 xl:px-16",
          @select? && "pb-28"
        ]}
      >
        <%!-- The header. On a phone: one bar that stays at the top with the search, the view
              switch and (for the owner) Select, then the kind tabs with the sort in a small
              menu. On a wide screen the same pieces become one toolbar (the wrappers vanish
              with `contents` and `order-*` lays the pieces out). --%>
        <div class="contents lg:sticky lg:top-14 lg:z-30 lg:-mx-12 lg:flex lg:flex-wrap lg:items-center lg:gap-x-5 lg:gap-y-3 lg:border-b lg:border-base-300/60 lg:bg-base-100/90 lg:px-12 lg:py-3 lg:backdrop-blur xl:-mx-16 xl:px-16">
          <%!-- The search, how the list is laid out (posters or rows), and Select. --%>
          <div class="sticky top-14 z-30 -mx-4 flex items-center gap-2 border-b border-base-300/50 bg-base-100/90 px-4 py-2 backdrop-blur sm:-mx-6 sm:px-6 lg:contents">
            <form
              id="watched-search"
              phx-change="search"
              phx-submit="search"
              class="min-w-0 flex-1 sm:max-w-md lg:order-4 lg:w-96 lg:flex-none"
            >
              <label class="flex h-10 w-full items-center gap-2 rounded-full bg-base-200 px-3.5 focus-within:ring-2 focus-within:ring-primary/60 lg:h-12 lg:border lg:border-base-300 lg:bg-base-100">
                <.icon name="hero-magnifying-glass" class="h-4 w-4 shrink-0 text-base-content/50" />
                <input
                  type="text"
                  name="q"
                  value={@q}
                  placeholder="Search watched…"
                  aria-label={
                    if @owner?,
                      do: "Search what you watched",
                      else: "Search what #{@username} watched"
                  }
                  autocomplete="off"
                  phx-debounce="300"
                  class="min-w-0 grow bg-transparent text-sm outline-none placeholder:text-base-content/45"
                />
              </label>
            </form>
            <div
              class="inline-flex shrink-0 overflow-hidden rounded-full bg-base-200 p-0.5 lg:order-6 lg:h-12 lg:items-center"
              role="group"
              aria-label="View"
            >
              <.link
                patch={address(assigns, view: :grid)}
                class={[
                  "flex h-9 w-9 items-center justify-center rounded-full transition lg:h-10 lg:w-10",
                  @view == :grid && "bg-base-100 shadow-sm"
                ]}
                aria-label="Grid view"
                title="Grid"
              >
                <.icon name="hero-squares-2x2" class="h-5 w-5" />
              </.link>
              <.link
                patch={address(assigns, view: :rows)}
                class={[
                  "flex h-9 w-9 items-center justify-center rounded-full transition lg:h-10 lg:w-10",
                  @view == :rows && "bg-base-100 shadow-sm"
                ]}
                aria-label="List view"
                title="List"
              >
                <.icon name="hero-bars-3" class="h-5 w-5" />
              </.link>
            </div>
            <RokiWeb.GridSize.grid_switch
              :if={@view == :grid}
              step_on_phone
              size={@grid_size}
              class="lg:order-6 lg:h-12 lg:items-center"
            />
            <%!-- Select mode, for the owner: one button, on and off. --%>
            <button
              :if={@owner?}
              type="button"
              phx-click="select_mode"
              aria-pressed={to_string(@select?)}
              class={[
                "btn btn-sm ml-auto h-10 shrink-0 gap-1.5 rounded-full lg:order-7 lg:btn-md",
                @select? && "btn-primary"
              ]}
            >
              <.icon name={if @select?, do: "hero-check", else: "hero-check-circle"} class="h-4 w-4" />
              {if @select?, do: "Done", else: "Select"}
            </button>
          </div>

          <%!-- The kinds as tabs, and the sort: a menu on a phone, plain buttons on a wide screen. --%>
          <div class="flex items-center gap-3 pb-4 pt-3 lg:order-8 lg:pt-0 lg:basis-full lg:gap-4 lg:pb-0">
            <div class="grid min-w-0 flex-1 grid-cols-4 rounded-full bg-base-200 p-0.5 lg:flex lg:flex-none lg:bg-transparent lg:p-0 lg:gap-1.5">
              <.link
                :for={{k, label} <- Profile.kinds()}
                patch={address(assigns, kind: k)}
                class={[
                  "flex h-8 items-center justify-center whitespace-nowrap rounded-full px-2 text-sm font-medium transition lg:h-9 lg:px-4",
                  @kind == k &&
                    "bg-base-100 text-primary shadow-sm lg:bg-primary lg:text-primary-content",
                  @kind != k && "text-base-content/70 hover:text-base-content lg:bg-base-200"
                ]}
              >
                {label}
              </.link>
            </div>

            <%!-- Phone: sort and rating in one menu. --%>
            <div class="dropdown dropdown-end shrink-0 lg:hidden">
              <div
                tabindex="0"
                role="button"
                class="btn btn-sm h-9 gap-1 rounded-full border-0 bg-base-200 px-3 font-medium"
                aria-label="Sort and filter"
              >
                <.icon name="hero-adjustments-horizontal" class="h-4 w-4" />
                {case @sort do
                  :top -> "Rating"
                  :oldest -> "Oldest"
                  _ -> "Latest"
                end}
                <span
                  :if={filters_on(@status, @rating, @genre, @undated?) > 0}
                  class="badge badge-primary badge-xs"
                >{filters_on(@status, @rating, @genre, @undated?)}</span>
              </div>
              <div
                tabindex="0"
                class="dropdown-content z-40 mt-2 w-60 rounded-box border border-base-300 bg-base-100 p-3 shadow-xl"
              >
                <p class="px-1 pb-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/50">
                  Sort
                </p>
                <div class="grid grid-cols-2 gap-1.5">
                  <.link
                    :for={
                      {s, label} <- [{:latest, "Latest"}, {:oldest, "Oldest"}, {:top, "By rating"}]
                    }
                    patch={address(assigns, sort: s)}
                    onclick="document.activeElement.blur()"
                    class={[
                      "btn btn-sm rounded-full border-0",
                      @sort == s && "btn-primary",
                      @sort != s && "bg-base-200"
                    ]}
                  >{label}</.link>
                </div>
                <.months_toggle a={assigns} class="mt-3" />
                <.undated_toggle :if={@owner?} a={assigns} class="mt-1.5" />
                <.status_picker a={assigns} />
                <.genre_picker a={assigns} />
                <.rating_picker :if={@owner? or @profile.show_ratings} a={assigns} />
              </div>
            </div>

            <%!-- Wide screen: sort as pills, rating as a menu. --%>
            <div class="hidden items-center gap-1.5 lg:flex">
              <.link
                :for={{s, label} <- [{:latest, "Latest"}, {:oldest, "Oldest"}, {:top, "By rating"}]}
                patch={address(assigns, sort: s)}
                class={[
                  "btn btn-sm h-9 rounded-full border-0 text-sm font-medium",
                  @sort == s && "btn-primary",
                  @sort != s && "bg-base-200"
                ]}
              >
                {label}
              </.link>
              <.months_toggle a={assigns} pill />
              <.undated_toggle :if={@owner?} a={assigns} pill />
              <div class="dropdown">
                <div
                  tabindex="0"
                  role="button"
                  class={[
                    "btn btn-sm h-9 gap-1 rounded-full border-0 text-sm font-medium",
                    @genre && "btn-primary",
                    !@genre && "bg-base-200"
                  ]}
                >
                  {if @genre, do: Roki.Genres.label(@genre), else: "Genre"}
                  <.icon name="hero-chevron-down-micro" class="h-4 w-4" />
                </div>
                <div
                  tabindex="0"
                  class="dropdown-content z-40 mt-2 w-72 rounded-box border border-base-300 bg-base-100 p-3 shadow-xl"
                >
                  <.genre_picker a={assigns} heading={false} />
                </div>
              </div>
              <div class="dropdown">
                <div
                  tabindex="0"
                  role="button"
                  class={[
                    "btn btn-sm h-9 gap-1 rounded-full border-0 text-sm font-medium",
                    @status && "btn-primary",
                    !@status && "bg-base-200"
                  ]}
                >
                  {if @status, do: status_label(@status), else: "Status"}
                  <.icon name="hero-chevron-down-micro" class="h-4 w-4" />
                </div>
                <div
                  tabindex="0"
                  class="dropdown-content z-40 mt-2 w-60 rounded-box border border-base-300 bg-base-100 p-3 shadow-xl"
                >
                  <.status_picker a={assigns} heading={false} />
                </div>
              </div>
              <div :if={@owner? or @profile.show_ratings} class="dropdown">
                <div
                  tabindex="0"
                  role="button"
                  class={[
                    "btn btn-sm h-9 gap-1 rounded-full border-0 text-sm font-medium",
                    @rating && "btn-primary",
                    !@rating && "bg-base-200"
                  ]}
                >
                  {cond do
                    @rating == :none -> "Not rated"
                    @rating -> "★ #{@rating}"
                    true -> "★ Rating"
                  end}
                  <.icon name="hero-chevron-down-micro" class="h-4 w-4" />
                </div>
                <div
                  tabindex="0"
                  class="dropdown-content z-40 mt-2 w-60 rounded-box border border-base-300 bg-base-100 p-3 shadow-xl"
                >
                  <.rating_picker a={assigns} heading={false} />
                </div>
              </div>
            </div>
          </div>
        </div>

        <p :if={@notice} class="rounded-box bg-success/10 px-4 py-3 text-sm text-success">
          {@notice}
        </p>
        <p :if={@genre && genres_pending(@history) > 0} class="text-sm text-base-content/60">
          Still reading the genres of {genres_pending(@history)} titles. They join the list as they arrive.
        </p>

        <ul
          :if={@history == nil}
          class={["grid gap-4", RokiWeb.GridSize.cols(@grid_size)]}
          aria-busy="true"
        >
          <li :for={_ <- 1..8} class="space-y-1">
            <div class="skeleton aspect-[2/3] w-full rounded-box"></div>
            <div class="skeleton h-4 w-3/4 rounded"></div>
          </li>
        </ul>

        <p :if={@history == []} class="text-sm text-base-content/50">
          {if @owner?,
            do: "Nothing finished yet. What you watch to the end shows up here.",
            else: "Nothing here yet."}
        </p>
        <p
          :if={@history != nil and @history != [] and @items == []}
          class="text-sm text-base-content/50"
        >
          {if @q != "",
            do: "Nothing watched matches \"#{@q}\".",
            else: "Nothing of that kind#{rating_note(@rating)}."}
        </p>

        <div
          :if={is_list(@history)}
          id="watched-list"
          phx-hook="KeepPlace"
          data-page={div(@shown + @page - 1, @page)}
          data-restore-y={@place_y}
          class="space-y-6"
        >
          <div :for={{label, group} <- @groups} class="space-y-3">
            <h2 :if={label} class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
              {label}
            </h2>

            <%!-- Grid: the posters, a tick in the corner while selecting. --%>
            <%!-- A film or a show opens into the card the rest of the site has (`GridCards`); an anime
                  with no TMDB title is a plain poster. The same poster in both modes, so turning
                  select mode on changes nothing's size (and the page does not move): while
                  selecting, a clear button lies over it, the ring and the tick are drawn on top,
                  and no card opens. --%>
            <div
              :if={@view == :grid}
              id={"watched-cards-#{:erlang.phash2(label)}"}
              phx-hook="GridCards"
            >
              <ul class={["grid gap-4", RokiWeb.GridSize.cols(@grid_size)]}>
                <%= for i <- group do %>
                  <RokiWeb.FeaturedLive.grid_card
                    :if={i.type in ["movie", "tv"]}
                    kind={:watched}
                    item={Map.put(i, :badge, nil)}
                    cached_titles={@cached_titles}
                    signed_in?={true}
                    no_card?={@select?}
                    keep_colour?={true}
                  >
                    <:overlay>
                      <.select_layer
                        i={i}
                        select?={@select?}
                        selectable?={selectable?(i, @seasons_all)}
                        selected={MapSet.member?(@selected, i.key)}
                      />
                    </:overlay>
                    <.day_row i={i} show_score={@owner? or @profile.show_ratings} />
                  </RokiWeb.FeaturedLive.grid_card>
                  <li :if={i.type not in ["movie", "tv"]} class="space-y-1">
                    <div class="relative">
                      <.poster
                        item={Map.put(i, :badge, nil)}
                        cached_titles={@cached_titles}
                        compact
                        title?={false}
                      />
                      <.select_layer
                        i={i}
                        select?={@select?}
                        selectable?={selectable?(i, @seasons_all)}
                        selected={MapSet.member?(@selected, i.key)}
                      />
                    </div>
                    <.day_row i={i} show_score={@owner? or @profile.show_ratings} />
                  </li>
                <% end %>
              </ul>
            </div>

            <%!-- Rows: one to a line, with what you would want to know. --%>
            <ul
              :if={@view == :rows}
              class="divide-y divide-base-300 overflow-hidden rounded-box border border-base-300"
            >
              <li :for={i <- group}>
                <.row
                  item={i}
                  select?={@select?}
                  selectable?={selectable?(i, @seasons_all)}
                  selected={MapSet.member?(@selected, i.key)}
                  show_score={@owner? or @profile.show_ratings}
                  seasons={undated_seasons(i, @season_notes)}
                />
              </li>
            </ul>
          </div>
        </div>

        <%!-- The end of the list: the next sixty are shown as it comes into view. --%>
        <div
          :if={length(@items) > @shown}
          id="watched-more"
          phx-hook="InfiniteScroll"
          data-event="more"
          data-active="true"
          class="flex min-h-16 items-center justify-center"
        >
          <span class="loading loading-spinner loading-md text-base-content/50"></span>
        </div>
      </div>

      <%!-- Select mode's bar: how many and which, then what to do with them. Two lines on a
            phone, one on a wide screen. --%>
      <div
        :if={@select?}
        class="fixed inset-x-0 bottom-0 z-40 border-t border-base-300 bg-base-100/95 px-4 pb-[max(0.75rem,env(safe-area-inset-bottom))] pt-3 shadow-[0_-8px_24px_-12px_rgba(0,0,0,0.3)] backdrop-blur"
      >
        <div class="mx-auto max-w-6xl space-y-3 sm:flex sm:items-center sm:gap-4 sm:space-y-0">
          <div class="flex items-center gap-1 sm:flex-1">
            <p class="min-w-0 flex-1 text-sm"><b>{MapSet.size(@selected)}</b> selected</p>
            <button
              type="button"
              phx-click="select_all"
              class="btn btn-ghost btn-sm whitespace-nowrap"
            >All {title_count(@items)}</button>
            <button
              type="button"
              phx-click="select_none"
              class="btn btn-ghost btn-sm"
              disabled={MapSet.size(@selected) == 0}
            >None</button>
          </div>
          <div class="grid grid-cols-2 gap-2 sm:flex">
            <button
              type="button"
              phx-click="date_open"
              class="btn btn-primary whitespace-nowrap"
              disabled={MapSet.size(@selected) == 0}
            >
              <.icon name="hero-calendar-days" class="h-4 w-4" /> Edit watch date
            </button>
            <button
              type="button"
              phx-click="remove"
              data-confirm={"Take #{MapSet.size(@selected)} off your watched list? Their ratings stay."}
              class="btn btn-error btn-outline"
              disabled={MapSet.size(@selected) == 0}
            >
              <.icon name="hero-trash" class="h-4 w-4" /> Remove
            </button>
          </div>
        </div>
      </div>

      <%!-- The date editor: one day for everything selected. --%>
      <div
        :if={@owner? and @dating?}
        class="fixed inset-0 z-50 flex items-end justify-center sm:items-center"
        role="dialog"
        aria-modal="true"
        aria-label="Edit watch date"
      >
        <div class="absolute inset-0 bg-black/60" phx-click="date_close"></div>
        <form
          id="date-form"
          phx-submit="date_save"
          phx-change="date_change"
          class="relative max-h-[92svh] w-full max-w-md space-y-4 overflow-y-auto rounded-t-box bg-base-100 p-5 pb-[max(1.25rem,env(safe-area-inset-bottom))] shadow-2xl sm:rounded-box"
        >
          <div>
            <h2 class="text-lg font-semibold">
              When did you watch {if MapSet.size(@selected) == 1, do: "it", else: "them"}?
            </h2>
            <p :if={@whole_title?} class="text-sm text-base-content/60">
              {MapSet.size(@selected)} {if MapSet.size(@selected) == 1, do: "title", else: "titles"} will be put on this day in your history — anywhere back, years if you like. They keep the order they have now.
            </p>
            <p :if={!@whole_title?} class="text-sm text-base-content/60">
              This one is still going, so the show itself has no date to change. A season of it
              does: pick the season you watched and the day you watched it, and its share of the
              hours moves there.
            </p>
          </div>
          <%!-- One title: what it is and when it came out, so the day can be chosen with that in view. --%>
          <div :if={@single} class="rounded-box bg-base-200 px-3 py-2 text-sm">
            <div class="font-medium">{@single.title}</div>
            <div class="text-base-content/70">
              <span :if={@released == :loading}>
                <span class="loading loading-spinner loading-xs"></span> Looking up the release date…
              </span>
              <span :if={is_map(@released)}>
                {if @released.type == "movie", do: "Released", else: "First aired"} {release_day(
                  @released.date
                )}
              </span>
              <span :if={@released == nil}>Release date unknown</span>
            </div>
            <div :if={@single.dated?} class="text-base-content/70">
              In your list on {Calendar.strftime(DateTime.from_unix!(@single.at), "%-d %B %Y")}
            </div>
          </div>
          <%!-- Date it by the calendar of the show: when each season was on. --%>
          <div :if={@air == :loading} class="flex items-center gap-2 text-sm text-base-content/60">
            <span class="loading loading-spinner loading-sm"></span>
            Looking up when each season aired…
          </div>
          <div :if={is_list(@air) and @air != []} class="space-y-1.5">
            <div class="text-sm font-medium">When each season was on</div>
            <ul class="divide-y divide-base-300 overflow-hidden rounded-box border border-base-300 text-sm">
              <li :for={s <- @air} class="flex items-center justify-between gap-2 px-3 py-2">
                <div class="min-w-0">
                  <div class="font-medium">Season {s.number}</div>
                  <div class="text-xs text-base-content/60">
                    {air_day(s.first)} → {air_day(s.last)}{if !s.ended?, do: " · still airing"} · {s.episodes} {if s.episodes ==
                                                                                                                     1,
                                                                                                                   do:
                                                                                                                     "episode",
                                                                                                                   else:
                                                                                                                     "episodes"}
                  </div>
                </div>
                <div class="flex shrink-0 gap-1">
                  <button
                    type="button"
                    phx-click="date_pick"
                    phx-value-date={Date.to_iso8601(s.first)}
                    phx-value-season={s.number}
                    class="btn btn-xs btn-ghost"
                    title="Put the date box on the day this season began"
                  >
                    Start
                  </button>
                  <button
                    type="button"
                    phx-click="date_pick"
                    phx-value-date={Date.to_iso8601(s.last)}
                    phx-value-season={s.number}
                    class="btn btn-xs btn-outline"
                    title="Put the date box on the day this season's last episode aired"
                  >
                    End
                  </button>
                </div>
              </li>
            </ul>
            <p class="text-xs text-base-content/60">
              Remember how many seasons were out when you caught up? Press End on the last one you
              had seen, and save.
            </p>
          </div>
          <%!-- One date field, written day/month/year, with the calendar beside it. The date that is
                sent is the hidden one (`EuDate`): a real date field, in ISO, for the form. --%>
          <div id="date-field" phx-hook="EuDate" class="relative">
            <input
              type="text"
              data-eu-text
              value={Calendar.strftime(@shown_date, "%d/%m/%Y")}
              placeholder="dd/mm/yyyy"
              inputmode="numeric"
              autocomplete="off"
              maxlength="10"
              aria-label="Date, day month year"
              class="input input-bordered w-full pr-12"
              autofocus
            />
            <button
              type="button"
              data-eu-open
              class="btn btn-ghost btn-sm btn-circle absolute right-1.5 top-1/2 -translate-y-1/2"
              aria-label="Open the calendar"
            >
              <.icon name="hero-calendar-days" class="h-5 w-5" />
            </button>
            <input
              type="date"
              name="date"
              data-eu-real
              value={Date.to_iso8601(@shown_date)}
              min="1900-01-01"
              max={@today}
              tabindex="-1"
              aria-hidden="true"
              class="pointer-events-none absolute bottom-0 right-1.5 h-0 w-0 opacity-0"
            />
          </div>
          <%!-- A show whose seasons were watched years apart: date one of them without moving
                the rest. Only offered for a single show laev has episode records for. --%>
          <label :if={@seasons != %{}} class="block space-y-1">
            <span class="text-sm font-medium">Apply to</span>
            <select name="season" class="select select-bordered w-full" required={!@whole_title?}>
              <option :if={@whole_title?} value="">The whole title</option>
              <option :if={!@whole_title?} value="" disabled selected>Pick a season</option>
              <option
                :for={{season, %{episodes: episodes}} <- Enum.sort(@seasons)}
                value={season}
                selected={@season_value == to_string(season)}
              >
                Season {season} only · {episodes} {if episodes == 1,
                  do: "episode",
                  else: "episodes"}
              </option>
            </select>
            <span class="block text-xs text-base-content/60">
              A season takes its share of the show's hours with it: episodes you marked take
              their runtime, episodes you played take what was measured.
            </span>
          </label>
          <p :if={@date_error} class="text-sm text-error">{@date_error}</p>
          <div class="flex flex-wrap items-center justify-between gap-2">
            <button
              :if={@aired_ok?}
              type="button"
              phx-click="date_aired"
              disabled={@aired_busy?}
              class="btn btn-ghost btn-sm"
              title="Each season goes on the day its last episode aired"
            >
              <span :if={@aired_busy?} class="loading loading-spinner loading-xs"></span>
              I watched {if MapSet.size(@selected) == 1, do: "it", else: "them"} as {if MapSet.size(
                                                                                          @selected
                                                                                        ) == 1,
                                                                                        do: "it",
                                                                                        else: "they"} aired
            </button>
            <span :if={!@aired_ok?}></span>
            <div class="flex gap-2">
              <button type="button" phx-click="date_close" class="btn btn-ghost">Cancel</button>
              <button type="submit" class="btn btn-primary">Save</button>
            </div>
          </div>
        </form>
      </div>
    </Layouts.app>
    """
  end

  attr :selected, :boolean, default: false

  # The round tick in a selectable poster's corner.
  # Month headings on or off. They only apply to the newest-first order, so the switch is
  # shown but idle (and says why) when the list is sorted by rating.
  attr :a, :map, required: true
  attr :class, :string, default: ""
  attr :pill, :boolean, default: false

  defp months_toggle(assigns) do
    ~H"""
    <.link
      patch={address(@a, months: not @a.months?)}
      onclick={if @pill, do: "document.activeElement.blur()", else: nil}
      role="switch"
      aria-checked={to_string(@a.months?)}
      class={[
        @pill && "btn btn-sm h-9 gap-1.5 rounded-full border-0 text-sm font-medium",
        @pill && @a.months? && "btn-primary",
        @pill && !@a.months? && "bg-base-200",
        !@pill &&
          "flex items-center justify-between rounded-xl bg-base-200 px-3 py-2 text-sm font-medium",
        @a.sort == :top && "opacity-50",
        @class
      ]}
      title={if @a.sort == :top, do: "Month headings show when sorted by date"}
    >
      <span class="flex items-center gap-1.5">
        <.icon name="hero-calendar-days" class="h-4 w-4" /> By month
      </span>
      <input
        :if={!@pill}
        type="checkbox"
        class="toggle toggle-primary toggle-sm pointer-events-none"
        checked={@a.months?}
        tabindex="-1"
        aria-hidden="true"
      />
    </.link>
    """
  end

  # Only the titles with no watch date, so they can be found and dated in the owner's own time.
  attr :a, :map, required: true
  attr :class, :string, default: ""
  attr :pill, :boolean, default: false

  defp undated_toggle(assigns) do
    ~H"""
    <.link
      patch={address(@a, undated?: not @a.undated?)}
      onclick={if @pill, do: "document.activeElement.blur()", else: nil}
      role="switch"
      aria-checked={to_string(@a.undated?)}
      class={[
        @pill && "btn btn-sm h-9 gap-1.5 rounded-full border-0 text-sm font-medium",
        @pill && @a.undated? && "btn-primary",
        @pill && !@a.undated? && "bg-base-200",
        !@pill &&
          "flex items-center justify-between rounded-xl bg-base-200 px-3 py-2 text-sm font-medium",
        @class
      ]}
      title="Show only titles with no watch date"
    >
      <span class="flex items-center gap-1.5">
        <.icon name="hero-calendar" class="h-4 w-4" /> No date
      </span>
      <input
        :if={!@pill}
        type="checkbox"
        class="toggle toggle-primary toggle-sm pointer-events-none"
        checked={@a.undated?}
        tabindex="-1"
        aria-hidden="true"
      />
    </.link>
    """
  end

  # Which genre: every one, or one of those the kind on show has (films and shows do not share them all).
  attr :a, :map, required: true
  attr :heading, :boolean, default: true

  defp genre_picker(assigns) do
    options =
      case assigns.a.kind do
        :movie -> Roki.Genres.options(:movies)
        :all -> Roki.Genres.all()
        _ -> Roki.Genres.options(:shows)
      end

    assigns = assign(assigns, :options, options)

    ~H"""
    <div>
      <p
        :if={@heading}
        class="px-1 pb-1.5 pt-3 text-xs font-semibold uppercase tracking-wide text-base-content/50"
      >
        Genre
      </p>
      <div class="grid grid-cols-3 gap-1.5">
        <.link
          patch={address(@a, genre: nil)}
          onclick="document.activeElement.blur()"
          class={[
            "btn btn-sm rounded-full border-0 px-1",
            @a.genre == nil && "btn-primary",
            @a.genre != nil && "bg-base-200"
          ]}
        >
          All
        </.link>
        <.link
          :for={{slug, label} <- @options}
          patch={address(@a, genre: slug)}
          onclick="document.activeElement.blur()"
          class={[
            "btn btn-sm rounded-full border-0 px-1 text-xs",
            @a.genre == slug && "btn-primary",
            @a.genre != slug && "bg-base-200"
          ]}
        >
          {label}
        </.link>
      </div>
    </div>
    """
  end

  # Which entries: everything, or only what was finished / is in progress / is up to date / is on hold.
  attr :a, :map, required: true
  attr :heading, :boolean, default: true

  defp status_picker(assigns) do
    assigns = assign(assigns, :statuses, @statuses)

    ~H"""
    <div>
      <p
        :if={@heading}
        class="px-1 pb-1.5 pt-3 text-xs font-semibold uppercase tracking-wide text-base-content/50"
      >
        Show
      </p>
      <div class="grid grid-cols-2 gap-1.5">
        <.link
          patch={address(@a, status: nil)}
          onclick="document.activeElement.blur()"
          class={[
            "btn btn-sm rounded-full border-0",
            @a.status == nil && "btn-primary",
            @a.status != nil && "bg-base-200"
          ]}
        >
          All
        </.link>
        <.link
          :for={{key, label} <- @statuses}
          patch={address(@a, status: key)}
          onclick="document.activeElement.blur()"
          class={[
            "btn btn-sm rounded-full border-0 whitespace-nowrap",
            @a.status == key && "btn-primary",
            @a.status != key && "bg-base-200"
          ]}
        >
          {label}
        </.link>
      </div>
    </div>
    """
  end

  attr :i, :map, required: true
  attr :select?, :boolean, default: false
  attr :selectable?, :boolean, default: false
  attr :selected, :boolean, default: false

  # Over a poster in the grid: where the title stands, and — while selecting — the clear button
  # that takes the click, the ring and the tick.
  defp select_layer(assigns) do
    ~H"""
    <.status_pill item={@i} />
    <button
      :if={@select? and @selectable?}
      type="button"
      phx-click="select_toggle"
      phx-value-key={@i.key}
      aria-pressed={to_string(@selected)}
      aria-label={"Select #{@i.title}"}
      class="absolute inset-0 z-10 cursor-pointer"
    ></button>
    <div
      :if={@select? and @selectable?}
      class={[
        "pointer-events-none absolute inset-x-0 top-0 z-20 aspect-[2/3] rounded-box transition",
        @selected && "ring-4 ring-primary"
      ]}
    >
      <.tick selected={@selected} />
    </div>
    """
  end

  attr :i, :map, required: true
  attr :show_score, :boolean, default: false

  # Under a poster: the day it was watched and the score.
  defp day_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between text-xs text-base-content/50">
      <span>{if @i[:season_no], do: "S#{@i.season_no} · "}{day(@i)}</span>
      <span :if={@i.score != nil and @show_score} class="font-semibold text-warning">
        ★ {Profile.score_text(@i.score)}
      </span>
    </div>
    """
  end

  # The small marker on a title that is not finished: where it stands, and laev's progress line.
  attr :item, :map, required: true

  defp status_pill(assigns) do
    ~H"""
    <span
      :if={!finished?(@item)}
      title={status_title(@item)}
      class="pointer-events-none absolute left-1.5 top-1.5 z-10 inline-flex items-center gap-1 rounded-full bg-black/70 px-1.5 py-1 text-[0.6rem] font-semibold leading-none text-white shadow backdrop-blur-sm"
    >
      <span class={[
        "h-1.5 w-1.5 rounded-full",
        @item.status == "progress" && "bg-warning",
        @item.status == "up_to_date" && "bg-success",
        @item.status == "on_hold" && "bg-base-content/50"
      ]}></span>
      {status_label(@item.status)}
    </span>
    """
  end

  # "Rated": any, or one whole rating, 10 down to 1. A tap on the one already chosen lets it go.
  attr :a, :map, required: true
  attr :heading, :boolean, default: true

  defp rating_picker(assigns) do
    ~H"""
    <div>
      <p
        :if={@heading}
        class="px-1 pb-1.5 pt-3 text-xs font-semibold uppercase tracking-wide text-base-content/50"
      >
        Rated
      </p>
      <div class="grid grid-cols-5 gap-1.5">
        <.link
          :for={n <- 10..1//-1}
          patch={address(@a, rating: if(@a.rating == n, do: nil, else: n))}
          onclick="document.activeElement.blur()"
          aria-label={"Rated #{n}"}
          class={[
            "btn btn-sm rounded-full border-0 px-0 tabular-nums",
            @a.rating == n && "btn-primary",
            @a.rating != n && "bg-base-200"
          ]}
        >
          {n}
        </.link>
      </div>
      <.link
        patch={address(@a, rating: if(@a.rating == :none, do: nil, else: :none))}
        onclick="document.activeElement.blur()"
        class={[
          "btn btn-sm mt-1.5 w-full rounded-full border-0",
          @a.rating == :none && "btn-primary",
          @a.rating != :none && "bg-base-200"
        ]}
      >
        Not rated yet
      </.link>
      <.link
        :if={@a.rating}
        patch={address(@a, rating: nil)}
        onclick="document.activeElement.blur()"
        class="mt-2 block rounded-full py-1.5 text-center text-sm text-base-content/60 hover:bg-base-200"
      >
        Any rating
      </.link>
    </div>
    """
  end

  defp tick(assigns) do
    ~H"""
    <span class={[
      "absolute right-1.5 top-1.5 flex h-6 w-6 items-center justify-center rounded-full border-2 shadow",
      if(@selected,
        do: "border-primary bg-primary text-primary-content",
        else: "border-white bg-black/30 text-transparent"
      )
    ]}>
      <.icon name="hero-check-micro" class="h-4 w-4" />
    </span>
    """
  end

  attr :item, :map, required: true
  attr :select?, :boolean, default: false
  attr :selected, :boolean, default: false
  attr :selectable?, :boolean, default: true
  attr :show_score, :boolean, default: true
  attr :seasons, :list, default: []

  # One title as a line: a small poster, its name, what kind and which year, and on the right
  # the owner's rating and the day.
  defp row(assigns) do
    assigns = assign(assigns, href: href(assigns.item))

    ~H"""
    <%= if @select? and @selectable? do %>
      <button
        type="button"
        phx-click="select_toggle"
        phx-value-key={@item.key}
        aria-pressed={to_string(@selected)}
        class={[
          "flex w-full items-center gap-3 p-2 text-left transition hover:bg-base-200 sm:p-3",
          @selected && "bg-primary/10"
        ]}
      >
        <.row_body item={@item} show_score={@show_score} seasons={@seasons} />
        <span class={[
          "flex h-6 w-6 shrink-0 items-center justify-center rounded-full border-2",
          if(@selected,
            do: "border-primary bg-primary text-primary-content",
            else: "border-base-content/30 text-transparent"
          )
        ]}>
          <.icon name="hero-check-micro" class="h-4 w-4" />
        </span>
      </button>
    <% else %>
      <.link navigate={@href} class="flex items-center gap-3 p-2 transition hover:bg-base-200 sm:p-3">
        <.row_body item={@item} show_score={@show_score} seasons={@seasons} />
      </.link>
    <% end %>
    """
  end

  attr :item, :map, required: true
  attr :show_score, :boolean, default: true
  attr :seasons, :list, default: []

  defp row_body(assigns) do
    ~H"""
    <div class="h-[4.5rem] w-12 shrink-0 overflow-hidden rounded bg-base-300 sm:h-24 sm:w-16">
      <img
        :if={@item.poster}
        src={Roki.Images.local(@item.poster)}
        alt=""
        loading="lazy"
        class="h-full w-full object-cover"
        draggable="false"
      />
    </div>
    <div class="min-w-0 flex-1">
      <div class="truncate font-medium">{@item.title}</div>
      <div class="truncate text-sm text-base-content/60">
        {kind_label(@item)}<span :if={@item.year}> · {@item.year}</span><span
          :if={@item[:season_no]}
          class="font-medium text-base-content/80"
        > · Season {@item.season_no}</span>
      </div>
      <div :if={!finished?(@item)} class="flex items-center gap-1.5 text-xs text-base-content/70">
        <span class={[
          "h-1.5 w-1.5 rounded-full",
          @item.status == "progress" && "bg-warning",
          @item.status == "up_to_date" && "bg-success",
          @item.status == "on_hold" && "bg-base-content/50"
        ]}></span>
        <span class="font-medium">{status_label(@item.status)}</span><span
          :if={@item[:note]}
          class="truncate text-base-content/50"
        > · {@item.note}</span>
      </div>
      <%!-- The seasons with something kept: the day each was watched, and what it was given. The
            day is when it was watched and never moves for a rating. --%>
      <ul
        :if={@seasons != []}
        class="mt-0.5 flex flex-wrap gap-x-3 gap-y-0.5 text-xs text-base-content/60"
      >
        <li :for={s <- @seasons} class="whitespace-nowrap">
          <span class="font-medium">S{s.season}</span><span
            :if={s.score && @show_score}
            class="text-warning"
          > · ★ {Profile.score_text(s.score)}</span>
        </li>
      </ul>
      <div class="text-xs text-base-content/50 sm:hidden">{day(@item)}</div>
    </div>
    <div class="shrink-0 text-right">
      <div :if={@item.score != nil and @show_score} class="font-semibold text-warning">
        ★ {Profile.score_text(@item.score)}
      </div>
      <div :if={@item.score == nil and @show_score} class="text-sm text-base-content/30">
        not rated
      </div>
      <div class="hidden text-sm text-base-content/60 sm:block">{day(@item) || "No date"}</div>
    </div>
    """
  end
end
