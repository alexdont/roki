defmodule RokiWeb.MangaController do
  use RokiWeb, :controller

  # This site's header above the reader's pages, so there is a way back to films, the profile and
  # search. Not on `show` — the chapter reader is a full-screen canvas — and not on the two async
  # fragments, which are rows spliced into a page that already has a header.
  plug :put_layout,
       [html: {RokiWeb.Layouts, :manga}]
       when action not in [:show, :search_extension, :explore_extension]

  # Tierlist, Grid and Comments moved out of the reader and under /:username, where they are
  # the account's own pages: one person's, in this site's plain frame rather than the reader's.
  plug :profile_page when action in [:annotations, :tierlist, :grid]

  defp profile_page(%{params: %{"username" => username}} = conn, _opts) do
    # The site's routes run the plain browser pipeline, which does not look up who is signed in
    # — the reader's own scope does that with :require_auth. Ask here instead, for the scope as
    # well as the user: the header above the page is drawn from the scope, and without it the
    # page renders as though nobody were signed in.
    conn = PhoenixKitWeb.Users.Auth.fetch_phoenix_kit_current_scope(conn, [])
    user = conn.assigns[:phoenix_kit_current_user]

    cond do
      is_nil(user) ->
        conn |> redirect(to: "/phoenix_kit/users/log-in") |> halt()

      String.downcase(to_string(user.username)) != String.downcase(username) ->
        conn |> redirect(to: "/home") |> halt()

      true ->
        put_layout(conn, html: {RokiWeb.Layouts, :page})
    end
  end

  defp profile_page(conn, _opts), do: conn

  alias Roki.Manga.Library
  alias Roki.Manga.Sources
  alias Guise
  alias RokiWeb.MangaHTML

  plug :load_resume_manga

  # ── Reader v2 UI preference ─────────────────────────────────────
  # Persisted per-user in custom_fields["reader_ui_v2"]. V2 is the
  # DEFAULT: only an explicit `false` (burger menu -> "Switch to old
  # reader") serves the v1 pages. When v2 is active, the canonical
  # home + details routes redirect to their v2 counterparts, so every
  # entry point (bookmarks, post-save redirects, nav links) lands on
  # the version the user picked. The /home2 and /manga2 test routes
  # always force v2 regardless of the preference.
  defp reader_v2?(user) do
    user && (user.custom_fields || %{})["reader_ui_v2"] != false
  end

  def home(conn, params) do
    # XHR fetches to "/manga" are the home JSON API — never redirect
    # those, only full page loads.
    if reader_v2?(conn.assigns[:phoenix_kit_current_user]) &&
         get_req_header(conn, "x-requested-with") != ["XMLHttpRequest"] do
      qs = if conn.query_string != "", do: "?" <> conn.query_string, else: ""
      redirect(conn, to: "/manga/home2" <> qs)
    else
      do_home(conn, params, :home)
    end
  end

  # Parallel test route for the redesigned home page (cinematic resume
  # hero, cover-dominant cards, FLIP grid animations). Same data, same
  # JSON branch — only the template differs.
  def home2(conn, params), do: do_home(conn, params, :home2)

  defp do_home(conn, params, template) do
    user = conn.assigns[:phoenix_kit_current_user]
    categories = Library.list_categories(user.uuid)

    # Two URL params control the saved-manga set, mirroring the JS
    # chip cycle: `?category=N` filters TO that category (active),
    # `?exclude=N` filters everything BUT that category (excluded).
    # Active wins if both are sent — the click flow never produces
    # that combination, but a hand-crafted URL would.
    {filter_opt, active_category, excluded_category} =
      case params["category"] do
        id when is_binary(id) and id != "" ->
          case Integer.parse(id) do
            {int_id, ""} -> {[category_id: int_id], int_id, nil}
            _ -> {[], nil, nil}
          end

        _ ->
          case params["exclude"] do
            id when is_binary(id) and id != "" ->
              case Integer.parse(id) do
                {int_id, ""} -> {[exclude_category_id: int_id], nil, int_id}
                _ -> {[], nil, nil}
              end

            _ ->
              {[], nil, nil}
          end
      end

    saved_manga = Library.list_saved_manga(user.uuid, filter_opt)

    case get_req_header(conn, "x-requested-with") do
      ["XMLHttpRequest"] ->
        comment_counts = Library.count_annotations_grouped(user.uuid)
        pairs = Enum.map(saved_manga, &{&1.source, &1.slug})
        cover_paths = Library.list_cover_file_uuids(pairs)
        publication_statuses = Library.list_publication_statuses(pairs)

        manga_json =
          Enum.map(saved_manga, fn m ->
            %{
              source: m.source,
              slug: m.slug,
              title: m.title,
              last_chapter: m.last_chapter,
              max_chapter: m.max_chapter,
              total_chapters: m.total_chapters,
              last_chapter_number: m.last_chapter_number,
              cover_url: MangaHTML.cover_image_src(m, cover_paths),
              source_label: Roki.Manga.Sources.label(m.source),
              comment_count: Map.get(comment_counts, {m.source, m.slug}, 0),
              inserted_at: m.inserted_at && NaiveDateTime.to_iso8601(m.inserted_at),
              updated_at: m.updated_at && NaiveDateTime.to_iso8601(m.updated_at),
              newest_chapter_at: m.newest_chapter_at && DateTime.to_iso8601(m.newest_chapter_at),
              completed: m.completed || false,
              # "paged" or "scroll" — mirrors `MangaHTML.tierlist_kind/1`
              # so the home page's Manga/Manhwa filter chips can route
              # by the user's preferred reading mode for this title.
              kind: MangaHTML.tierlist_kind(m),
              publication_status: MangaHTML.publication_status(m, publication_statuses),
              # Drives the `.btn-progress` fill on the Continue button —
              # nil when the data can't form a percent, integer 0-100
              # otherwise.
              percent_read: Library.chapter_progress_percent(m),
              # Drives the `.chapter-progress` fill on the "Ch. N"
              # badge — how far into the current chapter the user has
              # read.
              chapter_percent:
                MangaHTML.chapter_read_percent(
                  m.last_page,
                  m.last_page_fraction,
                  m.last_chapter_total_pages
                )
            }
          end)

        json(conn, %{ok: true, manga: manga_json})

      _ ->
        if saved_manga == [] && active_category == nil && categories == [] do
          redirect(conn, to: ~p"/manga/explore")
        else
          # Chip count badges always reflect the FULL library, even when
          # the grid itself is category-filtered by the URL params.
          all_manga =
            if filter_opt == [], do: saved_manga, else: Library.list_saved_manga(user.uuid)

          chip_counts = MangaHTML.chip_counts(all_manga)
          category_counts = Library.count_manga_per_category(user.uuid)

          resume_manga =
            if active_category do
              Enum.find(all_manga, &(&1.last_chapter && !&1.completed))
            else
              Enum.find(saved_manga, &(&1.last_chapter && !&1.completed))
            end

          comment_counts = Library.count_annotations_grouped(user.uuid)
          pairs = Enum.map(saved_manga, &{&1.source, &1.slug})

          pairs =
            if resume_manga &&
                 !Enum.any?(pairs, fn {s, sl} ->
                   s == resume_manga.source && sl == resume_manga.slug
                 end) do
              [{resume_manga.source, resume_manga.slug} | pairs]
            else
              pairs
            end

          cover_paths = Library.list_cover_file_uuids(pairs)
          publication_statuses = Library.list_publication_statuses(pairs)

          referer = get_req_header(conn, "referer") |> List.first()
          referer_host = if referer, do: URI.parse(referer).host
          is_internal = referer_host == conn.host
          custom = user.custom_fields || %{}
          auto_resume = !is_internal && custom["auto_resume"] == true
          auto_resume_timer = custom["auto_resume_timer"] || 5

          auto_resume_art_url =
            case custom["auto_resume_art"] do
              uuid when is_binary(uuid) and uuid != "" ->
                PhoenixKit.Modules.Storage.URLSigner.signed_url(uuid, "original")

              _ ->
                nil
            end

          render(conn, template,
            saved_manga: saved_manga,
            resume_manga: resume_manga,
            comment_counts: comment_counts,
            cover_paths: cover_paths,
            publication_statuses: publication_statuses,
            categories: categories,
            active_category: active_category,
            excluded_category: excluded_category,
            chip_counts: chip_counts,
            category_counts: category_counts,
            auto_resume: auto_resume,
            auto_resume_timer: auto_resume_timer,
            auto_resume_art_url: auto_resume_art_url
          )
        end
    end
  end

  def history(conn, params) do
    user = conn.assigns[:phoenix_kit_current_user]
    today = Date.utc_today()

    selected_date =
      case params["date"] do
        <<y::binary-size(4), "-", m::binary-size(2), "-", d::binary-size(2)>> ->
          case Date.new(String.to_integer(y), String.to_integer(m), String.to_integer(d)) do
            {:ok, date} -> date
            _ -> today
          end

        _ ->
          today
      end

    history = Library.list_reading_history_for_date(user.uuid, selected_date)
    hourly_activity = Library.list_hourly_activity_for_date(user.uuid, selected_date)
    activity = Library.list_reading_activity(user.uuid)
    hourly_averages = Library.list_hourly_averages(user.uuid)

    month =
      case params["month"] do
        <<y::binary-size(4), "-", m::binary-size(2)>> ->
          case Date.new(String.to_integer(y), String.to_integer(m), 1) do
            {:ok, date} -> date
            _ -> selected_date |> Date.beginning_of_month()
          end

        _ ->
          selected_date |> Date.beginning_of_month()
      end

    user_timezone = user.user_timezone
    offset_seconds = Library.timezone_offset_seconds(user_timezone)
    user_now = DateTime.utc_now() |> DateTime.add(offset_seconds, :second)

    # Build manga list from activity entries visible in this month's calendar
    last_day = Date.end_of_month(month)
    start_pad = Date.day_of_week(month) - 1
    end_pad = 7 - Date.day_of_week(last_day)
    cal_first = Date.add(month, -start_pad)
    cal_last = Date.add(last_day, end_pad)

    manga_list =
      activity
      |> Enum.filter(fn {date, _} ->
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
          seconds: entries |> Enum.map(& &1.seconds) |> Enum.sum()
        }
      end)
      |> Enum.sort_by(& &1.seconds, :desc)

    # Filter activity if a specific manga is selected
    manga_filter = params["manga"]

    filtered_activity =
      case manga_filter do
        nil ->
          activity

        "" ->
          activity

        filter ->
          [filter_source, filter_slug] = String.split(filter, "/", parts: 2)

          activity
          |> Enum.map(fn {date, entries} ->
            {date,
             Enum.filter(entries, fn e -> e.source == filter_source and e.slug == filter_slug end)}
          end)
          |> Enum.reject(fn {_date, entries} -> entries == [] end)
          |> Map.new()
      end

    # TEMP (beta): minute-resolution reading sessions from the stint
    # package for the selected day — placeholder display until the
    # calendar/timeline rework replaces it.
    stints = Stint.on_date(user.uuid, selected_date, utc_offset: offset_seconds)

    saved_all = Library.list_saved_manga(user.uuid)
    stint_titles = Map.new(saved_all, fn m -> {"manga:#{m.source}/#{m.slug}", m.title} end)

    # Cover art + titles for calendar-cell thumbnails, keyed by series.
    # Prefer locally-stored covers (custom upload, else the metadata
    # mirror) so we can serve sized variants instead of hot-linking.
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

    # Milestones across the visible calendar range, grouped by local
    # day and series — badge rank: completed > caught_up > started.
    month_events =
      Library.library_events_between(user.uuid, cal_first, cal_last, offset_seconds)
      |> Enum.group_by(fn e ->
        e.happened_at |> DateTime.add(offset_seconds, :second) |> DateTime.to_date()
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

    # Discrete chapter-read events for the day — matched to stints by
    # time window in the template ("this session covered ch 129-132").
    chapter_reads = Library.chapter_reads_on_date(user.uuid, selected_date, offset_seconds)

    # Library milestones for the day — completed / caught-up markers.
    library_events = Library.library_events_on_date(user.uuid, selected_date, offset_seconds)

    render(conn, :history,
      history: history,
      hourly_activity: hourly_activity,
      activity: filtered_activity,
      month: month,
      selected_date: selected_date,
      user_now: user_now,
      user_timezone: user_timezone,
      manga_filter: manga_filter,
      manga_list: manga_list,
      hourly_averages: hourly_averages,
      stints: stints,
      stint_titles: stint_titles,
      stint_tz: offset_seconds,
      chapter_reads: chapter_reads,
      library_events: library_events,
      manga_meta: manga_meta,
      month_events: month_events
    )
  end

  def update_auto_resume(conn, %{"enabled" => enabled}) do
    user = conn.assigns[:phoenix_kit_current_user]
    val = enabled in [true, "true", "1"]
    current = user.custom_fields || %{}

    {:ok, _} =
      PhoenixKit.Users.Auth.update_user_custom_fields(user, Map.put(current, "auto_resume", val))

    json(conn, %{ok: true, auto_resume: val})
  end

  def update_auto_resume_art(conn, %{"file_uuid" => file_uuid})
      when is_binary(file_uuid) and file_uuid != "" do
    user = conn.assigns[:phoenix_kit_current_user]
    current = user.custom_fields || %{}

    {:ok, _} =
      PhoenixKit.Users.Auth.update_user_custom_fields(
        user,
        Map.put(current, "auto_resume_art", file_uuid)
      )

    art_url = PhoenixKit.Modules.Storage.URLSigner.signed_url(file_uuid, "original")
    json(conn, %{ok: true, art_url: art_url})
  end

  def update_auto_resume_art(conn, %{"clear" => _}) do
    user = conn.assigns[:phoenix_kit_current_user]
    current = user.custom_fields || %{}

    {:ok, _} =
      PhoenixKit.Users.Auth.update_user_custom_fields(
        user,
        Map.delete(current, "auto_resume_art")
      )

    json(conn, %{ok: true, art_url: nil})
  end

  @valid_timer_values Enum.to_list(2..10)
  @valid_tap_zone_presets ["default", "left_right", "right_left"]

  def update_auto_resume_timer(conn, %{"seconds" => seconds}) do
    user = conn.assigns[:phoenix_kit_current_user]
    val = if is_binary(seconds), do: String.to_integer(seconds), else: seconds

    if val in @valid_timer_values do
      current = user.custom_fields || %{}

      {:ok, _} =
        PhoenixKit.Users.Auth.update_user_custom_fields(
          user,
          Map.put(current, "auto_resume_timer", val)
        )

      json(conn, %{ok: true, auto_resume_timer: val})
    else
      conn |> put_status(422) |> json(%{error: "Invalid timer value"})
    end
  end

  def update_default_tap_zone(conn, %{"preset" => preset}) do
    user = conn.assigns[:phoenix_kit_current_user]

    if preset in @valid_tap_zone_presets do
      current = user.custom_fields || %{}

      {:ok, _} =
        PhoenixKit.Users.Auth.update_user_custom_fields(
          user,
          Map.put(current, "default_tap_zone", preset)
        )

      json(conn, %{ok: true, default_tap_zone: preset})
    else
      conn |> put_status(422) |> json(%{error: "Invalid tap zone preset"})
    end
  end

  def update_default_reading_direction(conn, %{"direction" => direction})
      when direction in ["rtl", "ltr"] do
    user = conn.assigns[:phoenix_kit_current_user]
    current = user.custom_fields || %{}

    {:ok, _} =
      PhoenixKit.Users.Auth.update_user_custom_fields(
        user,
        Map.put(current, "default_reading_direction", direction)
      )

    json(conn, %{ok: true, default_reading_direction: direction})
  end

  def update_default_reading_direction(conn, _params) do
    conn |> put_status(422) |> json(%{error: "Invalid direction"})
  end

  def update_default_smart_scroll(conn, %{"enabled" => enabled}) do
    user = conn.assigns[:phoenix_kit_current_user]
    val = enabled in [true, "true", "1"]
    current = user.custom_fields || %{}

    {:ok, _} =
      PhoenixKit.Users.Auth.update_user_custom_fields(
        user,
        Map.put(current, "default_smart_scroll", val)
      )

    json(conn, %{ok: true, default_smart_scroll: val})
  end

  # Smart panels (paged reader): Next / Prev step through the detected
  # panels of a page, each zoomed and centred, before turning the page.
  # Read client-side from the root layout's `smart-panels` meta tag.
  @doc """
  Which generation of the home and series pages to serve. Was the reader menu's
  "Switch to old reader"; it is a row in the Reading settings now, so it saves the way
  every other preference there does.
  """
  def update_reader_ui_v2(conn, %{"enabled" => enabled}) do
    user = conn.assigns[:phoenix_kit_current_user]
    val = enabled in [true, "true", "1"]
    current = user.custom_fields || %{}

    {:ok, _} =
      PhoenixKit.Users.Auth.update_user_custom_fields(user, Map.put(current, "reader_ui_v2", val))

    json(conn, %{ok: true, reader_ui_v2: val})
  end

  def update_smart_panels(conn, %{"enabled" => enabled}) do
    user = conn.assigns[:phoenix_kit_current_user]
    val = enabled in [true, "true", "1"]
    current = user.custom_fields || %{}

    {:ok, _} =
      PhoenixKit.Users.Auth.update_user_custom_fields(user, Map.put(current, "smart_panels", val))

    json(conn, %{ok: true, smart_panels: val})
  end

  @doc """
  Global default page padding for the scroll (manhwa) reader, held
  separately per form factor: a 70% shrink that frames the strip nicely on
  a wide monitor would leave a phone with a sliver of image.

  Stored as a shrink percentage, 0-90, matching the reader's slider. Either
  key may be sent alone; whichever is present is validated and written.
  """
  def update_default_page_padding(conn, params) do
    user = conn.assigns[:phoenix_kit_current_user]
    current = user.custom_fields || %{}

    updated =
      Enum.reduce(["desktop", "mobile"], current, fn form_factor, acc ->
        case parse_padding_pct(params[form_factor]) do
          {:ok, pct} -> Map.put(acc, "default_page_padding_#{form_factor}", pct)
          :error -> acc
        end
      end)

    if updated == current do
      conn |> put_status(422) |> json(%{error: "Invalid padding"})
    else
      {:ok, _} = PhoenixKit.Users.Auth.update_user_custom_fields(user, updated)

      json(conn, %{
        ok: true,
        desktop: updated["default_page_padding_desktop"],
        mobile: updated["default_page_padding_mobile"]
      })
    end
  end

  defp parse_padding_pct(nil), do: :error
  defp parse_padding_pct(n) when is_integer(n) and n >= 0 and n <= 90, do: {:ok, n}

  defp parse_padding_pct(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n >= 0 and n <= 90 -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_padding_pct(_), do: :error

  @valid_jump_styles ["smooth", "instant"]
  @valid_scan_distances Enum.to_list(1..5)
  @valid_gutter_tolerances [50, 300, 800, 1500]
  @valid_min_gutter_widths [20, 50, 100]

  def update_smart_scroll_config(conn, %{"config" => config}) when is_map(config) do
    user = conn.assigns[:phoenix_kit_current_user]

    validated = %{}

    validated =
      case config["jump_style"] do
        v when v in @valid_jump_styles -> Map.put(validated, "jump_style", v)
        _ -> validated
      end

    validated =
      case config["scan_distance"] do
        v when is_number(v) and v >= 1 and v <= 5 ->
          Map.put(validated, "scan_distance", v)

        v when is_binary(v) ->
          case Integer.parse(v) do
            {n, ""} when n in @valid_scan_distances -> Map.put(validated, "scan_distance", n)
            _ -> validated
          end

        _ ->
          validated
      end

    validated =
      case config["long_panel_steps"] do
        v when is_boolean(v) -> Map.put(validated, "long_panel_steps", v)
        _ -> validated
      end

    validated =
      case config["gutter_tolerance"] do
        v when is_integer(v) and v in @valid_gutter_tolerances ->
          Map.put(validated, "gutter_tolerance", v)

        v when is_number(v) and round(v) in @valid_gutter_tolerances ->
          Map.put(validated, "gutter_tolerance", round(v))

        v when is_binary(v) ->
          case Integer.parse(v) do
            {n, ""} when n in @valid_gutter_tolerances ->
              Map.put(validated, "gutter_tolerance", n)

            _ ->
              validated
          end

        _ ->
          validated
      end

    validated =
      case config["min_gutter_width"] do
        v when is_integer(v) and v in @valid_min_gutter_widths ->
          Map.put(validated, "min_gutter_width", v)

        v when is_number(v) and round(v) in @valid_min_gutter_widths ->
          Map.put(validated, "min_gutter_width", round(v))

        v when is_binary(v) ->
          case Integer.parse(v) do
            {n, ""} when n in @valid_min_gutter_widths ->
              Map.put(validated, "min_gutter_width", n)

            _ ->
              validated
          end

        _ ->
          validated
      end

    current = user.custom_fields || %{}
    existing = Map.get(current, "smart_scroll_config", %{})
    merged = Map.merge(existing, validated)

    {:ok, _} =
      PhoenixKit.Users.Auth.update_user_custom_fields(
        user,
        Map.put(current, "smart_scroll_config", merged)
      )

    json(conn, %{ok: true, smart_scroll_config: merged})
  end

  def update_smart_scroll_config(conn, _params) do
    conn |> put_status(422) |> json(%{error: "Invalid config"})
  end

  @doc """
  The reader's old addresses for the pages that moved under `/:username` — Comments, Tierlist,
  Grid and History. They are the account's own pages now, reached from the account menu, and
  the reader's menus still point here.
  """
  def moved(conn, _params) do
    username = conn.assigns[:phoenix_kit_current_user].username
    page = conn.request_path |> String.split("/") |> List.last()
    redirect(conn, to: "/#{username}/#{page}")
  end

  @doc """
  `/manga/settings` -> `/:username/settings`, whose Reading section now carries the reader's
  preferences (`RokiWeb.MangaSettings`). The reader's own settings page is gone; its menus
  and `RokiWeb.TrackerController`'s return link still point here.
  """
  def settings(conn, _params) do
    username = conn.assigns[:phoenix_kit_current_user].username
    redirect(conn, to: "/#{username}/settings#reading")
  end

  def update_timezone(conn, %{"offset" => offset}) do
    user = conn.assigns[:phoenix_kit_current_user]
    offset_str = to_string(offset)

    case Float.parse(offset_str) do
      {n, _} when n >= -12 and n <= 14 ->
        val = if n == trunc(n), do: to_string(trunc(n)), else: offset_str
        {:ok, _} = PhoenixKit.Users.Auth.update_user_profile(user, %{user_timezone: val})
        json(conn, %{ok: true, timezone: val})

      _ ->
        conn |> put_status(422) |> json(%{error: "Invalid timezone offset"})
    end
  end

  def categories(conn, _params) do
    user = conn.assigns[:phoenix_kit_current_user]
    categories = Library.list_categories(user.uuid)
    render(conn, :categories, categories: categories)
  end

  def search(conn, params) do
    query = (params["q"] || "") |> String.trim()
    source = params["source"]
    user = conn.assigns[:phoenix_kit_current_user]

    others_saved =
      if query != "" and user do
        results = Library.search_saved_across_users(query)
        cover_paths = Library.list_cover_file_uuids(Enum.map(results, &{&1.source, &1.slug}))
        Enum.map(results, &Map.put(&1, :cover_src, MangaHTML.cover_image_src(&1, cover_paths)))
      else
        []
      end

    cond do
      query == "" ->
        render(conn, :search,
          query: "",
          mode: :all,
          results_grouped: [],
          results: [],
          others_saved: [],
          kotatsu_pending: []
        )

      # Single kotatsu extension: ?source=kotatsu:WEEBCENTRAL
      source != nil and String.starts_with?(source, "kotatsu:") ->
        ext = String.replace_prefix(source, "kotatsu:", "")

        {results, error} =
          case Roki.Manga.MangaSource.Kotatsu.search(ext, query, 1) do
            {:ok, results} -> {results, nil}
            {:error, reason} -> {[], reason}
          end

        render(conn, :search,
          query: query,
          mode: :kotatsu_single,
          kotatsu_source: ext,
          kotatsu_error: error,
          results: results,
          results_grouped: [],
          others_saved: others_saved,
          kotatsu_pending: []
        )

      source != nil and Sources.valid?(source) ->
        mod = Sources.module(source)

        case mod.search(query) do
          {:ok, results} ->
            render(conn, :search,
              query: query,
              mode: :single,
              source: source,
              source_label: Sources.label(source),
              results: results,
              results_grouped: [],
              others_saved: others_saved,
              kotatsu_pending: []
            )

          {:error, reason} ->
            conn
            |> put_flash(:error, "Search failed: #{inspect(reason)}")
            |> render(:search,
              query: query,
              mode: :single,
              source: source,
              source_label: Sources.label(source),
              results: [],
              results_grouped: [],
              others_saved: others_saved,
              kotatsu_pending: []
            )
        end

      true ->
        # Built-in scrapers the user has enabled (Settings → Source
        # extensions; absent setting = all of them).
        native_enabled =
          MapSet.new(Roki.Manga.MangaSource.Extensions.enabled_native(user))

        # Fetch results from the enabled sources in parallel
        all_results =
          Sources.all()
          |> Enum.filter(fn {key, _} -> MapSet.member?(native_enabled, key) end)
          |> Task.async_stream(
            fn {key, label} ->
              mod = Sources.module(key)

              case mod.search(query) do
                {:ok, results} -> {key, label, results}
                {:error, _} -> {key, label, []}
              end
            end,
            timeout: 15_000,
            on_timeout: :kill_task
          )
          |> Enum.map(fn
            {:ok, result} -> result
            {:exit, _} -> nil
          end)
          |> Enum.reject(&is_nil/1)
          |> Map.new(fn {key, label, results} -> {key, {label, results}} end)

        # Group results by language; disabled sources drop out of the
        # display entirely, as do languages left empty by that.
        results_grouped =
          Sources.grouped()
          |> Enum.map(fn {lang_label, sources} ->
            source_results =
              sources
              |> Enum.filter(fn {key, _} -> MapSet.member?(native_enabled, key) end)
              |> Enum.map(fn {key, _label} ->
                case Map.get(all_results, key) do
                  {label, results} -> {key, label, results}
                  nil -> {key, Sources.label(key) || key, []}
                end
              end)

            {lang_label, source_results}
          end)
          |> Enum.reject(fn {_lang, sources} -> sources == [] end)

        # Enabled kotatsu extensions load ASYNC from the browser (one
        # fragment request per source, see search_extension/2) so the
        # page itself renders without waiting on any live site — the
        # slowest source used to hold the whole page for up to 20s.
        render(conn, :search,
          query: query,
          mode: :all,
          results_grouped: results_grouped,
          results: [],
          others_saved: others_saved,
          kotatsu_pending: kotatsu_pending(user)
        )
    end
  end

  # [{name, label, searchable?}] for the enabled extensions — the
  # placeholders the page renders before the async rows arrive.
  defp kotatsu_pending(nil), do: []

  defp kotatsu_pending(user) do
    case Roki.Manga.MangaSource.Extensions.enabled(user) do
      [] ->
        []

      enabled ->
        metas =
          case Roki.Manga.MangaSource.Kotatsu.list_sources() do
            {:ok, sources} -> Map.new(sources, &{&1.id, &1})
            _ -> %{}
          end

        Enum.map(enabled, fn name ->
          meta = metas[name]
          {name, (meta && meta.title) || name, is_nil(meta) or meta.search_supported}
        end)
    end
  end

  @doc """
  Async fragment: one extension's search results row (layout-free
  HTML injected by the search page's loader script).
  """
  def search_extension(conn, %{"source" => name, "q" => q}) do
    user = conn.assigns[:phoenix_kit_current_user]

    outcome =
      if name in Roki.Manga.MangaSource.Extensions.enabled(user) do
        Roki.Manga.MangaSource.Kotatsu.search(name, String.trim(q || ""), 1)
      else
        {:error, :not_enabled}
      end

    conn
    |> put_root_layout(false)
    |> put_layout(false)
    |> render(:ext_search_row, ext_name: name, outcome: outcome, query: q)
  end

  @doc "Async fragment: one extension's explore catalog row."
  def explore_extension(conn, %{"source" => name}) do
    user = conn.assigns[:phoenix_kit_current_user]

    outcome =
      if name in Roki.Manga.MangaSource.Extensions.enabled(user) do
        Roki.Manga.MangaSource.Kotatsu.catalog(name, 1)
      else
        {:error, :not_enabled}
      end

    conn
    |> put_root_layout(false)
    |> put_layout(false)
    |> render(:ext_explore_row, ext_name: name, outcome: outcome)
  end

  def explore(conn, _params) do
    user = conn.assigns[:phoenix_kit_current_user]
    manga = Library.list_explore()
    comment_counts = Library.count_annotations_grouped(user.uuid)
    pairs = Enum.map(manga, &{&1.source, &1.slug})
    cover_paths = Library.list_cover_file_uuids(pairs)

    # Catalog rows for enabled kotatsu extensions load ASYNC from the
    # browser (one fragment request per source, explore_extension/2)
    # so the page never waits on a live site.
    render(conn, :explore,
      manga: manga,
      comment_counts: comment_counts,
      cover_paths: cover_paths,
      kotatsu_pending: kotatsu_pending(user)
    )
  end

  @doc """
  `/manga/stats` -> `/:username/stats`, whose Reading section now carries the reader's
  reading time (`RokiWeb.MangaStats`). The reader's own stats page is gone; its menus
  still point here.
  """
  def stats(conn, _params) do
    username = conn.assigns[:phoenix_kit_current_user].username
    redirect(conn, to: "/#{username}/stats#reading")
  end

  def index(conn, %{"source" => source, "slug" => slug} = params) do
    if reader_v2?(conn.assigns[:phoenix_kit_current_user]) do
      qs = if conn.query_string != "", do: "?" <> conn.query_string, else: ""
      redirect(conn, to: ~p"/manga/manga2/#{source}/#{slug}" <> qs)
    else
      do_index(conn, params, :index)
    end
  end

  # Parallel test route for the redesigned details page (v2 hero +
  # About card + chapter tiles). Same data and modals — template only.
  def index2(conn, params), do: do_index(conn, params, :index2)

  defp do_index(conn, %{"source" => source, "slug" => slug} = params, template) do
    # Kotatsu browse links carry the search-result title as `?st=` —
    # register it as the details-skeleton seed (some parsers never
    # re-parse the title, see Roki.Manga.KotatsuSource).
    with "kotatsu" <- source,
         st when is_binary(st) and st != "" <- params["st"],
         {:ok, name, url, _} <- Roki.Manga.KotatsuSource.parse_slug(slug) do
      Roki.Manga.KotatsuSource.remember_title(name, url, st)
    else
      _ -> :ok
    end

    with true <- Sources.valid?(source),
         mod when not is_nil(mod) <- Sources.module(source) do
      user = conn.assigns[:phoenix_kit_current_user]

      search_back_url =
        case params do
          %{"sq" => q} when q != "" ->
            query = if params["ss"], do: %{q: q, source: params["ss"]}, else: %{q: q}
            ~p"/manga/search?#{query}"

          _ ->
            nil
        end

      search_params =
        case params do
          %{"sq" => q} when q != "" ->
            if params["ss"], do: %{sq: q, ss: params["ss"]}, else: %{sq: q}

          _ ->
            %{}
        end

      saved_manga = if user, do: Library.get_saved_manga(user.uuid, source, slug)
      metadata = Library.get_manga_metadata(source, slug)

      manga_result =
        if metadata do
          {:ok, Library.metadata_to_manga_map(metadata)}
        else
          mod.get_manga(slug)
        end

      case manga_result do
        {:ok, manga} ->
          # MyAnimeList enrichment for THIS user (if they've linked
          # the title): MAL's synopsis/genres win, `:mal` carries
          # score/rank/link/cover for display.
          mal = user && Library.mal_data(user.uuid, source, slug)
          manga = Library.apply_mal_enrichment(manga, mal)

          if saved_manga do
            last_num = RokiWeb.MangaHTML.last_chapter_number(manga.chapters)

            {prev_total, new_total} =
              Library.update_total_chapters(
                user.uuid,
                source,
                slug,
                length(manga.chapters),
                last_num
              )

            Library.notify_new_chapters(
              user.uuid,
              source,
              slug,
              manga.title,
              prev_total,
              new_total
            )
          end

          reading_mode = if saved_manga, do: saved_manga.reading_mode, else: manga.reading_mode

          # Fabledex story data — rendered from the locally saved copy
          # only. Missing / day-old rows re-sync in the background (MAL
          # link first, then title match), landing on the next load.
          story_row = Roki.Manga.Fabledex.get(source, slug)

          Roki.Manga.Fabledex.sync_async_if_stale(story_row, source, slug,
            mal_id: mal && mal["id"],
            titles: [saved_manga && saved_manga.title, manga.title],
            alt_titles: manga[:alt_titles]
          )

          story_arcs = Roki.Manga.Fabledex.arcs(story_row)
          story_volumes = Roki.Manga.Fabledex.volumes(story_row)
          chapter_titles = Roki.Manga.Fabledex.chapter_titles(story_row)

          # Finished chapters feed the arc spoiler unlock — only needed
          # when there are arcs to unlock.
          finished_chapters =
            if (story_arcs != [] or story_volumes != []) and saved_manga,
              do: Library.finished_chapters(user.uuid, source, slug),
              else: []

          chapter_comment_counts = Library.count_annotations_by_chapter(source, slug, user.uuid)
          comment_count = chapter_comment_counts |> Map.values() |> Enum.sum()

          cover_img_src =
            cond do
              saved_manga && saved_manga.cover_file_uuid ->
                PhoenixKit.Modules.Storage.URLSigner.signed_url(
                  saved_manga.cover_file_uuid,
                  "original"
                )

              metadata && metadata.cover_file_uuid ->
                PhoenixKit.Modules.Storage.URLSigner.signed_url(
                  metadata.cover_file_uuid,
                  "original"
                )

              true ->
                ~p"/manga/proxy/image?#{%{url: manga.cover_url}}"
            end

          categories = Library.list_categories(user.uuid)

          manga_category_ids =
            if saved_manga, do: Library.list_manga_category_ids(saved_manga.id), else: []

          manga_readers =
            if user do
              Library.manga_readers(source, slug, user.uuid)
              |> Enum.map(&resolve_avatar_url/1)
            else
              []
            end

          reading_rank = user && Library.user_reading_rank(user.uuid, source, slug)
          user_tier = user && Library.user_tier_for(user.uuid, source, slug)
          reading_estimate = saved_manga && Library.completion_estimate(saved_manga)
          percent_read = saved_manga && Library.chapter_progress_percent(saved_manga)

          current_chapter_percent =
            saved_manga &&
              RokiWeb.MangaHTML.chapter_read_percent(
                saved_manga.last_page,
                saved_manga.last_page_fraction,
                saved_manga.last_chapter_total_pages
              )

          render(conn, template,
            source: source,
            source_url: Sources.source_url(source, slug),
            source_label: Sources.label(source),
            slug: slug,
            manga: manga,
            display_title: (saved_manga && saved_manga.title) || manga.title,
            saved: !!saved_manga,
            manga_readers: manga_readers,
            reading_mode: reading_mode,
            last_chapter: saved_manga && saved_manga.last_chapter,
            max_chapter: saved_manga && (saved_manga.max_chapter || saved_manga.last_chapter),
            last_page: saved_manga && saved_manga.last_page,
            last_page_fraction: saved_manga && saved_manga.last_page_fraction,
            last_chapter_total_pages: saved_manga && saved_manga.last_chapter_total_pages,
            reading_seconds: saved_manga && saved_manga.reading_seconds,
            reading_seconds_adjusted: saved_manga && saved_manga.reading_seconds_adjusted,
            onsite_activity_seconds:
              (saved_manga && Library.onsite_activity_seconds(user.uuid, source, slug)) || 0,
            reading_seconds_offsite: saved_manga && saved_manga.reading_seconds_offsite,
            reading_seconds_offsite_approximate:
              saved_manga && saved_manga.reading_seconds_offsite_approximate,
            date_started:
              case saved_manga && Library.started_event_at(user.uuid, source, slug) do
                %DateTime{} = dt ->
                  dt
                  |> DateTime.add(Library.timezone_offset_seconds(user.user_timezone), :second)
                  |> DateTime.to_date()

                _ ->
                  nil
              end,
            last_read_at: saved_manga && saved_manga.updated_at,
            comment_count: comment_count,
            chapter_comment_counts: chapter_comment_counts,
            story_arcs: story_arcs,
            story_volumes: story_volumes,
            chapter_titles: chapter_titles,
            finished_chapters: finished_chapters,
            cover_img_src: cover_img_src,
            search_back_url: search_back_url,
            search_params: search_params,
            categories: categories,
            manga_category_ids: manga_category_ids,
            current_category_id: saved_manga && saved_manga.category_id,
            completed: saved_manga && saved_manga.completed,
            reading_rank: reading_rank,
            user_tier: user_tier,
            reading_estimate: reading_estimate,
            percent_read: percent_read,
            current_chapter_percent: current_chapter_percent
          )

        {:error, reason} ->
          conn
          |> put_flash(:error, "Failed to load manga: #{inspect(reason)}")
          |> render(template,
            source: source,
            source_url: Sources.source_url(source, slug),
            source_label: Sources.label(source),
            slug: slug,
            manga: nil,
            display_title: nil,
            saved: false,
            reading_mode: "scroll",
            last_chapter: nil,
            max_chapter: nil,
            last_page: nil,
            last_page_fraction: nil,
            last_chapter_total_pages: nil,
            reading_seconds: nil,
            reading_seconds_adjusted: nil,
            onsite_activity_seconds: 0,
            reading_seconds_offsite: nil,
            reading_seconds_offsite_approximate: false,
            date_started: nil,
            last_read_at: nil,
            comment_count: 0,
            chapter_comment_counts: %{},
            story_arcs: [],
            story_volumes: [],
            chapter_titles: %{},
            finished_chapters: [],
            cover_img_src: nil,
            search_back_url: nil,
            search_params: %{},
            categories: [],
            manga_category_ids: [],
            current_category_id: nil,
            completed: false,
            reading_rank: nil,
            user_tier: nil,
            reading_estimate: nil,
            percent_read: nil,
            current_chapter_percent: nil
          )
      end
    else
      _ -> send_resp(conn, 404, "Unknown source")
    end
  end

  # Returns the SOURCE SKELETON only (no live searches) — the modal
  # renders spinners per source and fetches each one's results in
  # parallel from migrate_search_one/2, same async pattern as the
  # search/explore pages. Universe = the user's enabled built-in
  # scrapers + enabled kotatsu extensions.
  def migrate_search(conn, %{"source" => source, "slug" => _slug} = params) do
    query = (params["q"] || "") |> String.trim()
    user = conn.assigns[:phoenix_kit_current_user]

    if query == "" do
      json(conn, %{groups: []})
    else
      native_enabled = MapSet.new(Roki.Manga.MangaSource.Extensions.enabled_native(user))

      native_groups =
        Sources.grouped()
        |> Enum.map(fn {lang_label, sources} ->
          entries =
            sources
            |> Enum.filter(fn {key, _label} -> MapSet.member?(native_enabled, key) end)
            |> Enum.reject(fn {key, _label} -> key == source end)
            |> Enum.map(fn {key, label} -> %{source: key, ext: nil, label: label} end)

          %{lang: lang_label, sources: entries}
        end)
        |> Enum.reject(fn %{sources: sources} -> sources == [] end)

      ext_entries =
        for {name, label, searchable} <- kotatsu_pending(user),
            searchable,
            do: %{source: "kotatsu", ext: name, label: label}

      groups =
        native_groups ++
          if(ext_entries == [], do: [], else: [%{lang: "Extensions", sources: ext_entries}])

      json(conn, %{groups: groups})
    end
  end

  @doc """
  One migrate-modal source's results (async fragment JSON): `native`
  names a built-in scraper key, `ext` a kotatsu extension. Kotatsu
  targets use source "kotatsu" + composite slug and sidecar cover
  URLs (which /manga/proxy/image knows how to fetch).
  """
  def migrate_search_one(conn, %{"q" => q} = params) do
    user = conn.assigns[:phoenix_kit_current_user]
    query = String.trim(q || "")

    results =
      cond do
        query == "" ->
          []

        (ext = params["ext"]) not in [nil, ""] ->
          if ext in Roki.Manga.MangaSource.Extensions.enabled(user) do
            case Roki.Manga.MangaSource.Kotatsu.search(ext, query, 1) do
              {:ok, results} ->
                results
                |> Enum.take(10)
                |> Enum.map(fn r ->
                  %{
                    slug: Roki.Manga.KotatsuSource.build_slug(ext, r.ref.url),
                    title: r.title,
                    cover_url: Roki.Manga.KotatsuSource.sidecar_image_url(ext, r.cover_url)
                  }
                end)

              _ ->
                []
            end
          else
            []
          end

        (key = params["native"]) not in [nil, ""] ->
          with true <- key in Roki.Manga.MangaSource.Extensions.enabled_native(user),
               mod when not is_nil(mod) <- Sources.module(key),
               {:ok, results} <- mod.search(query) do
            results
            |> Enum.take(10)
            |> Enum.map(&%{slug: &1.slug, title: &1.title, cover_url: &1.cover_url})
          else
            _ -> []
          end

        true ->
          []
      end

    json(conn, %{results: results})
  end

  def migrate(conn, %{"source" => source, "slug" => slug} = params) do
    with true <- Sources.valid?(source),
         true <- Sources.valid?(params["target_source"]) do
      user = conn.assigns[:phoenix_kit_current_user]

      opts = %{
        "migrate_progress" => params["migrate_progress"] in [true, "true", "1"],
        "migrate_categories" => params["migrate_categories"] in [true, "true", "1"],
        "migrate_time" => params["migrate_time"] in [true, "true", "1"]
      }

      target_source = params["target_source"]
      target_slug = params["target_slug"]
      target_title = params["target_title"] || target_slug
      target_cover_url = params["target_cover_url"] || ""

      # Kotatsu targets: register the title as the details-skeleton
      # seed so seed-keeping parsers resolve the migrated title.
      if target_source == "kotatsu" do
        case Roki.Manga.KotatsuSource.parse_slug(target_slug) do
          {:ok, name, url, _} -> Roki.Manga.KotatsuSource.remember_title(name, url, target_title)
          _ -> :ok
        end
      end

      case Library.migrate_manga(
             user.uuid,
             {source, slug},
             {target_source, target_slug, target_title, target_cover_url},
             opts
           ) do
        {:ok, :ok} ->
          json(conn, %{ok: true, redirect_to: ~p"/manga/#{target_source}/#{target_slug}"})

        {:error, reason} ->
          conn |> put_status(422) |> json(%{error: "Migration failed: #{inspect(reason)}"})
      end
    else
      _ -> conn |> put_status(404) |> json(%{error: "Unknown source"})
    end
  end

  def toggle_completed(conn, %{"source" => source, "slug" => slug}) do
    if Sources.valid?(source) do
      user = conn.assigns[:phoenix_kit_current_user]
      saved_manga = Library.get_saved_manga(user.uuid, source, slug)

      if saved_manga do
        if saved_manga.completed do
          Library.unmark_completed(user.uuid, source, slug)
        else
          last_chapter = find_last_chapter(source, slug)
          Library.mark_completed(user.uuid, source, slug, last_chapter, user.user_timezone)
        end
      end

      redirect(conn, to: ~p"/manga/#{source}/#{slug}")
    else
      send_resp(conn, 404, "Unknown source")
    end
  end

  # ── MyAnimeList linking (enrichment) ──────────────────────────────

  @doc "Search MAL by title for the link modal (JSON)."
  def mal_search(conn, %{"q" => q}) do
    query = String.trim(q || "")

    results =
      case Roki.Manga.Trackers.MAL.search(query, Roki.Manga.Trackers.MAL.app_client_id()) do
        {:ok, list} ->
          Enum.map(list, fn r ->
            %{id: r.id, title: r.title, cover_url: r.cover_url, score: r.score, year: r.year}
          end)

        _ ->
          []
      end

    json(conn, %{results: results})
  end

  @doc "Link the title to a MAL id for this user, then back to details."
  def mal_link(conn, %{"source" => source, "slug" => slug, "mal_id" => mal_id}) do
    user = conn.assigns[:phoenix_kit_current_user]

    conn =
      with {id, _} <- Integer.parse(to_string(mal_id)),
           {:ok, _} <-
             Library.link_mal_manga(
               user.uuid,
               source,
               slug,
               id,
               Roki.Manga.Trackers.MAL.app_client_id()
             ) do
        put_flash(conn, :info, "Linked to MyAnimeList")
      else
        _ -> put_flash(conn, :error, "Could not link to MyAnimeList")
      end

    redirect(conn, to: ~p"/manga/#{source}/#{slug}")
  end

  def mal_unlink(conn, %{"source" => source, "slug" => slug}) do
    user = conn.assigns[:phoenix_kit_current_user]
    Library.unlink_mal_manga(user.uuid, source, slug)

    conn
    |> put_flash(:info, "Unlinked from MyAnimeList")
    |> redirect(to: ~p"/manga/#{source}/#{slug}")
  end

  @doc "Re-pull fresh MAL data (rating, status, years) for a linked title."
  def mal_refresh(conn, %{"source" => source, "slug" => slug}) do
    user = conn.assigns[:phoenix_kit_current_user]

    conn =
      case Library.mal_data(user.uuid, source, slug) do
        %{"id" => mal_id} when is_integer(mal_id) ->
          case Library.link_mal_manga(
                 user.uuid,
                 source,
                 slug,
                 mal_id,
                 Roki.Manga.Trackers.MAL.app_client_id()
               ) do
            {:ok, _} -> put_flash(conn, :info, "MyAnimeList info updated")
            _ -> put_flash(conn, :error, "Could not update from MyAnimeList")
          end

        _ ->
          put_flash(conn, :error, "This title isn't linked to MyAnimeList")
      end

    redirect(conn, to: ~p"/manga/#{source}/#{slug}")
  end

  defp find_last_chapter(source, slug) do
    case Library.get_manga_metadata(source, slug) do
      %{data: %{"chapters" => chapters}} when is_list(chapters) and chapters != [] ->
        List.last(chapters)

      _ ->
        case Sources.module(source) do
          nil ->
            nil

          mod ->
            case mod.get_manga(slug) do
              {:ok, manga} -> List.last(manga.chapters || [])
              _ -> nil
            end
        end
    end
  end

  def save(conn, %{"source" => source, "slug" => slug}) do
    with true <- Sources.valid?(source),
         mod when not is_nil(mod) <- Sources.module(source) do
      user = conn.assigns[:phoenix_kit_current_user]

      case mod.get_manga(slug) do
        {:ok, manga} ->
          cover_file_uuid = download_and_store_cover(manga.cover_url, user.uuid)

          Library.upsert_manga_metadata(%{
            source: source,
            slug: slug,
            title: manga.title,
            cover_url: manga.cover_url,
            cover_file_uuid: cover_file_uuid,
            alt_titles: manga.alt_titles,
            status: manga.status,
            reading_direction: manga.reading_direction,
            reading_mode: manga.reading_mode,
            written_by: manga.written_by,
            illustrated_by: manga.illustrated_by,
            year: manga.year,
            genres: manga.genres,
            synopsis: manga.synopsis,
            chapters: manga.chapters,
            chapter_dates: manga.chapter_dates
          })

          save_result =
            Library.save_manga(user.uuid, %{
              source: source,
              slug: slug,
              title: manga.title,
              cover_url: manga.cover_url,
              reading_mode: manga.reading_mode,
              total_chapters: length(manga.chapters),
              last_chapter_number: RokiWeb.MangaHTML.last_chapter_number(manga.chapters)
            })

          # An invalid changeset used to flash "Saved" while saving
          # nothing (e.g. a source without a usable cover/title).
          conn =
            case save_result do
              {:ok, _} ->
                put_flash(conn, :info, "Saved #{manga.title}")

              {:error, changeset} ->
                fields = changeset.errors |> Keyword.keys() |> Enum.map_join(", ", &to_string/1)
                put_flash(conn, :error, "Could not save: source gave no usable #{fields}")
            end

          redirect(conn, to: ~p"/manga/#{source}/#{slug}")

        {:error, _reason} ->
          conn
          |> put_flash(:error, "Failed to save manga")
          |> redirect(to: ~p"/manga/#{source}/#{slug}")
      end
    else
      _ -> send_resp(conn, 404, "Unknown source")
    end
  end

  def unsave(conn, %{"source" => source, "slug" => slug}) do
    if Sources.valid?(source) do
      user = conn.assigns[:phoenix_kit_current_user]
      Library.unsave_manga(user.uuid, source, slug)

      conn
      |> put_flash(:info, "Removed from saved")
      |> redirect(to: ~p"/manga/#{source}/#{slug}")
    else
      send_resp(conn, 404, "Unknown source")
    end
  end

  def refresh(conn, %{"source" => source, "slug" => slug}) do
    user = conn.assigns[:phoenix_kit_current_user]

    case do_refresh_one(user, source, slug) do
      {:ok, %{title: title}} ->
        conn
        |> put_flash(:info, "Refreshed #{title}")
        |> redirect(to: ~p"/manga/#{source}/#{slug}")

      {:error, :unknown_source} ->
        send_resp(conn, 404, "Unknown source")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Failed to refresh manga")
        |> redirect(to: ~p"/manga/#{source}/#{slug}")
    end
  end

  @doc """
  Bulk-refresh every saved manga the user has caught up to. Each
  title goes through the same per-manga scrape + persist + notify
  path as the explicit refresh button, so any newly-discovered
  chapters fire `notify_new_chapters` and surface in the bell
  exactly the way a single refresh would. Errors on individual
  titles are counted but never abort the loop — one dead source
  shouldn't stall the rest.
  """
  def sync_caught_up(conn, _params) do
    user = conn.assigns[:phoenix_kit_current_user]

    manga_list = Library.list_caught_up_saved_manga(user.uuid)

    stats =
      Enum.reduce(manga_list, %{refreshed: 0, with_new: 0, errors: 0, new_total: 0}, fn m, acc ->
        case do_refresh_one(user, m.source, m.slug) do
          {:ok, %{delta: delta}} when delta > 0 ->
            %{
              acc
              | refreshed: acc.refreshed + 1,
                with_new: acc.with_new + 1,
                new_total: acc.new_total + delta
            }

          {:ok, _} ->
            %{acc | refreshed: acc.refreshed + 1}

          {:error, _} ->
            %{acc | errors: acc.errors + 1}
        end
      end)

    json(conn, %{
      ok: true,
      total: length(manga_list),
      refreshed: stats.refreshed,
      with_new: stats.with_new,
      errors: stats.errors,
      new_chapters: stats.new_total
    })
  end

  # Per-manga refresh path shared by the single-manga `refresh/2`
  # endpoint and the bulk `sync_caught_up/2`. Scrapes the source,
  # upserts the metadata, updates the user's saved row, and fires
  # `notify_new_chapters` for any positive delta. Returns
  # `{:ok, %{title, delta}}` on success, `{:error, reason}` otherwise.
  defp do_refresh_one(user, source, slug) do
    with true <- Sources.valid?(source),
         mod when not is_nil(mod) <- Sources.module(source),
         {:ok, manga} <- mod.get_manga(slug) do
      # Capture the publication status *before* the upsert so we can
      # diff against the freshly-scraped one and fan out a status-
      # change bell notification when the source flipped it.
      prev_status =
        case Library.get_manga_metadata(source, slug) do
          %{data: %{"status" => s}} -> RokiWeb.MangaHTML.normalize_publication_status(s)
          _ -> "unknown"
        end

      cover_file_uuid = download_and_store_cover(manga.cover_url, user.uuid)

      Library.upsert_manga_metadata(%{
        source: source,
        slug: slug,
        title: manga.title,
        cover_url: manga.cover_url,
        cover_file_uuid: cover_file_uuid,
        alt_titles: manga.alt_titles,
        status: manga.status,
        reading_direction: manga.reading_direction,
        reading_mode: manga.reading_mode,
        written_by: manga.written_by,
        illustrated_by: manga.illustrated_by,
        year: manga.year,
        genres: manga.genres,
        synopsis: manga.synopsis,
        chapters: manga.chapters,
        chapter_dates: manga.chapter_dates
      })

      {prev_total, new_total} =
        Library.update_total_chapters(
          user.uuid,
          source,
          slug,
          length(manga.chapters),
          RokiWeb.MangaHTML.last_chapter_number(manga.chapters)
        )

      Library.notify_new_chapters(user.uuid, source, slug, manga.title, prev_total, new_total)

      # Re-pull fabledex arcs / chapter titles into the local copy.
      # Best-effort: a fabledex failure keeps the saved row and never
      # fails the refresh.
      mal = Library.mal_data(user.uuid, source, slug)
      saved_title = (saved = Library.get_saved_manga(user.uuid, source, slug)) && saved.title

      Roki.Manga.Fabledex.sync(source, slug,
        mal_id: mal && mal["id"],
        titles: [saved_title, manga.title],
        alt_titles: manga[:alt_titles]
      )

      new_status = RokiWeb.MangaHTML.normalize_publication_status(manga.status)
      Library.notify_status_change(source, slug, manga.title, prev_status, new_status)

      delta = max(0, new_total - (prev_total || new_total))
      {:ok, %{title: manga.title, delta: delta}}
    else
      false -> {:error, :unknown_source}
      nil -> {:error, :unknown_source}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unexpected}
    end
  end

  @valid_modes ["scroll", "paged", "double_page"]

  def update_reading_mode(
        conn,
        %{"source" => source, "slug" => slug, "mode" => mode, "redirect_to" => redirect_to} =
          params
      )
      when mode in @valid_modes do
    if Sources.valid?(source) do
      user = conn.assigns[:phoenix_kit_current_user]
      device = effective_update_device(conn, params)
      Library.update_reading_mode(user.uuid, source, slug, mode, device)

      redirect_url =
        if device do
          uri = URI.parse(redirect_to)
          query = URI.decode_query(uri.query || "")
          %{uri | query: URI.encode_query(Map.put(query, "device", device))} |> to_string()
        else
          redirect_to
        end

      redirect(conn, to: redirect_url)
    else
      send_resp(conn, 404, "Unknown source")
    end
  end

  def update_reading_mode(conn, %{"source" => source, "slug" => slug, "mode" => mode} = params)
      when mode in @valid_modes do
    if Sources.valid?(source) do
      user = conn.assigns[:phoenix_kit_current_user]

      Library.update_reading_mode(
        user.uuid,
        source,
        slug,
        mode,
        effective_update_device(conn, params)
      )

      redirect(conn, to: ~p"/manga/#{source}/#{slug}")
    else
      send_resp(conn, 404, "Unknown source")
    end
  end

  defp normalize_device("mobile"), do: "mobile"
  defp normalize_device("desktop"), do: "desktop"
  defp normalize_device("all"), do: "all"
  defp normalize_device(_), do: nil

  # Pick the device slot to write to. Explicit `device=mobile|desktop|all`
  # from the form wins; otherwise fall back to UA detection so the
  # fresco reader's in-place toggles (which submit with an empty
  # `device` field) update the slot the user is actually using — not
  # the legacy generic column, which would then get shadowed on the
  # next render because `effective_reading_mode/2` reads the per-
  # device slot first.
  defp effective_update_device(conn, params) do
    case normalize_device(params["device"]) do
      nil -> device_kind(conn, params)
      d -> d
    end
  end

  @valid_directions ["rtl", "ltr"]

  def update_reading_direction(conn, %{
        "source" => source,
        "slug" => slug,
        "direction" => direction
      })
      when direction in @valid_directions do
    if Sources.valid?(source) do
      user = conn.assigns[:phoenix_kit_current_user]
      Library.update_reading_direction(user.uuid, source, slug, direction)
      json(conn, %{ok: true, reading_direction: direction})
    else
      conn |> put_status(404) |> json(%{error: "Unknown source"})
    end
  end

  def update_reading_direction(conn, _params) do
    conn |> put_status(422) |> json(%{error: "Invalid direction"})
  end

  def update_comments_visible(conn, %{"source" => source, "slug" => slug, "visible" => visible}) do
    if Sources.valid?(source) do
      user = conn.assigns[:phoenix_kit_current_user]
      val = visible in [true, "true", "1"]
      Library.update_comments_visible(user.uuid, source, slug, val)
      json(conn, %{ok: true, comments_visible: val})
    else
      conn |> put_status(404) |> json(%{error: "Unknown source"})
    end
  end

  def update_reading_rotation(conn, %{"source" => source, "slug" => slug, "rotation" => rotation}) do
    rot = normalize_rotation(rotation)

    cond do
      not Sources.valid?(source) ->
        conn |> put_status(404) |> json(%{error: "Unknown source"})

      rot == :error ->
        conn |> put_status(422) |> json(%{error: "Invalid rotation"})

      true ->
        user = conn.assigns[:phoenix_kit_current_user]
        Library.update_reading_rotation(user.uuid, source, slug, rot)
        json(conn, %{ok: true, reading_rotation: rot})
    end
  end

  defp normalize_rotation(r) when is_integer(r), do: normalize_rotation_value(r)

  defp normalize_rotation(r) when is_binary(r) do
    case Integer.parse(r) do
      {n, _} -> normalize_rotation_value(n)
      :error -> :error
    end
  end

  defp normalize_rotation(_), do: :error

  # Map -90 → 270 to match Fresco's normalized [0, 360) representation.
  defp normalize_rotation_value(r) do
    snapped = rem(rem(r, 360) + 360, 360)
    if snapped in [0, 90, 180, 270], do: snapped, else: :error
  end

  def update_custom_cover(conn, %{"source" => source, "slug" => slug, "file_uuid" => file_uuid})
      when is_binary(file_uuid) and file_uuid != "" do
    if Sources.valid?(source) do
      user = conn.assigns[:phoenix_kit_current_user]

      if Library.saved?(user.uuid, source, slug) do
        Library.update_cover_file_uuid(user.uuid, source, slug, file_uuid)
        cover_url = PhoenixKit.Modules.Storage.URLSigner.signed_url(file_uuid, "original")
        json(conn, %{ok: true, cover_url: cover_url})
      else
        conn |> put_status(403) |> json(%{error: "Manga not saved"})
      end
    else
      conn |> put_status(404) |> json(%{error: "Unknown source"})
    end
  end

  @doc """
  Cover picker: choose which cover a saved title uses.
  `which` = "scraper" (clear the override → default source cover) or
  "mal" (download + store the linked MAL cover as the custom cover).
  Uploads keep going through `update_custom_cover`.
  """
  def set_cover(conn, %{"source" => source, "slug" => slug, "which" => which}) do
    user = conn.assigns[:phoenix_kit_current_user]

    conn =
      cond do
        not Library.saved?(user.uuid, source, slug) ->
          put_flash(conn, :error, "Save the manga first")

        which == "scraper" ->
          # Clear the override — display falls back to the source cover.
          Library.update_cover_file_uuid(user.uuid, source, slug, nil)
          put_flash(conn, :info, "Cover set to the source's")

        which == "mal" ->
          case Library.mal_data(user.uuid, source, slug) do
            %{"cover_url" => url} when is_binary(url) and url != "" ->
              case fetch_and_store_cover(url, user.uuid, []) do
                uuid when is_binary(uuid) ->
                  Library.update_cover_file_uuid(user.uuid, source, slug, uuid)
                  put_flash(conn, :info, "Cover set to MyAnimeList's")

                _ ->
                  put_flash(conn, :error, "Could not fetch the MyAnimeList cover")
              end

            _ ->
              put_flash(conn, :error, "No MyAnimeList cover available")
          end

        true ->
          put_flash(conn, :error, "Unknown cover choice")
      end

    redirect(conn, to: ~p"/manga/manga2/#{source}/#{slug}")
  end

  @doc """
  Title picker: set a saved title's display name from the scraper
  title, the linked MAL title, or a custom string. The chosen value
  arrives as `title` (the client submits the resolved text for each
  option), validated + trimmed server-side.
  """
  def set_title(conn, %{"source" => source, "slug" => slug, "title" => title}) do
    user = conn.assigns[:phoenix_kit_current_user]

    conn =
      cond do
        not Library.saved?(user.uuid, source, slug) ->
          put_flash(conn, :error, "Save the manga first")

        Library.update_saved_title(user.uuid, source, slug, title) == :ok ->
          put_flash(conn, :info, "Title updated")

        true ->
          put_flash(conn, :error, "Title can't be blank")
      end

    redirect(conn, to: ~p"/manga/manga2/#{source}/#{slug}")
  end

  def update_smart_crop(conn, %{"source" => source, "slug" => slug, "enabled" => enabled}) do
    if Sources.valid?(source) do
      user = conn.assigns[:phoenix_kit_current_user]
      val = enabled in [true, "true", "1"]
      Library.update_smart_crop(user.uuid, source, slug, val)
      json(conn, %{ok: true, smart_crop: val})
    else
      conn |> put_status(404) |> json(%{error: "Unknown source"})
    end
  end

  def update_tap_zone_preset(
        conn,
        %{"source" => source, "slug" => slug, "preset" => preset} = params
      ) do
    if Sources.valid?(source) do
      user = conn.assigns[:phoenix_kit_current_user]
      device = normalize_device(params["device"])

      case Library.update_tap_zone_preset(user.uuid, source, slug, preset, device) do
        {:error, _} -> conn |> put_status(422) |> json(%{error: "Invalid preset"})
        {_count, _} -> json(conn, %{ok: true, tap_zone_preset: preset})
      end
    else
      conn |> put_status(404) |> json(%{error: "Unknown source"})
    end
  end

  def update_reading_time(conn, %{"source" => source, "slug" => slug} = params) do
    if Sources.valid?(source) do
      user = conn.assigns[:phoenix_kit_current_user]

      cond do
        params["reset_all"] in [true, "true"] ->
          # Nuke everything (raw + on-site override + off-site + activity log).
          Library.reset_all_reading_time(user.uuid, source, slug)

        params["reset"] in [true, "true"] ->
          # "Reset On-Site Time" — zero the on-site bucket: raw
          # auto-tracker, manual override, AND the activity log.
          # Off-site is preserved (use `reset_offsite` for that).
          Library.reset_onsite_reading_time(user.uuid, source, slug)

        params["reset_offsite"] in [true, "true"] ->
          # "Reset Off-Site Time" — clear only the off-site bucket.
          Library.reset_offsite_reading_time(user.uuid, source, slug)

        true ->
          # Two-field save: on-site (hours+minutes) + off-site
          # (offsite_hours+offsite_minutes). Either can be omitted on
          # the form to leave its column unchanged.
          if has_form_field?(params, ["hours", "minutes"]) do
            onsite =
              parse_elapsed(params["hours"]) * 3600 +
                parse_elapsed(params["minutes"]) * 60

            Library.update_reading_seconds_adjusted(user.uuid, source, slug, onsite)
          end

          if has_form_field?(params, ["offsite_hours", "offsite_minutes"]) do
            offsite =
              parse_elapsed(params["offsite_hours"]) * 3600 +
                parse_elapsed(params["offsite_minutes"]) * 60

            # Store nil instead of 0 so the "no off-site time" case
            # leaves the display clean (no "0m off site" suffix).
            value = if offsite > 0, do: offsite, else: nil
            approximate? = params["offsite_approximate"] in [true, "true", "on", "1"]
            Library.update_reading_seconds_offsite(user.uuid, source, slug, value, approximate?)
          end

          # Editable "date started" milestone: a date moves/creates
          # the ▶ event, clearing the field removes it.
          if Map.has_key?(params, "date_started") do
            case params["date_started"] do
              "" ->
                Library.set_started_date(user.uuid, source, slug, nil, user.user_timezone)

              d ->
                case Date.from_iso8601(d) do
                  {:ok, date} ->
                    Library.set_started_date(user.uuid, source, slug, date, user.user_timezone)

                  _ ->
                    :ok
                end
            end
          end
      end

      redirect(conn, to: ~p"/manga/#{source}/#{slug}")
    else
      send_resp(conn, 404, "Unknown source")
    end
  end

  def update_progress(
        conn,
        %{"source" => source, "slug" => slug, "chapter" => chapter, "page" => page} = params
      ) do
    if Sources.valid?(source) do
      user = conn.assigns[:phoenix_kit_current_user]
      page = if is_binary(page), do: String.to_integer(page), else: page
      elapsed = parse_elapsed(params["elapsed"])
      user_timezone = user.user_timezone

      total_pages =
        case params["total_pages"] do
          n when is_integer(n) and n > 0 ->
            n

          n when is_binary(n) ->
            case Integer.parse(n) do
              {v, _} when v > 0 -> v
              _ -> nil
            end

          _ ->
            nil
        end

      page_fraction = parse_page_fraction(params["page_fraction"])

      Library.update_progress(
        user.uuid,
        source,
        slug,
        chapter,
        page,
        elapsed,
        user_timezone,
        total_pages,
        page_fraction
      )

      json(conn, %{ok: true})
    else
      conn |> put_status(404) |> json(%{error: "Unknown source"})
    end
  end

  defp parse_page_fraction(nil), do: 0.0
  defp parse_page_fraction(f) when is_float(f), do: f |> max(0.0) |> min(1.0)
  defp parse_page_fraction(n) when is_integer(n), do: n |> max(0) |> min(1) |> :erlang.float()

  defp parse_page_fraction(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f |> max(0.0) |> min(1.0)
      :error -> 0.0
    end
  end

  defp parse_page_fraction(_), do: 0.0

  @doc """
  Toggle a chapter page override (insert-blank-before or mark-solo) for
  the current user. Same endpoint both adds and removes so the client
  can wire a single tap action — `state` in the response tells the UI
  whether the override is now active.
  """
  def toggle_page_override(conn, %{
        "source" => source,
        "slug" => slug,
        "chapter" => chapter,
        "page_index" => page_index,
        "kind" => kind
      }) do
    if Sources.valid?(source) do
      user = conn.assigns[:phoenix_kit_current_user]

      page_index =
        case page_index do
          n when is_integer(n) ->
            n

          n when is_binary(n) ->
            case Integer.parse(n) do
              {v, ""} -> v
              _ -> 0
            end

          _ ->
            0
        end

      cond do
        page_index < 1 ->
          conn |> put_status(422) |> json(%{error: "page_index must be >= 1"})

        kind not in ["insert_blank_before", "solo"] ->
          conn |> put_status(422) |> json(%{error: "invalid kind"})

        true ->
          case Library.toggle_page_override(user.uuid, source, slug, chapter, page_index, kind) do
            {:ok, state} -> json(conn, %{ok: true, state: Atom.to_string(state)})
            {:error, _} -> conn |> put_status(422) |> json(%{error: "could not toggle"})
          end
      end
    else
      conn |> put_status(404) |> json(%{error: "Unknown source"})
    end
  end

  def reset_max_chapter(conn, %{"source" => source, "slug" => slug}) do
    user = conn.assigns[:phoenix_kit_current_user]
    Library.reset_max_chapter(user.uuid, source, slug)
    redirect(conn, to: ~p"/manga/#{source}/#{slug}")
  end

  def create_category(conn, %{"name" => name}) do
    user = conn.assigns[:phoenix_kit_current_user]
    name = String.trim(name)

    result =
      if name != "" do
        Library.create_category(user.uuid, %{name: name})
      end

    case get_req_header(conn, "x-requested-with") do
      ["XMLHttpRequest"] ->
        case result do
          {:ok, cat} -> json(conn, %{ok: true, id: cat.id, name: cat.name})
          _ -> json(conn, %{ok: true})
        end

      _ ->
        redirect(conn, to: ~p"/manga/categories")
    end
  end

  def reorder_categories(conn, %{"ordered_ids" => ordered_ids}) when is_list(ordered_ids) do
    user = conn.assigns[:phoenix_kit_current_user]

    ids =
      Enum.map(ordered_ids, fn id ->
        case Integer.parse(to_string(id)) do
          {int_id, ""} -> int_id
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    Library.reorder_categories(user.uuid, ids)
    json(conn, %{ok: true})
  end

  def delete_category(conn, %{"id" => id}) do
    user = conn.assigns[:phoenix_kit_current_user]

    case Integer.parse(id) do
      {int_id, ""} -> Library.delete_category(int_id, user.uuid)
      _ -> :noop
    end

    case get_req_header(conn, "x-requested-with") do
      ["XMLHttpRequest"] -> json(conn, %{ok: true})
      _ -> redirect(conn, to: ~p"/manga/categories")
    end
  end

  def rename_category(conn, %{"id" => id, "name" => name}) do
    user = conn.assigns[:phoenix_kit_current_user]
    name = String.trim(name)

    case Integer.parse(id) do
      {int_id, ""} when name != "" -> Library.rename_category(int_id, user.uuid, name)
      _ -> :noop
    end

    case get_req_header(conn, "x-requested-with") do
      ["XMLHttpRequest"] -> json(conn, %{ok: true, name: name})
      _ -> redirect(conn, to: ~p"/manga/categories")
    end
  end

  def set_manga_category(conn, %{"source" => source, "slug" => slug} = params) do
    user = conn.assigns[:phoenix_kit_current_user]

    category_id =
      case params["category_id"] do
        "" ->
          nil

        nil ->
          nil

        id ->
          case Integer.parse(id) do
            {int_id, ""} -> int_id
            _ -> nil
          end
      end

    Library.set_manga_category(user.uuid, source, slug, category_id)

    redirect(conn, to: ~p"/manga/#{source}/#{slug}")
  end

  def category_manga_ids(conn, %{"id" => id}) do
    user = conn.assigns[:phoenix_kit_current_user]

    case Integer.parse(id) do
      {int_id, ""} ->
        keys = Library.list_category_manga_keys(int_id, user.uuid)
        json(conn, %{ok: true, manga_keys: keys})

      _ ->
        json(conn, %{ok: false})
    end
  end

  def toggle_manga_category(conn, %{"source" => source, "slug" => slug, "category_id" => cat_id}) do
    user = conn.assigns[:phoenix_kit_current_user]

    with {int_id, ""} <- Integer.parse(to_string(cat_id)),
         saved_manga when not is_nil(saved_manga) <-
           Library.get_saved_manga(user.uuid, source, slug) do
      {_ok, action} = Library.toggle_manga_category(saved_manga.id, int_id)
      category_ids = Library.list_manga_category_ids(saved_manga.id)
      json(conn, %{ok: true, action: action, category_ids: category_ids})
    else
      _ -> conn |> put_status(422) |> json(%{error: "Invalid request"})
    end
  end

  # True iff at least one of `keys` was submitted on the form (any
  # non-nil string value, even empty). Used by `update_reading_time`
  # to know which of the two field-groups the user actually edited
  # so the other column stays untouched.
  defp has_form_field?(params, keys) do
    Enum.any?(keys, fn k -> Map.has_key?(params, k) end)
  end

  defp parse_elapsed(nil), do: 0
  defp parse_elapsed(val) when is_integer(val), do: val
  defp parse_elapsed(val) when is_float(val), do: round(val)

  defp parse_elapsed(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp parse_elapsed(_), do: 0

  # Canonical reader dispatch. Both modes render directly on the same
  # URL — no redirect: paged + double_page → show_fresco, scroll →
  # show_fresco_strip. Legacy is only reachable via explicit
  # /manga/legacy/... URLs (old comment notifications, the
  # reader-switcher fallback in settings).
  #
  # Per-device reading_mode: `saved_manga` carries `reading_mode_desktop`
  # and `reading_mode_mobile` alongside the legacy generic
  # `reading_mode`. We detect device via `?device=`-override or
  # User-Agent and pick the matching field — falls back to the generic
  # `reading_mode` when the per-device slot is unset (so existing
  # users without per-device prefs keep their old behavior).
  def show(conn, %{"source" => source, "slug" => slug, "chapter" => chapter} = params) do
    if Sources.valid?(source) do
      user = conn.assigns[:phoenix_kit_current_user]

      # `?from_max=1` lands here when the user clicks the
      # "Continue from Ch. N" jump-ahead button on the manga details
      # page. Snap `last_chapter` to the URL chapter on entry so the
      # resume pointer matches what they just opened, instead of
      # waiting for the in-reader progress tick to catch up.
      # Idempotent + forward-only on the Library side, so refreshing
      # the URL after auto-advancing in-reader doesn't undo progress.
      if user && params["from_max"] == "1" do
        Library.snap_to_chapter(user.uuid, source, slug, chapter, user.user_timezone)
      end

      saved_manga = if user, do: Library.get_saved_manga(user.uuid, source, slug)
      device = device_kind(conn, params)
      mode = effective_reading_mode(saved_manga, device) || "paged"

      if mode == "scroll" do
        show_fresco_strip(conn, params)
      else
        show_fresco(conn, params)
      end
    else
      send_resp(conn, 404, "Unknown source")
    end
  end

  # ── Per-device settings helpers ─────────────────────────────────────
  # `device_kind/2` resolves to "mobile" or "desktop". Priority:
  #   1. explicit `?device=` query param (lets a user pin the override)
  #   2. User-Agent sniff against the same regex production uses
  #   3. fallback "desktop"
  defp device_kind(conn, params) do
    case params["device"] do
      "mobile" -> "mobile"
      "desktop" -> "desktop"
      _ -> device_from_ua(conn)
    end
  end

  defp device_from_ua(conn) do
    ua = conn |> get_req_header("user-agent") |> List.first() || ""
    if Regex.match?(~r/Mobi|Android|iPhone|iPad|iPod/i, ua), do: "mobile", else: "desktop"
  end

  # Pick the saved reading_mode for the resolved device, falling back
  # to the generic field when the per-device slot is nil.
  defp effective_reading_mode(nil, _device), do: nil

  defp effective_reading_mode(saved_manga, "mobile"),
    do: saved_manga.reading_mode_mobile || saved_manga.reading_mode

  defp effective_reading_mode(saved_manga, _),
    do: saved_manga.reading_mode_desktop || saved_manga.reading_mode

  def show_fresco(conn, %{"source" => source, "slug" => slug, "chapter" => chapter} = params) do
    with true <- Sources.valid?(source),
         mod when not is_nil(mod) <- Sources.module(source) do
      user = conn.assigns[:phoenix_kit_current_user]
      user_id = if user, do: user.uuid, else: "anon"

      saved_manga = if user, do: Library.get_saved_manga(user.uuid, source, slug)
      metadata = Library.get_manga_metadata(source, slug)

      chapters =
        case metadata do
          %{data: %{"chapters" => ch}} when ch != [] ->
            ch

          _ ->
            Roki.Manga.Cache.fetch({source, slug, :chapters}, :timer.hours(1), fn ->
              case mod.get_manga(slug) do
                {:ok, manga} -> manga.chapters
                _ -> []
              end
            end)
        end

      idx = Enum.find_index(chapters, &(&1 == chapter))
      prev_chapter = if idx && idx > 0, do: Enum.at(chapters, idx - 1)
      next_chapter = if idx, do: Enum.at(chapters, idx + 1)

      images_result =
        Roki.Manga.SourceThrottle.throttled_fetch(
          source,
          user_id,
          {source, slug, chapter, :images},
          :timer.hours(6),
          fn -> mod.get_chapter_images(slug, chapter) end
        )

      case images_result do
        {:ok, images} ->
          # Source modules return a list of URL strings; normalize to %{url, width, height}
          # maps so templates can take `img.url`.
          # Full probe for paged chapters (sampling made a wide spread
          # page outside the sample look portrait → it paired with a
          # neighbour instead of getting its own solo spread). Results
          # cache per URL, so this costs once per chapter; very long
          # lists (strip-sized) still fall back to sampling inside.
          images = Roki.Manga.ImageDimensions.probe_paged(images)

          # User-applied chapter page overrides — splice synthetic
          # blanks before flagged natural indices, accumulate solo
          # indices in post-insert coordinates. Anonymous users get
          # the natural list back unchanged.
          overrides =
            if user,
              do: Library.list_page_overrides(user.uuid, source, slug, chapter),
              else: []

          {images, solo_set, inserted_set} =
            RokiWeb.MangaHTML.apply_overrides(images, overrides)

          manga_title = if saved_manga, do: saved_manga.title, else: slug
          total = length(images)

          page =
            case Integer.parse(params["page"] || "") do
              {n, ""} when n >= 1 and n <= total ->
                n

              _ ->
                if saved_manga && saved_manga.last_chapter == chapter && saved_manga.last_page do
                  saved_manga.last_page |> max(1) |> min(total)
                else
                  1
                end
            end

          # Per-device default for single-vs-double: pick the matching
          # `reading_mode_{desktop,mobile}` field (falling back to the
          # generic). `?double=` URL override still wins so the user
          # can flip per-session without touching saved prefs.
          device = device_kind(conn, params)

          double? =
            cond do
              params["double"] in ["1", "true"] -> true
              params["double"] in ["0", "false"] -> false
              true -> effective_reading_mode(saved_manga, device) == "double_page"
            end

          direction =
            cond do
              params["dir"] == "ltr" -> "ltr"
              params["dir"] == "rtl" -> "rtl"
              saved_manga && saved_manga.reading_direction -> saved_manga.reading_direction
              true -> "rtl"
            end

          spread_starts =
            if double?,
              do: RokiWeb.MangaHTML.fresco_spread_starts(images, solo_set),
              else: []

          # Load every visible etcher shape for this chapter — the
          # current user's own (any visibility) plus other users'
          # public shapes. The template stuffs them into the canvas
          # extension so Etcher hydrates them on mount. Anonymous
          # callers see only the public set.
          etcher_annotations =
            Roki.Manga.Library.Marks.list_visible_etcher_shape_payloads(
              source,
              slug,
              chapter,
              user && user.uuid
            )

          reading_rotation = (saved_manga && saved_manga.reading_rotation) || 0

          render(conn, :show_fresco,
            source: source,
            slug: slug,
            chapter: chapter,
            images: images,
            total_pages: total,
            page: page,
            double_page: double?,
            direction: direction,
            spread_starts: spread_starts,
            solo_pages: MapSet.to_list(solo_set),
            inserted_pages: MapSet.to_list(inserted_set),
            chapters: chapters,
            prev_chapter: prev_chapter,
            next_chapter: next_chapter,
            manga_title: manga_title,
            current_user: user,
            etcher_annotations: etcher_annotations,
            reading_rotation: reading_rotation,
            # `?ann=` means the user landed here from a comment deep-link
            # (notification, /comments index, etc.) — JS gates progress
            # saves until the user proves they're actually rereading
            # (≥2 min on page + ≥2 page flips).
            transient_mode: params["ann"] != nil,
            page_title: "[fresco-test] #{manga_title} — Ch. #{chapter} (p.#{page})"
          )

        {:error, reason} ->
          conn
          |> put_flash(:error, "Failed to load chapter: #{inspect(reason)}")
          |> redirect(to: ~p"/manga/#{source}/#{slug}")
      end
    else
      _ -> send_resp(conn, 404, "Unknown source")
    end
  end

  # On-device telemetry endpoint used by the strip-test reader during
  # smoothness debugging. Writes JSON-lines to /tmp/fresco_debug.log so
  # iPhone Safari sessions (no DevTools) can be cross-referenced.
  @fresco_debug_log_path "/tmp/fresco_debug.log"

  def fresco_debug_log(conn, params) do
    line = Jason.encode!(%{ts: System.system_time(:millisecond), payload: params})
    File.write!(@fresco_debug_log_path, line <> "\n", [:append])
    json(conn, %{ok: true})
  end

  # Parallel test route — Fresco 0.5 scroll_strip reader (manhwa /
  # vertical-strip WIP). DOM <img> + native browser scroll, with the
  # gutter-snap algorithm ported verbatim from the production scroll
  # reader (show.html.heex). Production reader untouched.
  def show_fresco_strip(
        conn,
        %{"source" => source, "slug" => slug, "chapter" => chapter} = params
      ) do
    # The reader's whole JS engine is INLINE in this page. Without an
    # explicit cache policy iOS (standalone webapps especially) caches the
    # HTML heuristically and keeps executing week-old reader code through
    # app restarts — debugging against phantom versions. Never cache it.
    conn = put_resp_header(conn, "cache-control", "no-store")

    with true <- Sources.valid?(source),
         mod when not is_nil(mod) <- Sources.module(source) do
      user = conn.assigns[:phoenix_kit_current_user]
      user_id = if user, do: user.uuid, else: "anon"

      saved_manga = if user, do: Library.get_saved_manga(user.uuid, source, slug)
      metadata = Library.get_manga_metadata(source, slug)

      chapters =
        case metadata do
          %{data: %{"chapters" => ch}} when ch != [] ->
            ch

          _ ->
            Roki.Manga.Cache.fetch({source, slug, :chapters}, :timer.hours(1), fn ->
              case mod.get_manga(slug) do
                {:ok, manga} -> manga.chapters
                _ -> []
              end
            end)
        end

      idx = Enum.find_index(chapters, &(&1 == chapter))
      prev_chapter = if idx && idx > 0, do: Enum.at(chapters, idx - 1)
      next_chapter = if idx, do: Enum.at(chapters, idx + 1)

      images_result =
        Roki.Manga.SourceThrottle.throttled_fetch(
          source,
          user_id,
          {source, slug, chapter, :images},
          :timer.hours(6),
          fn -> mod.get_chapter_images(slug, chapter) end
        )

      case images_result do
        {:ok, images} ->
          # Sampled probing: chapter image lists can be enormous
          # (500+ panels for manhwa). `probe_sampled/1` probes ~20
          # evenly-distributed images and median-fills the rest —
          # dim accuracy stays within 1-2% since same-source pages
          # publish at consistent sizes, but server-outbound traffic
          # drops ~25× per chapter load.
          images = Roki.Manga.ImageDimensions.probe_sampled(images)
          manga_title = if saved_manga, do: saved_manga.title, else: slug

          etcher_annotations =
            Roki.Manga.Library.Marks.list_visible_etcher_shape_payloads(
              source,
              slug,
              chapter,
              user && user.uuid
            )

          {resume_page, resume_fraction} =
            if saved_manga && saved_manga.last_chapter == chapter && saved_manga.last_page do
              {saved_manga.last_page, saved_manga.last_page_fraction || 0.0}
            else
              {1, 0.0}
            end

          render(conn, :show_fresco_strip,
            source: source,
            slug: slug,
            chapter: chapter,
            page_padding_defaults:
              Roki.Manga.Library.page_padding_defaults(user && user.custom_fields),
            images: images,
            total_pages: length(images),
            chapters: chapters,
            prev_chapter: prev_chapter,
            next_chapter: next_chapter,
            manga_title: manga_title,
            current_user: user,
            etcher_annotations: etcher_annotations,
            resume_page: resume_page,
            resume_fraction: resume_fraction,
            # `?ann=` means the user landed here from a comment deep-link.
            # JS gates progress saves until the user proves they're
            # actually rereading (≥2 min on page + ≥2 page transitions).
            transient_mode: params["ann"] != nil,
            page_title: "#{manga_title} — Ch. #{chapter}"
          )

        {:error, reason} ->
          conn
          |> put_flash(:error, "Failed to load chapter: #{inspect(reason)}")
          |> redirect(to: ~p"/manga/#{source}/#{slug}")
      end
    else
      _ -> send_resp(conn, 404, "Unknown source")
    end
  end

  def chapter_images(conn, %{"source" => source, "slug" => slug, "chapter" => chapter}) do
    with true <- Sources.valid?(source),
         mod when not is_nil(mod) <- Sources.module(source) do
      user = conn.assigns[:phoenix_kit_current_user]
      user_id = if user, do: user.uuid, else: "anon"

      chapter_images_result =
        Roki.Manga.SourceThrottle.throttled_fetch(
          source,
          user_id,
          {source, slug, chapter, :images},
          :timer.hours(6),
          fn ->
            mod.get_chapter_images(slug, chapter)
          end
        )

      case chapter_images_result do
        {:ok, images} ->
          # Look up prev/next chapter so the strip's inline-append loop
          # can chain to the next one without a second API round-trip.
          metadata = Library.get_manga_metadata(source, slug)

          chapters =
            case metadata do
              %{data: %{"chapters" => ch}} when ch != [] ->
                ch

              _ ->
                Roki.Manga.Cache.fetch({source, slug, :chapters}, :timer.hours(1), fn ->
                  case mod.get_manga(slug) do
                    {:ok, manga} -> manga.chapters
                    _ -> []
                  end
                end)
            end

          idx = Enum.find_index(chapters, &(&1 == chapter))
          prev_chapter = if idx && idx > 0, do: Enum.at(chapters, idx - 1)
          next_chapter = if idx, do: Enum.at(chapters, idx + 1)

          etcher_shapes =
            Roki.Manga.Library.Marks.list_visible_etcher_shape_payloads(
              source,
              slug,
              chapter,
              user && user.uuid
            )

          # probe_paged: full dims for pageable chapter lengths so the
          # in-place chapter swap keeps wide-page solo spreads correct
          # (see show_fresco); strip-sized lists sample as before.
          probed = Roki.Manga.ImageDimensions.probe_paged(images)

          # Also build the paged-layout sources list (id="page-N",
          # side-by-side x positions per RTL/LTR direction, y-centered).
          # The strip reader doesn't need this branch — it ignores
          # `sources` and uses its own append-by-y loop — but the paged
          # in-place chapter swap needs a fully laid-out source array
          # to hand to `handle.setSources` so pages render at the right
          # spots without remounting the canvas.
          direction =
            case conn.query_params["direction"] do
              d when d in ["rtl", "ltr"] -> d
              _ -> "rtl"
            end

          double_page = conn.query_params["double_page"] in ["true", "1"]

          paged_canvas =
            RokiWeb.MangaHTML.fresco_canvas(
              probed,
              direction,
              etcher_shapes,
              1,
              double_page,
              []
            )

          # Fresco's `setSources` reads `width` and `height` per
          # source, but `Fresco.Canvas` images carry `width` +
          # `natural_width` + `natural_height` (no top-level `height`).
          # Fold `natural_height` into `height` so the swap path lines
          # up with what fresco expects; keep the originals so the
          # initial-mount data shape stays usable for anything else.
          sources =
            Enum.map(paged_canvas.images, fn img ->
              Map.put(img, :height, img[:natural_height] || img[:height] || 0)
            end)

          # The paged in-place chapter swap needs a JS-side `images[]`
          # closure that already carries the proxied URL the server
          # placed on the canvas (so applyImageWindow's "real src"
          # swap-back is a no-op match against what setSources already
          # applied — not a fresh cross-origin re-fetch). Strip mode,
          # on the other hand, expects `data.images` to stay RAW —
          # appendChapterToContainer wraps each `img.url` in the proxy
          # itself, and a pre-proxied URL would double-wrap into a 404.
          # So: ship the proxied-window payload under its own key.
          paged_window_images =
            Enum.map(probed, fn img ->
              base = %{
                url: RokiWeb.MangaHTML.proxied_image_src(img),
                width: img.width,
                height: img.height
              }

              if Map.get(img, :synthetic), do: Map.put(base, :synthetic, true), else: base
            end)

          json(conn, %{
            chapter: chapter,
            images: probed,
            paged_window_images: paged_window_images,
            sources: sources,
            canvas_width: paged_canvas.canvas.width,
            canvas_height: paged_canvas.canvas.height,
            prev_chapter: prev_chapter,
            next_chapter: next_chapter,
            etcher_shapes: etcher_shapes
          })

        {:error, _reason} ->
          conn |> put_status(404) |> json(%{error: "Chapter not found"})
      end
    else
      _ -> conn |> put_status(404) |> json(%{error: "Unknown source"})
    end
  end

  def proxy_image(conn, %{"url" => url}) do
    cond do
      # Kotatsu sidecar image URLs (covers/pages of extension-backed
      # series) — the sidecar adds the source site's own headers, we
      # just relay from loopback.
      Roki.Manga.KotatsuSource.sidecar_image_url?(url) ->
        stream_sidecar_image(conn, url)

      true ->
        case URI.parse(url) do
          %URI{host: host} when is_binary(host) ->
            case Sources.image_referer(host) do
              nil -> send_resp(conn, 403, "Forbidden")
              referer -> stream_image(conn, url, referer)
            end

          _ ->
            send_resp(conn, 403, "Forbidden")
        end
    end
  end

  defp stream_sidecar_image(conn, url) do
    case Req.get(url, receive_timeout: 60_000, retry: false) do
      {:ok, %{status: 200, body: body, headers: resp_headers}} ->
        content_type =
          resp_headers
          |> Enum.find_value("image/jpeg", fn
            {"content-type", [val | _]} -> val
            _ -> nil
          end)

        conn
        |> put_resp_content_type(content_type)
        |> put_resp_header("cache-control", "public, max-age=86400")
        |> send_resp(200, body)

      _ ->
        send_resp(conn, 502, "Failed to fetch image")
    end
  end

  def grid(conn, params) do
    user = conn.assigns[:phoenix_kit_current_user]
    mode = normalize_grid_mode(params["mode"])

    slots = Library.list_grid_slots(user.uuid, mode)
    saved_manga = Library.list_saved_manga(user.uuid)

    pool =
      case mode do
        "manga" -> Enum.filter(saved_manga, &(MangaHTML.tierlist_kind(&1) == "paged"))
        "manhwa" -> Enum.filter(saved_manga, &(MangaHTML.tierlist_kind(&1) == "scroll"))
        _ -> saved_manga
      end

    saved_index = Map.new(saved_manga, fn m -> {{m.source, m.slug}, m} end)
    pairs = Enum.map(saved_manga, &{&1.source, &1.slug})
    cover_paths = Library.list_cover_file_uuids(pairs)

    render(conn, :grid,
      slots: slots,
      saved_manga: pool,
      saved_index: saved_index,
      cover_paths: cover_paths,
      active_mode: mode
    )
  end

  def update_grid(conn, %{"slot" => slot} = params) do
    user = conn.assigns[:phoenix_kit_current_user]
    id = params["id"]
    mode = normalize_grid_mode(params["mode"])

    with {n, ""} when n in 1..15 <- Integer.parse(to_string(slot)),
         {source, slug} <- parse_grid_id(id) do
      Library.set_grid_slot(user.uuid, mode, n, source, slug)
      json(conn, %{ok: true})
    else
      _ -> conn |> put_status(400) |> json(%{ok: false})
    end
  end

  defp normalize_grid_mode(m) when m in ["overall", "manga", "manhwa"], do: m
  defp normalize_grid_mode(_), do: "overall"

  defp parse_grid_id(nil), do: {nil, nil}
  defp parse_grid_id(""), do: {nil, nil}

  defp parse_grid_id(id) when is_binary(id) do
    case String.split(id, ":", parts: 2) do
      [src, slug] when src != "" and slug != "" -> {src, slug}
      _ -> :error
    end
  end

  defp parse_grid_id(_), do: :error

  def tierlist(conn, _params) do
    user = conn.assigns[:phoenix_kit_current_user]
    saved_manga = Library.list_saved_manga(user.uuid)
    pairs = Enum.map(saved_manga, &{&1.source, &1.slug})
    cover_paths = Library.list_cover_file_uuids(pairs)
    tier_index = Library.list_tierlist(user.uuid)
    buckets = Library.bucketize_tierlist(saved_manga, tier_index)
    categories = Library.list_categories(user.uuid)
    category_memberships = Library.list_category_memberships(user.uuid)
    mal_sync = Library.tierlist_mal_sync(user.uuid, tier_index)
    mal_connected = Library.get_tracker_token(user.uuid, "mal") != nil

    {roki, _placed} = Roki.Tiers.board(user.uuid)

    render(conn, :tierlist,
      roki: roki,
      saved_manga: saved_manga,
      cover_paths: cover_paths,
      buckets: buckets,
      categories: categories,
      category_memberships: category_memberships,
      mal_sync: mal_sync,
      mal_connected: mal_connected
    )
  end

  @doc """
  The board, as it was left. One board holds two kinds of thing, so what comes back is split:
  manga goes to the reader's own table, which is what the MyAnimeList sync writes through, and
  everything else to this site's (`Roki.Tiers`), which rates what moved.
  """
  def update_tierlist(conn, %{"tiers" => tiers}) when is_map(tiers) do
    user = conn.assigns[:phoenix_kit_current_user]
    by_id = Map.new(Library.list_saved_manga(user.uuid), &{&1.id, {&1.source, &1.slug}})

    split =
      Enum.into(tiers, %{}, fn {tier, ids} ->
        {to_string(tier),
         (ids || []) |> Enum.map(&to_string/1) |> Enum.flat_map(&parse_tier_item(&1, by_id))}
      end)

    manga = for {tier, items} <- split, into: %{}, do: {tier, for({:manga, p} <- items, do: p)}
    roki = for {tier, items} <- split, into: %{}, do: {tier, for({:roki, k} <- items, do: k)}

    Library.replace_tierlist(user.uuid, manga)

    titles =
      roki
      |> Enum.flat_map(fn {_tier, keys} -> keys end)
      |> Roki.Titles.cards()
      |> Map.new(fn {key, card} -> {key, card[:title]} end)

    Roki.Tiers.replace(user.uuid, roki, titles)
    json(conn, %{ok: true})
  end

  # `"manga:12"` is the reader's own id for a saved series; `"movie:603"`, `"tv:1399"` and
  # `"mal:5114"` are this site's keys, the same ones the shelves use.
  defp parse_tier_item("manga:" <> id, by_id) do
    with {n, ""} <- Integer.parse(id),
         {_, _} = pair <- by_id[n],
         do: [{:manga, pair}],
         else: (_ -> [])
  end

  defp parse_tier_item(item, _by_id) do
    case String.split(item, ":", parts: 2) do
      [type, id] when type in ["movie", "tv", "mal"] ->
        case Integer.parse(id) do
          {n, ""} -> [{:roki, {type, n}}]
          _ -> []
        end

      _ ->
        []
    end
  end

  @annotations_page_size 50

  def annotations(conn, params) do
    user = conn.assigns[:phoenix_kit_current_user]
    before = parse_before_cursor(params["before"])

    annotations =
      Library.list_recent_annotations(@annotations_page_size, user.uuid, before: before)
      |> Enum.map(fn a ->
        gif_url = get_in(a, [:metadata, "giphy", "url"])

        a
        |> Map.update(:content, "", &Library.strip_gif_placeholder/1)
        |> Map.put(:gif_url, gif_url)
        |> Map.drop([:metadata])
      end)

    # When a full page comes back, assume there's more and surface the
    # last row's inserted_at as the next cursor. A short page means the
    # tail of the list is in hand — no loader needed.
    next_cursor =
      if length(annotations) == @annotations_page_size do
        annotations |> List.last() |> Map.get(:inserted_at) |> NaiveDateTime.to_iso8601()
      else
        nil
      end

    assigns = [annotations: annotations, next_cursor: next_cursor]

    if before do
      conn
      |> put_root_layout(false)
      |> put_layout(false)
      |> render(:annotations_more, assigns)
    else
      colors_used = Library.list_user_annotation_colors(user.uuid)

      %{titles: filter_titles, usernames: filter_usernames} =
        Library.list_user_annotation_filters(user.uuid)

      extras = [
        colors_used: colors_used,
        filter_titles: filter_titles,
        filter_usernames: filter_usernames
      ]

      render(conn, :annotations, extras ++ assigns)
    end
  end

  defp parse_before_cursor(nil), do: nil
  defp parse_before_cursor(""), do: nil

  defp parse_before_cursor(s) when is_binary(s) do
    case NaiveDateTime.from_iso8601(s) do
      {:ok, ts} -> ts
      _ -> nil
    end
  end

  defp parse_before_cursor(_), do: nil

  def manga_annotations(conn, %{"source" => source, "slug" => slug}) do
    if Sources.valid?(source) do
      user = conn.assigns[:phoenix_kit_current_user]

      legacy = Library.list_manga_annotations(source, slug, user.uuid)
      marks = Library.list_mark_comments_for_manga(source, slug, user.uuid)

      annotations =
        (legacy ++ marks)
        |> Enum.sort_by(& &1.inserted_at, {:desc, NaiveDateTime})
        |> Enum.map(fn a ->
          gif_url = get_in(a, [:metadata, "giphy", "url"])

          a
          |> Map.update(:content, "", &Library.strip_gif_placeholder/1)
          |> Map.put(:gif_url, gif_url)
          |> Map.drop([:metadata])
        end)

      title =
        case annotations do
          [first | _] -> first.title
          [] -> slug
        end

      render(conn, :manga_annotations,
        annotations: annotations,
        source: source,
        slug: slug,
        manga_title: title
      )
    else
      send_resp(conn, 404, "Unknown source")
    end
  end

  def list_annotations(conn, %{"source" => source, "slug" => slug, "chapter" => chapter}) do
    user = conn.assigns[:phoenix_kit_current_user]
    annotations = Library.list_annotations(source, slug, chapter, user.uuid)
    json(conn, %{annotations: annotations})
  end

  def annotation_detail(conn, %{"id" => comment_uuid}) do
    user = conn.assigns[:phoenix_kit_current_user]

    case Library.get_annotation_detail(comment_uuid, user.uuid) do
      nil ->
        conn |> put_status(404) |> json(%{error: "Not found"})

      detail ->
        detail = resolve_avatar_url(detail)
        gif_url = get_in(detail, [:metadata, "gif_url"]) || get_in(detail, [:metadata, :gif_url])
        detail = Map.update(detail, :content, "", &Library.strip_gif_placeholder/1)
        detail = Map.drop(detail, [:metadata])
        detail = if gif_url, do: Map.put(detail, :gif_url, gif_url), else: detail
        json(conn, detail)
    end
  end

  def create_annotation(
        conn,
        %{"source" => source, "slug" => slug, "chapter" => chapter} = params
      ) do
    user = conn.assigns[:phoenix_kit_current_user]

    case Library.create_annotation(user, source, slug, chapter, params) do
      {:ok, annotation} ->
        comment = PhoenixKitComments.get_comment(annotation.comment_uuid)

        conn
        |> put_status(201)
        |> json(%{
          id: annotation.id,
          comment_uuid: annotation.comment_uuid,
          resource_uuid: comment && comment.resource_uuid,
          page: annotation.page,
          x_pct: annotation.x_pct,
          y_pct: annotation.y_pct,
          w_pct: annotation.w_pct,
          h_pct: annotation.h_pct,
          color: annotation.color,
          visibility: annotation.visibility,
          user_id: user.uuid,
          content: params["content"],
          like_count: 0,
          liked: false,
          user_uuid: user.uuid,
          username: user.username,
          avatar_url: avatar_url_for_user(user),
          is_own: true,
          inserted_at: annotation.inserted_at
        })

      {:error, _reason} ->
        conn |> put_status(422) |> json(%{error: "Failed to create annotation"})
    end
  end

  def update_annotation(conn, %{"id" => id} = params) do
    user = conn.assigns[:phoenix_kit_current_user]

    case Library.update_annotation(id, user.uuid, params) do
      {:ok, annotation} ->
        json(conn, %{
          id: annotation.id,
          comment_uuid: annotation.comment_uuid,
          page: annotation.page,
          x_pct: annotation.x_pct,
          y_pct: annotation.y_pct,
          w_pct: annotation.w_pct,
          h_pct: annotation.h_pct,
          color: annotation.color,
          visibility: annotation.visibility,
          content: params["content"]
        })

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "Not found"})

      {:error, :forbidden} ->
        conn |> put_status(403) |> json(%{error: "Forbidden"})

      {:error, _reason} ->
        conn |> put_status(422) |> json(%{error: "Failed to update annotation"})
    end
  end

  def delete_annotation(conn, %{"id" => id}) do
    user = conn.assigns[:phoenix_kit_current_user]

    case Library.delete_annotation(id, user.uuid) do
      {:ok, _} -> json(conn, %{ok: true})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "Not found"})
      {:error, :forbidden} -> conn |> put_status(403) |> json(%{error: "Forbidden"})
    end
  end

  def toggle_like(conn, %{"id" => comment_uuid}) do
    user = conn.assigns[:phoenix_kit_current_user]

    # `toggle_like_annotation/2` answers `{:ok, liked, count}` and nothing else, so the error
    # branch that used to sit here could never be reached.
    {:ok, liked, like_count} = Library.toggle_like_annotation(comment_uuid, user.uuid)
    json(conn, %{liked: liked, like_count: like_count})
  end

  def list_replies(conn, %{"id" => comment_uuid}) do
    user = conn.assigns[:phoenix_kit_current_user]

    replies =
      Library.list_annotation_replies(comment_uuid, user.uuid)
      |> Enum.map(&resolve_avatar_url/1)
      |> Enum.map(fn r ->
        gif_url = get_in(r, [:metadata, "gif_url"]) || get_in(r, [:metadata, :gif_url])
        r = Map.update(r, :content, "", &Library.strip_gif_placeholder/1)
        r = Map.drop(r, [:metadata])
        if gif_url, do: Map.put(r, :gif_url, gif_url), else: r
      end)

    json(conn, %{replies: replies})
  end

  def delete_reply(conn, %{"reply_id" => reply_uuid}) do
    user = conn.assigns[:phoenix_kit_current_user]

    case Library.delete_reply(reply_uuid, user.uuid) do
      {:ok, _} -> json(conn, %{ok: true})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "Not found"})
      {:error, :forbidden} -> conn |> put_status(403) |> json(%{error: "Forbidden"})
    end
  end

  def create_reply(conn, %{"id" => comment_uuid} = params) do
    user = conn.assigns[:phoenix_kit_current_user]
    content = params["content"] || ""

    case Library.create_annotation_reply(comment_uuid, user.uuid, content, params) do
      {:ok, comment} ->
        gif_url = get_in(comment.metadata || %{}, ["gif_url"])

        reply = %{
          uuid: comment.uuid,
          content: Library.strip_gif_placeholder(comment.content),
          like_count: 0,
          liked: false,
          user_uuid: user.uuid,
          username: user.username,
          is_own: true,
          inserted_at: comment.inserted_at
        }

        reply = if gif_url, do: Map.put(reply, :gif_url, gif_url), else: reply

        conn
        |> put_status(201)
        |> json(reply)

      {:error, _reason} ->
        conn |> put_status(422) |> json(%{error: "Failed to create reply"})
    end
  end

  defp load_resume_manga(conn, _opts) do
    user = conn.assigns[:phoenix_kit_current_user]
    resume = Library.list_saved_manga(user.uuid) |> Enum.find(&(&1.last_chapter && !&1.completed))
    assign(conn, :resume_manga, resume)
  end

  defp download_and_store_cover(cover_url, _user_uuid)
       when not is_binary(cover_url) or cover_url == "",
       do: nil

  defp download_and_store_cover(cover_url, user_uuid) do
    cond do
      # Sidecar proxy URLs (kotatsu extension covers) — plain loopback
      # fetch; the sidecar adds the source site's headers upstream.
      Roki.Manga.KotatsuSource.sidecar_image_url?(cover_url) ->
        fetch_and_store_cover(cover_url, user_uuid, [])

      true ->
        case URI.parse(cover_url) do
          %URI{host: host} when is_binary(host) ->
            case Sources.image_referer(host) do
              nil ->
                nil

              referer ->
                session_key = {user_uuid, referer}
                fetch_and_store_cover(cover_url, user_uuid, Guise.headers(referer, session_key))
            end

          _ ->
            nil
        end
    end
  end

  defp fetch_and_store_cover(cover_url, user_uuid, headers) do
    case Req.get(cover_url, headers: headers, retry: false, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: body}} when is_binary(body) and byte_size(body) > 0 ->
        checksum = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
        ext = cover_extension(cover_url)
        tmp_path = Path.join(System.tmp_dir!(), "cover_#{checksum}.#{ext}")

        try do
          File.write!(tmp_path, body)

          case PhoenixKit.Modules.Storage.store_file_in_buckets(
                 tmp_path,
                 "image",
                 user_uuid,
                 checksum,
                 ext,
                 "cover.#{ext}"
               ) do
            {:ok, file} -> file.uuid
            {:ok, file, :duplicate} -> file.uuid
            _ -> nil
          end
        after
          File.rm(tmp_path)
        end

      _ ->
        nil
    end
  end

  # Extension of the actual image file: for proxy URLs the real image
  # rides in the `url` query param.
  defp cover_extension(cover_url) do
    inner =
      with %URI{query: q} when is_binary(q) <- URI.parse(cover_url),
           %{"url" => u} <- URI.decode_query(q) do
        u
      else
        _ -> cover_url
      end

    ext =
      inner
      |> URI.parse()
      |> Map.get(:path)
      |> Kernel.||("")
      |> Path.extname()
      |> String.trim_leading(".")

    if ext == "", do: "jpg", else: ext
  end

  # ─────────────────────────────────────────────────────────────────
  # Marks API — generic per-user-per-chapter overlay store, used by
  # the new fresco-based readers. Items are typed (annotation/drawing/
  # marker/highlight); we only wire annotation create here, but the
  # list + delete endpoints are type-agnostic so adding a new type
  # later is just a new "create_mark_*" sibling.
  # ─────────────────────────────────────────────────────────────────

  def list_marks(conn, %{"source" => source, "slug" => slug, "chapter" => chapter}) do
    user = conn.assigns[:phoenix_kit_current_user]
    items = Roki.Manga.Library.Marks.list_visible_items(source, slug, chapter, user.uuid)
    json(conn, %{items: items})
  end

  def create_mark_annotation(
        conn,
        %{"source" => source, "slug" => slug, "chapter" => chapter} = params
      ) do
    user = conn.assigns[:phoenix_kit_current_user]

    attrs = %{
      title: params["title"] || "",
      content: params["content"] || "",
      color: params["color"] || "blue",
      visibility: params["visibility"] || "public",
      anchor: params["anchor"] || %{},
      giphy: params["giphy"]
    }

    case Roki.Manga.Library.Marks.create_annotation(user, source, slug, chapter, attrs) do
      {:ok, item} ->
        conn
        |> put_status(201)
        |> json(%{item: Map.put(item, "_user_id", user.uuid)})

      {:error, {:comment, reason}} ->
        conn |> put_status(422) |> json(%{error: "comment: #{inspect(reason)}"})

      {:error, {:items, changeset}} ->
        conn |> put_status(422) |> json(%{error: "items: #{inspect(changeset.errors)}"})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  def attach_etcher_comment(
        conn,
        %{"source" => source, "slug" => slug, "chapter" => chapter, "shape_uuid" => shape_uuid} =
          params
      ) do
    user = conn.assigns[:phoenix_kit_current_user]

    # Build giphy payload from gif_url if the composer included one
    # (production uses `gif_url` on the wire; the comment's metadata
    # stores it under `giphy` as `%{url, preview_url}`).
    giphy =
      case params["gif_url"] do
        url when is_binary(url) and url != "" -> %{"url" => url, "preview_url" => url}
        _ -> params["giphy"]
      end

    attrs = %{
      title: params["title"] || "",
      content: params["content"] || "",
      visibility: params["visibility"] || "public",
      giphy: giphy
    }

    if attrs.content == "" and is_nil(giphy) do
      conn |> put_status(422) |> json(%{error: "content or gif required"})
    else
      case Roki.Manga.Library.Marks.attach_comment_to_etcher_shape(
             user,
             source,
             slug,
             chapter,
             shape_uuid,
             attrs
           ) do
        {:ok, %{comment_uuid: cuuid, resource_uuid: ruuid, tooltip_metadata: meta}} ->
          conn
          |> put_status(201)
          |> json(%{
            shape_uuid: shape_uuid,
            comment_uuid: cuuid,
            resource_uuid: ruuid,
            tooltip_metadata: meta
          })

        {:error, {:comment, reason}} ->
          conn |> put_status(422) |> json(%{error: "comment: #{inspect(reason)}"})

        {:error, {:items, changeset}} ->
          conn |> put_status(422) |> json(%{error: "items: #{inspect(changeset.errors)}"})

        {:error, reason} ->
          conn |> put_status(422) |> json(%{error: inspect(reason)})
      end
    end
  end

  def delete_mark(conn, %{
        "source" => source,
        "slug" => slug,
        "chapter" => chapter,
        "item_id" => item_id
      }) do
    user = conn.assigns[:phoenix_kit_current_user]

    # Annotation deletes also need to remove the linked comment, so
    # we look up the item type first and dispatch. Non-annotation
    # items are a simple array splice.
    case Roki.Manga.Library.Marks.get_user_row(user.uuid, source, slug, chapter) do
      nil ->
        conn |> put_status(404) |> json(%{error: "no marks row"})

      %{items: items} ->
        case Enum.find(items, &(&1["id"] == item_id)) do
          nil ->
            conn |> put_status(404) |> json(%{error: "item not found"})

          %{"type" => "annotation"} ->
            case Roki.Manga.Library.Marks.delete_annotation(user, source, slug, chapter, item_id) do
              {:ok, _} -> json(conn, %{ok: true})
              {:error, reason} -> conn |> put_status(422) |> json(%{error: inspect(reason)})
            end

          _ ->
            case Roki.Manga.Library.Marks.delete_item(user.uuid, source, slug, chapter, item_id) do
              {:ok, _} ->
                json(conn, %{ok: true})

              {:error, changeset} ->
                conn |> put_status(422) |> json(%{error: inspect(changeset.errors)})
            end
        end
    end
  end

  defp stream_image(conn, url, referer) do
    user = conn.assigns[:phoenix_kit_current_user]
    session_key = {user.uuid, referer}

    case Req.get(url, headers: Guise.headers(referer, session_key)) do
      {:ok, %{status: 200, body: body, headers: resp_headers}} ->
        content_type =
          resp_headers
          |> Enum.find_value("image/jpeg", fn
            {"content-type", [val | _]} -> val
            _ -> nil
          end)

        conn
        |> put_resp_content_type(content_type)
        |> put_resp_header("cache-control", "public, max-age=86400")
        |> send_resp(200, body)

      _ ->
        send_resp(conn, 502, "Failed to fetch image")
    end
  end

  defp resolve_avatar_url(%{avatar_file_uuid: uuid} = map) when is_binary(uuid) and uuid != "" do
    map
    |> Map.put(:avatar_url, PhoenixKit.Modules.Storage.URLSigner.signed_url(uuid, "small"))
    |> Map.delete(:avatar_file_uuid)
  end

  defp resolve_avatar_url(map),
    do: Map.put(map, :avatar_url, nil) |> Map.delete(:avatar_file_uuid)

  defp avatar_url_for_user(user) do
    case user.custom_fields do
      %{"avatar_file_uuid" => uuid} when is_binary(uuid) and uuid != "" ->
        PhoenixKit.Modules.Storage.URLSigner.signed_url(uuid, "small")

      _ ->
        nil
    end
  end
end
