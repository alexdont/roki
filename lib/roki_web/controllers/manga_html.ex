defmodule RokiWeb.MangaHTML do
  use RokiWeb, :html

  embed_templates "manga_html/*"

  alias Roki.Manga.Fabledex

  # Cutoff for legacy-vs-fresco reader routing on comment deep-links.
  # Annotations created BEFORE this date were authored against the
  # legacy OSD reader's pixel layout, so their `?ann=` deep-links must
  # land in the legacy reader to keep working. From this date onward
  # comments anchor to the Fresco canvas and get the canonical URL.
  @reader_cutoff ~D[2026-05-22]

  @doc """
  Pick the right reader URL for a comment deep-link. The kind is
  determined by data source, not date:

    * `:legacy` (MangaAnnotation rows) → `/manga/legacy/...`. Page-
      anchored, so `?page=N&ann=ID` is preserved.
    * `:mark`   (etcher-shape comments) → `/manga/...` (fresco).
      No `page` (strip / paged-fresco don't share the legacy paging
      coordinate), so only `?ann=UUID` is sent.

  Annotations missing `:kind` fall back to the date-cutoff heuristic
  so pre-existing call sites keep working.
  """
  def comment_reader_url(a) do
    case classify(a) do
      :legacy ->
        page_q = if a.page, do: "page=#{a.page}&", else: ""
        "/manga/legacy/#{a.source}/#{a.slug}/#{a.chapter}?#{page_q}ann=#{a.id}"

      :mark ->
        # Include `page=N` when the comment's metadata (or the linked
        # shape's image_id) yields it. Without page= the reader lands
        # at page 1 and only jumps once the deep-link poll finds the
        # shape — orphan comments (shape deleted) would never jump at
        # all, so always supplying page= when known is more robust.
        page_q = if a.page, do: "page=#{a.page}&", else: ""
        "/manga/#{a.source}/#{a.slug}/#{a.chapter}?#{page_q}ann=#{a.id}"
    end
  end

  defp classify(%{kind: :legacy}), do: :legacy
  defp classify(%{kind: :mark}), do: :mark
  defp classify(a), do: if(comment_legacy?(a), do: :legacy, else: :mark)

  defp comment_legacy?(%{inserted_at: %NaiveDateTime{} = ts}),
    do: Date.compare(NaiveDateTime.to_date(ts), @reader_cutoff) == :lt

  defp comment_legacy?(%{inserted_at: %DateTime{} = ts}),
    do: Date.compare(DateTime.to_date(ts), @reader_cutoff) == :lt

  defp comment_legacy?(_), do: false

  @doc """
  Canonical publication-status bucket for a saved manga, derived from the
  scraped `data["status"]` field on `manga_metadata`. Returns one of
  `"ongoing" | "completed" | "hiatus" | "unknown"`.

  Sources report status in their own UI strings (English on the EN
  scrapers, Russian on mangalib/remanga/mangabuff), so we substring-match
  the canonical English term *and* the localized variants. New sources
  that introduce unfamiliar phrasing fall through to "unknown" rather
  than getting silently mis-bucketed.
  """
  def publication_status(manga, status_map) do
    raw = Map.get(status_map, {manga.source, manga.slug})
    normalize_publication_status(raw)
  end

  @doc """
  Public form of the same bucket logic that `publication_status/2` runs
  internally. Used by the refresh path to compute the old-vs-new
  status diff that powers the status-change bell notification.
  Delegates to the `chapter` package.
  """
  defdelegate normalize_publication_status(raw), to: Chapter.Status, as: :normalize

  @doc """
  Display label + color for a tierlist tier id, mirroring the legend
  in `tierlist.html.heex`. Used on the manga details page so the
  user can read where they ranked it without going to the tierlist.
  Returns `nil` for an unknown / nil tier so the caller can skip the
  row entirely with `:if`.
  """
  def tier_display(nil), do: nil
  def tier_display("sp"), do: %{label: "S+", color: "#ff66cc"}
  def tier_display("s"), do: %{label: "S", color: "#ff7f7f"}
  def tier_display("a"), do: %{label: "A", color: "#ffbf7f"}
  def tier_display("b"), do: %{label: "B", color: "#ffdf80"}
  def tier_display("c"), do: %{label: "C", color: "#ffff7f"}
  def tier_display("d"), do: %{label: "D", color: "#bfff7f"}
  def tier_display("e"), do: %{label: "E", color: "#7fdfff"}
  def tier_display("unknown"), do: %{label: "Don't Know", color: "#bfbfbf"}
  def tier_display("want"), do: %{label: "Want to Read", color: "#c79fff"}
  def tier_display("pool"), do: %{label: "Unranked", color: "#bfbfbf"}
  def tier_display(_), do: nil

  @doc "The MAL score (0–10) a tier maps to, or nil for non-scoring tiers."
  def tier_mal_score(tier), do: Roki.Manga.Trackers.MAL.tier_score(tier)

  @doc """
  Small corner badge on a tierlist cover showing its MyAnimeList
  rating-sync state. `sync` is one entry from `Library.tierlist_mal_sync/2`
  (or nil for unlinked titles — renders nothing).
  """
  attr :sync, :map, default: nil

  def mal_sync_badge(assigns) do
    ~H"""
    <span :if={@sync} class="mal-badge absolute top-0.5 right-0.5 z-10 flex items-center gap-0.5">
      <span
        :if={@sync.mal_mean}
        class="inline-flex items-center justify-center min-w-[16px] h-4 px-0.5 rounded-full bg-black/75 text-white text-[9px] font-bold leading-none ring-1 ring-white/20 shadow"
        title="MyAnimeList community rating"
      >{@sync.mal_mean}</span>
      <span
        class={[
          "inline-flex items-center justify-center rounded-full leading-none ring-1 ring-black/40 shadow",
          case @sync.status do
            :synced -> "min-w-[16px] h-4 px-0.5 bg-emerald-500 text-white text-[9px] font-bold"
            :out_of_sync -> "min-w-[16px] h-4 px-0.5 bg-amber-400 text-black text-[9px] font-bold"
            :linked -> "w-2.5 h-2.5 bg-sky-500/90"
          end
        ]}
        title={mal_sync_title(@sync)}
      >{mal_sync_text(@sync)}</span>
    </span>
    """
  end

  defp mal_sync_text(%{status: :synced, mal_score: s}) when is_integer(s) and s > 0,
    do: Integer.to_string(s)

  defp mal_sync_text(%{status: :synced}), do: "✓"

  defp mal_sync_text(%{status: :out_of_sync, mal_score: s}) when is_integer(s) and s > 0,
    do: Integer.to_string(s)

  defp mal_sync_text(%{status: :out_of_sync}), do: "!"
  defp mal_sync_text(_), do: ""

  defp mal_sync_title(%{status: :synced, expected: e}), do: "MyAnimeList rating synced (#{e})"

  defp mal_sync_title(%{status: :out_of_sync, mal_score: s, expected: e}) do
    have = if is_integer(s) and s > 0, do: Integer.to_string(s), else: "none"
    "MyAnimeList shows #{have}, tier maps to #{e} — will sync on next change"
  end

  defp mal_sync_title(_), do: "Linked to MyAnimeList"

  def tierlist_kind(manga) do
    paged = ~w(paged double_page)

    # MyAnimeList's media type is authoritative when the title is
    # linked: manhwa/manhua read as vertical strips, manga as paged.
    # Fall back to the user's reading-mode / scraped direction otherwise.
    case media_kind(Map.get(manga, :mal_media_type)) do
      "scroll" ->
        "scroll"

      "paged" ->
        "paged"

      _ ->
        cond do
          manga.reading_mode_desktop in paged -> "paged"
          manga.reading_mode_mobile in paged -> "paged"
          manga.reading_mode_desktop == "scroll" -> "scroll"
          manga.reading_mode_mobile == "scroll" -> "scroll"
          manhwa_label?(manga.reading_direction) -> "scroll"
          manga.reading_direction == "ltr" -> "scroll"
          manga.reading_mode in paged -> "paged"
          true -> "paged"
        end
    end
  end

  # MAL media_type → reading kind (shared with the reader auto-switch).
  defp media_kind(media_type), do: Roki.Manga.Trackers.MAL.reading_kind(media_type)

  defp manhwa_label?(nil), do: false

  defp manhwa_label?(label) when is_binary(label) do
    d = String.downcase(label)
    Enum.any?(~w(manhwa manhua manwha webtoon), &String.contains?(d, &1))
  end

  defp manhwa_label?(_), do: false

  @doc """
  Cover image URL for a manga, preferring locally-stored files over
  hot-linking the source site. `variant` picks the phoenix_kit
  Storage size ("thumbnail" 150px / "small" 300px / "medium" 800px /
  "large" 1920px / "original") — match it to the rendered size
  instead of shipping originals everywhere.
  """
  def cover_image_src(manga, cover_paths, variant \\ "original") do
    user_cover = Map.get(manga, :cover_file_uuid)

    cond do
      user_cover ->
        PhoenixKit.Modules.Storage.URLSigner.signed_url(user_cover, variant)

      file_uuid = Map.get(cover_paths, {manga.source, manga.slug}) ->
        PhoenixKit.Modules.Storage.URLSigner.signed_url(file_uuid, variant)

      true ->
        ~p"/manga/proxy/image?#{%{url: manga.cover_url}}"
    end
  end

  @doc "Compact count: 1234 → \"1.2K\", 1_200_000 → \"1.2M\"."
  def format_count(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M" |> String.replace(".0M", "M")

  def format_count(n) when is_integer(n) and n >= 1_000,
    do: "#{Float.round(n / 1_000, 1)}K" |> String.replace(".0K", "K")

  def format_count(n) when is_integer(n), do: Integer.to_string(n)
  def format_count(_), do: nil

  @doc "Short human note for a kotatsu extension error tuple."
  def error_note(:no_search), do: "no text search — Explore only"
  def error_note(:rate_limited), do: "rate limited"
  def error_note(:timeout), do: "timed out"
  def error_note(:not_found), do: "not found"
  def error_note(:auth_required), do: "needs an account"
  def error_note({:transport, _}), do: "backend offline"
  def error_note({:upstream, %{detail: d}}) when is_binary(d), do: String.slice(d, 0, 60)
  def error_note(other), do: inspect(other) |> String.slice(0, 60)

  def chapter_read?(_, nil), do: false
  def chapter_read?(ch, last_chapter), do: Chapter.before?(ch, last_chapter)

  defdelegate chapter_sort_key(ch), to: Chapter, as: :sort_key

  @doc """
  Percent of the current chapter remaining for the resume label.
  Manhwa / strip readers show "12% left" instead of a page number, since
  per-image page numbers aren't meaningful in a long-form scroll context.

  Returns nil when we don't have enough data (no total_pages persisted yet,
  or the manga is paged).
  """
  def percent_left(_last_page, _fraction, nil), do: nil
  def percent_left(_last_page, _fraction, total) when total <= 0, do: nil
  def percent_left(nil, _fraction, _total), do: nil

  def percent_left(last_page, fraction, total) do
    fraction = fraction || 0.0
    read = (last_page - 1 + fraction) / total
    remaining = max(0.0, min(1.0, 1.0 - read))
    round(remaining * 100)
  end

  @doc """
  Inverse of `percent_left/3` — how far into the *current* chapter
  the user has read. Drives the chapter-badge fill on the home page
  card so each tile shows both the manga's overall progress (Continue
  button bar) and the current-chapter progress (the "Ch. N" badge).
  Same nil-on-missing-data shape so the caller can drop the style
  attr with a single `:if`.
  """
  def chapter_read_percent(_last_page, _fraction, nil), do: nil
  def chapter_read_percent(_last_page, _fraction, total) when total <= 0, do: nil
  def chapter_read_percent(nil, _fraction, _total), do: nil

  def chapter_read_percent(last_page, fraction, total) do
    fraction = fraction || 0.0
    read = (last_page - 1 + fraction) / total
    round(max(0.0, min(1.0, read)) * 100)
  end

  @doc """
  True when this saved_manga is read as a vertical scroll (manhwa /
  long-form). Used to pick the resume-button label: "% left" for scroll,
  "p.N" for paged.
  """
  def strip_mode?(reading_mode) do
    reading_mode == "scroll"
  end

  defdelegate last_chapter_number(chapters), to: Chapter, as: :last_number

  # Shared through story_arcs to every arc / chapter grid below it.
  @grid_attrs ~w(source slug search_params last_chapter max_chapter current_chapter_percent chapter_titles)a

  @doc """
  Fabledex story-arc chapter browser for the details pages (index +
  index2). When a title has arcs it replaces the flat chapter list: the
  chapters fold into their arcs (open an arc to pick one), and chapters
  no arc covers sit between / after the arcs as plain, always-visible
  chapters (no collapsible box), so none are hidden.

  Spoilers stay hidden until earned, judged by how far the reader has
  *read through* (finished chapters, the furthest chapter reached, or
  the title marked completed):

    * read arc     — fully visible
    * current arc  — title, range and chapter numbers visible; the
                     description and unread chapter titles blurred
    * later arcs   — everything blurred, but still openable / clickable

  Volumes get the same browser. With both, an Arcs | Volumes switch
  picks one (remembered per browser, arcs by default); a volume's
  number, span and chapters are never blurred, only a real name and
  description.

  Renders nothing when there are neither arcs nor volumes.
  """
  attr :arcs, :list, required: true
  attr :volumes, :list, default: []
  attr :chapters, :list, required: true
  attr :source, :string, required: true
  attr :slug, :string, required: true
  attr :search_params, :map, default: %{}
  attr :last_chapter, :string, default: nil
  attr :max_chapter, :string, default: nil
  attr :completed, :boolean, default: false
  attr :current_chapter_percent, :integer, default: nil
  attr :chapter_titles, :map, default: %{}
  attr :finished_chapters, :list, default: []
  attr :saved, :boolean, default: false

  def story_arcs(assigns) do
    read_through = read_through(assigns)
    current_num = assigns.last_chapter && Chapter.number(assigns.last_chapter)

    views =
      for {kind, items} <- [arcs: assigns.arcs, volumes: assigns.volumes], items != [] do
        {folded, shown} =
          fold_read(arc_segments(items, assigns.chapters), read_through, current_num)

        %{kind: kind, count: length(items), folded: folded, shown: shown}
      end

    assigns =
      assign(assigns,
        current_num: current_num,
        grid: Map.take(assigns, @grid_attrs) |> Map.put(:read_through, read_through),
        views: views
      )

    ~H"""
    <div :if={@views != []} id="story-browser" class="mt-6 sm:mt-8">
      <style>
        .arc-spoiler { filter: blur(5px); user-select: none; transition: filter 0.2s; }
        .arc-ch { position: relative; display: flex; align-items: center; justify-content: center; gap: 0.5rem;
          min-height: 2.25rem; padding: 0.25rem 0.5rem; border-radius: 0.625rem; font-size: 0.8125rem;
          font-weight: 600; font-variant-numeric: tabular-nums; overflow: hidden;
          background: color-mix(in oklab, var(--color-base-content) 6%, transparent); transition: background 0.15s; }
        .arc-ch:hover { background: color-mix(in oklab, var(--color-primary) 18%, transparent); }
        .arc-ch.is-row { justify-content: flex-start; padding-inline: 0.75rem; }
        .arc-ch.is-read { opacity: 0.45; background: transparent; }
        .arc-ch.is-read:hover { opacity: 0.85; }
        .arc-ch.is-reread { background: color-mix(in oklab, var(--color-accent) 16%, transparent); }
        .arc-ch.is-current { background: var(--color-primary); color: var(--color-primary-content); }
      </style>
      <%!-- One row at every width: short counts and an icon-only
           Refresh on phones, full text from sm up. --%>
      <div class="flex items-center gap-1.5 sm:gap-2 mb-3 whitespace-nowrap">
        <h2 class="text-lg sm:text-xl font-bold">Story</h2>
        <span
          :for={{v, i} <- Enum.with_index(@views)}
          data-story-view={v.kind}
          hidden={i > 0}
          class="min-w-0 truncate rounded-full bg-base-content/5 px-1.5 sm:px-2.5 py-0.5 text-[11px] sm:text-xs font-semibold text-base-content/60"
        >
          <span class="sm:hidden">{v.count}{if v.kind == :arcs, do: "a", else: "v"}·{length(@chapters)}ch</span>
          <span class="hidden sm:inline">{v.count} {if v.kind == :arcs, do: "arcs", else: "volumes"} · {length(
            @chapters
          )} chapters</span>
        </span>
        <%!-- This section replaces the chapter list, so it carries the
             list's Refresh button: re-scrapes the source's chapters and
             re-pulls fabledex arcs + volumes (also in the ⋮ menu). --%>
        <form
          :if={@saved}
          method="post"
          action={~p"/manga/#{@source}/#{@slug}/refresh"}
          class="shrink-0"
        >
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
          <button
            type="submit"
            class="btn btn-sm btn-circle sm:w-auto sm:px-3 sm:rounded-full bg-base-content/5 hover:bg-base-content/10 border-0 gap-1.5"
            title="Refresh chapters, arcs and volumes"
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="h-4 w-4"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            ><path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"
            /></svg>
            <span class="hidden sm:inline">Refresh</span>
          </button>
        </form>
        <div class="ml-auto flex shrink-0 items-center gap-1.5 sm:gap-2">
          <div
            :if={length(@views) > 1}
            role="tablist"
            class="flex rounded-full bg-base-content/5 p-0.5 text-xs font-semibold"
          >
            <button
              :for={{v, i} <- Enum.with_index(@views)}
              type="button"
              role="tab"
              data-story-tab={v.kind}
              aria-selected={to_string(i == 0)}
              class="rounded-full px-2 sm:px-3 py-1 text-base-content/60 aria-selected:bg-base-100 aria-selected:text-base-content aria-selected:shadow-sm"
            >
              <%= if v.kind == :arcs do %>
                Arcs
              <% else %>
                <span class="sm:hidden">Vols</span><span class="hidden sm:inline">Volumes</span>
              <% end %>
            </button>
          </div>
          <span class="text-[9px] sm:text-[10px] font-semibold uppercase tracking-wider sm:tracking-widest text-base-content/40">
            Fabledex
          </span>
        </div>
      </div>
      <ol
        :for={{v, i} <- Enum.with_index(@views)}
        data-story-view={v.kind}
        hidden={i > 0}
        class="flex flex-col gap-2"
      >
        <li :if={v.folded != []}>
          <%!-- Read arcs / volumes before the current one fold away like
               read chapters do; the chevron row opens them in place. --%>
          <details class="group/read">
            <summary class="arc-ch is-read is-row justify-center gap-2 cursor-pointer list-none [&::-webkit-details-marker]:hidden group-open/read:hidden">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-4 w-4"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              ><path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M5 13l4 4L19 7"
              /></svg>
              <span>{folded_label(v.folded, v.kind)}</span>
              <span class="text-xs font-normal opacity-70">{length(v.folded)} read</span>
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-4 w-4 opacity-50"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              ><path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M19 9l-7 7-7-7"
              /></svg>
            </summary>
            <ol class="flex flex-col gap-2">
              <li :for={{seg, view} <- v.folded}>
                <.arc_segment seg={seg} view={view} kind={v.kind} current_num={@current_num} {@grid} />
              </li>
            </ol>
          </details>
        </li>
        <li :for={{seg, view} <- v.shown}>
          <.arc_segment seg={seg} view={view} kind={v.kind} current_num={@current_num} {@grid} />
        </li>
      </ol>
      <script :if={length(@views) > 1}>
        (() => {
          const root = document.getElementById("story-browser");
          const KEY = "story-browser-view";
          const show = (kind) => {
            if (!root.querySelector(`[data-story-tab="${kind}"]`)) return;
            root.querySelectorAll("[data-story-view]").forEach((el) => { el.hidden = el.dataset.storyView !== kind; });
            root.querySelectorAll("[data-story-tab]").forEach((b) => b.setAttribute("aria-selected", String(b.dataset.storyTab === kind)));
          };
          try { const saved = localStorage.getItem(KEY); if (saved) show(saved); } catch (_) {}
          root.querySelectorAll("[data-story-tab]").forEach((b) => b.addEventListener("click", () => {
            show(b.dataset.storyTab);
            try { localStorage.setItem(KEY, b.dataset.storyTab); } catch (_) {}
          }));
        })();
      </script>
    </div>
    """
  end

  # Splits the segments into the leading run already read through
  # (folded behind one row) and the rest. Two or more, or there's
  # nothing to save.
  defp fold_read(segments, read_through, current_num) do
    viewed = Enum.map(segments, &{&1, segment_view(&1, read_through, current_num)})

    {done, rest} =
      Enum.split_while(viewed, fn {seg, view} -> segment_done?(seg, view, read_through) end)

    if length(done) >= 2, do: {done, rest}, else: {[], viewed}
  end

  defp segment_done?(%{arc: nil, chapters: chs}, _view, read_through) do
    chs != [] and
      Enum.all?(chs, fn ch ->
        n = Chapter.number(ch)
        n != nil and beyond?(read_through, n)
      end)
  end

  defp segment_done?(_seg, view, _read_through), do: view.badge == :read

  defp folded_label(folded, kind) do
    {one, many} = if kind == :arcs, do: {"Arc", "Arcs"}, else: {"Volume", "Volumes"}

    case for {%{arc: arc}, _} <- folded, arc, do: arc do
      [] -> "Read chapters"
      [arc] -> "#{one} #{arc.position}"
      arcs -> "#{many} #{hd(arcs).position}–#{List.last(arcs).position}"
    end
  end

  attr :seg, :map, required: true
  attr :view, :map, required: true
  attr :kind, :atom, default: :arcs
  attr :current_num, :any, default: nil
  attr :read_through, :any, required: true
  attr :source, :string, required: true
  attr :slug, :string, required: true
  attr :search_params, :map, default: %{}
  attr :last_chapter, :string, default: nil
  attr :max_chapter, :string, default: nil
  attr :current_chapter_percent, :integer, default: nil
  attr :chapter_titles, :map, default: %{}

  # One arc (a collapsible card) or a run of chapters no arc covers.
  defp arc_segment(assigns) do
    # Arcs hide their whole shape until reached; a volume's number, span
    # and chapters are no spoiler — only a real name / description are.
    arcs? = assigns.kind == :arcs

    assigns =
      assign(assigns,
        noun: if(arcs?, do: "an arc", else: "a volume"),
        hide_shape: arcs? and assigns.view.locked,
        hide_title: assigns.view.locked and (arcs? or (assigns.seg.arc && assigns.seg.arc.named))
      )

    ~H"""
    <div :if={is_nil(@seg.arc)} class="flex flex-col gap-2 py-1">
      <span class="px-1 text-xs font-semibold text-base-content/50">
        {segment_range_label(@seg.chapters)} · not in {@noun}
      </span>
      <.arc_chapter_grid
        chapters={@seg.chapters}
        locked={false}
        source={@source}
        slug={@slug}
        search_params={@search_params}
        last_chapter={@last_chapter}
        max_chapter={@max_chapter}
        current_chapter_percent={@current_chapter_percent}
        chapter_titles={@chapter_titles}
        read_through={@read_through}
      />
    </div>
    <details
      :if={@seg.arc}
      open={@view.open}
      class={[
        "group rounded-2xl border transition-colors",
        @view.badge == :current && "border-primary/40 bg-primary/5",
        @view.badge == :read && "border-base-content/5",
        @view.badge not in [:current, :read] && "border-base-content/10 bg-base-content/5"
      ]}
    >
      <summary class="flex items-center gap-3 px-3 sm:px-4 py-2.5 cursor-pointer list-none [&::-webkit-details-marker]:hidden">
        <span class={[
          "w-6 text-center text-xs font-bold tabular-nums shrink-0",
          (@view.badge == :current && "text-primary") || "text-base-content/40"
        ]}>
          {@seg.arc.position}
        </span>
        <img
          :if={@seg.arc[:cover_url]}
          src={@seg.arc.cover_url}
          alt=""
          loading="lazy"
          class={["h-11 w-8 rounded object-cover shrink-0", @view.badge == :read && "opacity-60"]}
        />
        <span class={["min-w-0 flex-1", @view.badge == :read && "opacity-60"]}>
          <span class={[
            "block font-semibold text-sm sm:text-base truncate",
            @hide_title && "arc-spoiler"
          ]}>
            {@seg.arc.title}
          </span>
          <span class="block text-[11px] text-base-content/50">
            <span class={@hide_shape && "arc-spoiler"}>Ch. {@seg.arc.from}–{@seg.arc.to}</span><span :if={
              @seg.arc[:released_on]
            }> · {String.slice(@seg.arc.released_on, 0, 4)}</span><span :if={@seg.arc.ongoing}> · ongoing</span><span :if={
              @seg.chapters == []
            }> · not on this source</span>
          </span>
        </span>
        <span :if={@view.badge == :read} class="badge badge-sm badge-ghost shrink-0">✓ Read</span>
        <span :if={@view.badge == :current} class="badge badge-sm badge-primary shrink-0">Reading</span>
        <span
          :if={@hide_title}
          class="shrink-0 text-base-content/40"
          title="Spoilers hidden until you get here"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            class="h-3.5 w-3.5"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
          ><path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z"
          /></svg>
        </span>
        <svg
          xmlns="http://www.w3.org/2000/svg"
          class="h-4 w-4 shrink-0 text-base-content/40 transition-transform group-open:rotate-180"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
        >
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
        </svg>
      </summary>
      <div class="flex flex-col gap-3 px-3 sm:px-4 pb-3 pt-0.5">
        <progress
          :if={@view.badge == :current && @seg.arc && @seg.arc.to >= @seg.arc.from}
          class="progress progress-primary w-full h-1.5"
          value={@current_num - @seg.arc.from}
          max={@seg.arc.to - @seg.arc.from + 1}
        ></progress>
        <p
          :if={@seg.arc && @seg.arc.description}
          class={[
            "text-sm text-base-content/70 leading-relaxed max-w-prose",
            @view.hide_description && "arc-spoiler"
          ]}
        >
          {@seg.arc.description}
        </p>
        <.arc_chapter_grid
          chapters={@seg.chapters}
          locked={@hide_shape}
          source={@source}
          slug={@slug}
          search_params={@search_params}
          last_chapter={@last_chapter}
          max_chapter={@max_chapter}
          current_chapter_percent={@current_chapter_percent}
          chapter_titles={@chapter_titles}
          read_through={@read_through}
        />
      </div>
    </details>
    """
  end

  attr :chapters, :list, required: true
  attr :locked, :boolean, default: false
  attr :source, :string, required: true
  attr :slug, :string, required: true
  attr :search_params, :map, default: %{}
  attr :last_chapter, :string, default: nil
  attr :max_chapter, :string, default: nil
  attr :current_chapter_percent, :integer, default: nil
  attr :chapter_titles, :map, default: %{}
  attr :read_through, :any, required: true

  # Chapter tiles (or title rows, once any chapter has a fabledex title)
  # for one arc / stray run. `locked` blurs the numbers too.
  defp arc_chapter_grid(assigns) do
    assigns =
      assign(
        assigns,
        :rows?,
        Enum.any?(assigns.chapters, &chapter_title(assigns.chapter_titles, &1))
      )

    ~H"""
    <div
      :if={@chapters != []}
      class={
        if @rows?,
          do: "grid grid-cols-1 sm:grid-cols-2 gap-1.5",
          else: "grid grid-cols-4 sm:grid-cols-6 md:grid-cols-8 lg:grid-cols-10 gap-1.5"
      }
    >
      <a
        :for={ch <- @chapters}
        href={~p"/manga/#{@source}/#{@slug}/#{ch}?#{@search_params}"}
        class={["arc-ch", @rows? && "is-row", "is-#{chapter_state(ch, @last_chapter, @max_chapter)}"]}
        style={
          if ch == @last_chapter && @current_chapter_percent,
            do: "--progress: #{@current_chapter_percent}%"
        }
      >
        <span class={["shrink-0", @locked && "arc-spoiler"]}>{ch}</span>
        <span
          :if={@rows? && chapter_title(@chapter_titles, ch)}
          class={[
            "truncate font-normal opacity-80",
            chapter_spoiler?(ch, @read_through) && "arc-spoiler"
          ]}
        >
          {chapter_title(@chapter_titles, ch)}
        </span>
      </a>
    </div>
    """
  end

  # How far the reader has read *through* — the highest chapter number
  # whose contents count as seen. Completed titles see everything;
  # otherwise the max of: finished-chapter events, and the chapter
  # before the furthest one reached (reaching N means 1..N-1 are done).
  defp read_through(%{completed: true}), do: :infinity

  defp read_through(assigns) do
    furthest = Chapter.number(assigns.max_chapter || assigns.last_chapter || "")
    finished = assigns.finished_chapters |> Enum.map(&Chapter.number/1) |> Enum.reject(&is_nil/1)

    Enum.max([0, (furthest && furthest - 1) || 0 | finished])
  end

  # Chapters in list order, grouped: each arc gets the chapters whose
  # number falls in its span; chapters no arc covers are chunked into
  # consecutive runs. Segments come back sorted by where they start, so
  # stray runs sit between / after the arcs they fall between.
  @doc false
  def arc_segments(arcs, chapters) do
    tagged = Enum.map(chapters, fn ch -> {ch, Fabledex.arc_for(arcs, Chapter.number(ch))} end)

    by_arc =
      tagged
      |> Enum.filter(&elem(&1, 1))
      |> Enum.group_by(&elem(&1, 1).id, &elem(&1, 0))

    arc_segs =
      for arc <- arcs, do: %{arc: arc, start: arc.from, chapters: Map.get(by_arc, arc.id, [])}

    stray_segs =
      tagged
      |> Enum.chunk_by(&is_nil(elem(&1, 1)))
      |> Enum.filter(fn [{_, arc} | _] -> is_nil(arc) end)
      |> Enum.map(fn run ->
        chs = Enum.map(run, &elem(&1, 0))
        %{arc: nil, start: Chapter.number(hd(chs)), chapters: chs}
      end)

    # Arcs before a stray run that starts at the same number; numberless
    # runs (extras, specials) go last.
    Enum.sort_by(arc_segs ++ stray_segs, fn s ->
      {s.start || :infinity, if(s.arc, do: 0, else: 1)}
    end)
  end

  # Spoiler / badge state for one segment.
  defp segment_view(%{arc: nil}, _read_through, _current_num),
    do: %{badge: nil, open: false, locked: false, hide_description: false}

  defp segment_view(%{arc: arc}, read_through, current_num) do
    current? = is_integer(current_num) and current_num >= arc.from and current_num <= arc.to
    unlocked? = beyond?(read_through, arc.to)
    reached? = current? or beyond?(read_through, arc.from - 1)

    %{
      badge:
        cond do
          current? -> :current
          unlocked? -> :read
          true -> nil
        end,
      open: current?,
      locked: not reached?,
      hide_description: not unlocked?
    }
  end

  defp beyond?(:infinity, _n), do: true
  defp beyond?(read_through, n), do: read_through >= n

  defp chapter_spoiler?(ch, read_through) do
    case Chapter.number(ch) do
      nil -> false
      n -> not beyond?(read_through, n)
    end
  end

  defp chapter_state(ch, last_chapter, max_chapter) do
    cond do
      ch == last_chapter -> "current btn-progress"
      chapter_read?(ch, last_chapter) -> "read"
      max_chapter && max_chapter != last_chapter && chapter_read?(ch, max_chapter) -> "reread"
      true -> "unread"
    end
  end

  defp segment_range_label([only]), do: "Chapter #{only}"
  defp segment_range_label(chs), do: "Chapters #{List.first(chs)}–#{List.last(chs)}"

  @doc """
  Saved fabledex title for source chapter id `ch`, or nil. Whole-number
  chapters only — fabledex units are numbered by integer, so `"10.5"`
  must not inherit chapter 10's title.
  """
  def chapter_title(titles, _ch) when titles == %{}, do: nil

  def chapter_title(titles, ch) when is_binary(ch) do
    if String.contains?(ch, "."), do: nil, else: titles[Chapter.number(ch)]
  end

  def chapter_title(_, _), do: nil

  @doc """
  Counts for the home page built-in chips (All / Reading / Caught Up /
  Manga To Read / Manhwa To Read / Completed). The predicates MUST
  mirror the JS `modePredicate` set in home.html.heex — same threshold
  fallback (last_chapter_number, else total_chapters) and the same
  chapter-floor parse — or the chip badge disagrees with what clicking
  the chip shows.
  """
  def chip_counts(saved_manga) do
    %{
      all: length(saved_manga),
      reading:
        Enum.count(saved_manga, fn m ->
          m.last_chapter not in [nil, ""] and !m.completed and !chip_caught_up?(m)
        end),
      caughtup: Enum.count(saved_manga, &chip_caught_up?/1),
      mangatoread:
        Enum.count(saved_manga, fn m -> chip_unstarted?(m) and tierlist_kind(m) == "paged" end),
      manhwatoread:
        Enum.count(saved_manga, fn m -> chip_unstarted?(m) and tierlist_kind(m) == "scroll" end),
      completed: Enum.count(saved_manga, & &1.completed)
    }
  end

  defp chip_unstarted?(m), do: m.last_chapter in [nil, ""] and !m.completed

  defp chip_caught_up?(m) do
    cond do
      m.last_chapter in [nil, ""] ->
        false

      m.completed ->
        false

      true ->
        threshold =
          cond do
            is_number(m.last_chapter_number) -> m.last_chapter_number
            is_number(m.total_chapters) and m.total_chapters > 0 -> m.total_chapters
            true -> nil
          end

        read = Chapter.number(m.last_chapter)
        threshold != nil and read != nil and read >= threshold
    end
  end

  def format_last_read(nil), do: nil

  def format_last_read(%NaiveDateTime{} = dt) do
    date = NaiveDateTime.to_date(dt)
    today = Date.utc_today()
    days_ago = Date.diff(today, date)

    relative =
      case days_ago do
        0 -> "Today"
        1 -> "Yesterday"
        n when n > 0 -> "#{n} Days Ago"
        _ -> nil
      end

    formatted = Calendar.strftime(dt, "%b %-d, %Y")
    if relative, do: "#{formatted} (#{relative})", else: formatted
  end

  def format_reading_time(nil), do: nil
  def format_reading_time(0), do: nil
  def format_reading_time(seconds) when seconds < 60, do: "<1m"

  def format_reading_time(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)

    case {hours, minutes} do
      {0, m} -> "#{m}m"
      {h, 0} -> "#{h}h"
      {h, m} -> "#{h}h #{m}m"
    end
  end

  # Prepend `~` when the total includes approximate off-site time, so
  # estimated figures (chapter-count × per-chapter heuristic) are
  # visually distinct from actually-tracked reading.
  def format_reading_time(seconds, approximate?) do
    case format_reading_time(seconds) do
      nil -> nil
      s -> if approximate?, do: "~" <> s, else: s
    end
  end

  # Breaks reading time into `{hours_str, minutes_str}` so the stats
  # row can render hours and minutes in fixed-width columns — keeps
  # "25h 30m" and "25h 3m" aligned digit-for-digit instead of letting
  # the single-digit-minute row shift left under right-alignment.
  # Either part can be nil (e.g. only hours, only minutes, sub-minute).
  def reading_time_parts(nil), do: {nil, nil}
  def reading_time_parts(0), do: {nil, nil}
  def reading_time_parts(seconds) when seconds < 60, do: {nil, "<1m"}

  def reading_time_parts(seconds) do
    h = div(seconds, 3600)
    m = div(rem(seconds, 3600), 60)
    {if(h > 0, do: "#{h}h"), if(m > 0, do: "#{m}m")}
  end

  @doc """
  Collapse one day's raw activity rows into a single entry per series,
  longest-read first.

  `Library.list_reading_activity/1` yields a row per reading session, so a
  series picked up three times in a day arrives as three rows — the
  calendar cell shows one cover and the tooltip one line, with `seconds`
  and `chapters_read` summed across the sessions.

  Shared by the dead view (via `calendar_weeks/2`) and `HistoryLive`'s
  `:day_cell` slot so the two calendars can't drift apart.
  """
  def collapse_day_entries(raw_entries) do
    raw_entries
    |> Enum.group_by(fn e -> {e.title, e.source, e.slug} end)
    |> Enum.map(fn {{title, source, slug}, group} ->
      %{
        title: title,
        source: source,
        slug: slug,
        seconds: group |> Enum.map(& &1.seconds) |> Enum.sum(),
        chapters_read: group |> Enum.map(&(Map.get(&1, :chapters_read) || 0)) |> Enum.sum()
      }
    end)
    |> Enum.sort_by(& &1.seconds, :desc)
  end

  def calendar_weeks(month, activity_map) do
    last_day = Date.end_of_month(month)
    # Monday = 1, Sunday = 7
    start_pad = Date.day_of_week(month) - 1
    end_pad = 7 - Date.day_of_week(last_day)

    first = Date.add(month, -start_pad)
    last = Date.add(last_day, end_pad)

    days =
      Date.range(first, last)
      |> Enum.map(fn date ->
        entries = collapse_day_entries(Map.get(activity_map, date, []))
        seconds = entries |> Enum.map(& &1.seconds) |> Enum.sum()

        %{
          date: date,
          day: date.day,
          in_month: date.month == month.month and date.year == month.year,
          seconds: seconds,
          entries: entries
        }
      end)

    max_seconds = days |> Enum.map(& &1.seconds) |> Enum.max() |> max(1)
    weeks = Enum.chunk_every(days, 7)
    {weeks, max_seconds}
  end

  @doc """
  Sized cover URL for a series on the history page: the stored file's
  `variant` when we have one, else the source image via the proxy,
  else nil.
  """
  def history_cover_src(source, slug, manga_meta, variant) do
    meta = Map.get(manga_meta, {source, slug}, %{})

    cond do
      uuid = meta[:cover_uuid] ->
        PhoenixKit.Modules.Storage.URLSigner.signed_url(uuid, variant)

      url = meta[:cover_url] ->
        ~p"/manga/proxy/image?#{%{url: url}}"

      true ->
        nil
    end
  end

  def calendar_day_covers(entries, day_events, manga_meta, limit \\ 3) do
    read =
      Enum.map(entries, fn e ->
        key = {e.source, e.slug}

        %{
          title: e.title,
          src: history_cover_src(e.source, e.slug, manga_meta, "thumbnail"),
          event: Map.get(day_events, key)
        }
      end)

    event_only =
      day_events
      |> Map.keys()
      |> Enum.reject(fn key -> Enum.any?(entries, fn e -> {e.source, e.slug} == key end) end)
      |> Enum.map(fn {source, slug} = key ->
        meta = Map.get(manga_meta, key, %{})

        %{
          title: meta[:title],
          src: history_cover_src(source, slug, manga_meta, "thumbnail"),
          event: Map.get(day_events, key)
        }
      end)

    all = read ++ event_only
    {top, rest} = Enum.split(all, limit)

    case Enum.filter(rest, & &1.event) do
      [] ->
        top

      displaced ->
        keep = limit - length(displaced)

        (Enum.filter(top, & &1.event) ++ Enum.reject(top, & &1.event))
        |> Enum.take(max(keep, 0))
        |> Kernel.++(displaced)
        |> Enum.take(limit)
    end
  end

  def calendar_color(0, _max_seconds), do: ""

  def calendar_color(seconds, max_seconds) do
    ratio = seconds / max_seconds

    cond do
      ratio <= 0.25 -> "bg-success/30"
      ratio <= 0.50 -> "bg-success/50"
      ratio <= 0.75 -> "bg-success/70"
      true -> "bg-success"
    end
  end

  def month_label(date) do
    Calendar.strftime(date, "%B %Y")
  end

  def prev_month_param(date) do
    prev = date |> Date.add(-1) |> Date.beginning_of_month()
    Calendar.strftime(prev, "%Y-%m")
  end

  def next_month_param(date) do
    next = date |> Date.end_of_month() |> Date.add(1)
    Calendar.strftime(next, "%Y-%m")
  end

  def is_current_month?(date) do
    today = Date.utc_today()
    date.year == today.year and date.month == today.month
  end

  def date_param(date) do
    Calendar.strftime(date, "%Y-%m-%d")
  end

  def selected_date_label(date) do
    today = Date.utc_today()

    case Date.diff(today, date) do
      0 -> "Today"
      1 -> "Yesterday"
      _ -> Calendar.strftime(date, "%b %-d, %Y")
    end
  end

  def annotation_color("pink"), do: "rgb(236,72,153)"
  def annotation_color("green"), do: "rgb(74,222,128)"
  def annotation_color("purple"), do: "rgb(168,85,247)"
  def annotation_color("#" <> _ = hex), do: hex
  def annotation_color(_), do: "rgb(59,130,246)"

  def annotation_bg("pink"), do: "rgba(236,72,153,0.15)"
  def annotation_bg("green"), do: "rgba(74,222,128,0.15)"
  def annotation_bg("purple"), do: "rgba(168,85,247,0.15)"
  def annotation_bg("#" <> _ = hex), do: hex_to_rgba(hex, 0.15)
  def annotation_bg(_), do: "rgba(59,130,246,0.15)"

  # Etcher shapes store their color as a hex string ("#93c5fd"); the
  # bg helper needs an `rgba(...)` with low alpha for the row tint.
  defp hex_to_rgba("#" <> hex, alpha) do
    case Integer.parse(hex, 16) do
      {n, ""} when byte_size(hex) == 6 ->
        <<r::8, g::8, b::8>> = <<n::24>>
        "rgba(#{r},#{g},#{b},#{alpha})"

      _ ->
        "rgba(59,130,246,#{alpha})"
    end
  end

  attr :a, :map, required: true

  @doc """
  One line of the comments page, whichever kind it is: a note on a page of a chapter, or a
  comment under a film, a show or someone's profile.
  """
  def comment_entry(%{a: %{kind: :site}} = assigns), do: site_comment_row(assigns)
  def comment_entry(assigns), do: annotation_row(assigns)

  attr :a, :map, required: true

  defp site_comment_row(assigns) do
    ~H"""
    <a
      href={@a.path}
      data-color="site"
      data-user={@a.username}
      data-title={@a.title}
      class="block rounded-lg border border-base-300 bg-base-200 px-4 py-3 transition-opacity hover:opacity-80"
    >
      <div class="flex items-center justify-between gap-2">
        <span class="truncate text-sm font-semibold">{@a.title}</span>
        <span class="whitespace-nowrap text-xs text-base-content/40">
          {if @a.where == "profile", do: "On a profile", else: "Under a title"}
        </span>
      </div>
      <p
        :if={@a.content != ""}
        class="mb-1.5 mt-1.5 line-clamp-2 border-l-2 border-current/20 pl-2.5 text-sm"
      >
        {@a.content}
      </p>
      <img
        :if={@a.gif_url}
        src={@a.gif_url}
        loading="lazy"
        alt="GIF"
        class="mb-1.5 mt-1.5 max-h-40 w-auto rounded-lg"
      />
      <div class="flex items-center justify-between">
        <span class="text-xs text-base-content/40">{@a.username}</span>
        <span :if={@a.like_count > 0} class="text-xs text-base-content/40">
          ♥ {@a.like_count}
        </span>
      </div>
    </a>
    """
  end

  def annotation_row(assigns) do
    ~H"""
    <a
      href={comment_reader_url(@a)}
      data-color={@a.color || "blue"}
      data-user={@a.username}
      data-title={@a.title}
      class="block rounded-lg px-4 py-3 transition-opacity hover:opacity-80"
      style={"background-color: #{annotation_bg(@a.color)}"}
    >
      <div class="flex items-center justify-between gap-2">
        <span class="font-semibold text-sm truncate">{@a.title}</span>
        <span class="text-xs text-base-content/40 whitespace-nowrap">Chapter {@a.chapter}, Page {@a.page}</span>
      </div>
      <p
        :if={@a.content != ""}
        class="text-sm mt-1.5 mb-1.5 pl-2.5 border-l-2 border-current/20 line-clamp-2"
      >
        {@a.content}
      </p>
      <img
        :if={@a.gif_url}
        src={@a.gif_url}
        loading="lazy"
        alt="GIF"
        class="mt-1.5 mb-1.5 rounded-lg max-h-40 w-auto"
      />
      <div class="flex items-center justify-between">
        <span class="text-xs text-base-content/40">
          {@a.username}
          <span
            :if={Map.get(@a, :visibility) == "private"}
            title="Private"
            style="margin-left:0.25rem;"
          >&#128274;</span>
        </span>
        <div class="flex items-center gap-3">
          <span :if={@a.like_count > 0} class="flex items-center gap-1 text-xs text-base-content/40">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="h-3 w-3"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            ><path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M4.318 6.318a4.5 4.5 0 000 6.364L12 20.364l7.682-7.682a4.5 4.5 0 00-6.364-6.364L12 7.636l-1.318-1.318a4.5 4.5 0 00-6.364 0z"
            /></svg>
            {@a.like_count}
          </span>
          <span :if={@a.reply_count > 0} class="flex items-center gap-1 text-xs text-base-content/40">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="h-3 w-3"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            ><path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M3 10h10a8 8 0 018 8v2M3 10l6 6m-6-6l6-6"
            /></svg>
            {@a.reply_count}
          </span>
          <time
            datetime={NaiveDateTime.to_iso8601(@a.inserted_at) <> "Z"}
            class="local-time text-xs text-base-content/40"
          ></time>
        </div>
      </div>
    </a>
    """
  end

  # ── TEMP (beta): stint session display helpers ─────────────────────
  # Serve the placeholder sessions section on the history page until
  # the calendar/timeline rework replaces it.

  @doc """
  Inline style positioning a stint's bar on a 24h track for the given
  local date — left/width as percentages of the day, clamped to the
  date (midnight-crossing stints show only their slice).
  """
  def stint_bar_style(stint, date, tz_offset) do
    case Stint.clamp_to_date(stint, date, utc_offset: tz_offset) do
      nil ->
        "display: none"

      {s, e} ->
        day_start =
          date
          |> DateTime.new!(~T[00:00:00], "Etc/UTC")
          |> DateTime.add(-tz_offset, :second)

        left = DateTime.diff(s, day_start) / 86_400 * 100
        width = max(DateTime.diff(e, s) / 86_400 * 100, 0.4)
        "left: #{Float.round(left, 2)}%; width: #{Float.round(width, 2)}%"
    end
  end

  @doc "A stint timestamp as the user's local HH:MM."
  def stint_local_time(dt, tz_offset) do
    dt
    |> DateTime.add(tz_offset, :second)
    |> Calendar.strftime("%H:%M")
  end

  @doc """
  Chapters completed during a stint — the chapter-read events on the
  stint's item whose read_at falls inside its time window.
  """
  def chapters_in_stint(chapter_reads, stint) do
    for c <- chapter_reads,
        "manga:#{c.source}/#{c.slug}" == stint.item,
        DateTime.compare(c.read_at, stint.started_at) != :lt,
        DateTime.compare(c.read_at, stint.ended_at) != :gt,
        do: c.chapter
  end

  @doc """
  The per-manga stat line under a history entry: chapter range +
  count from the day's chapter-read events, session count from the
  day's stints, and time read — "ch 23–49 · 27 today · 3 sessions ·
  2h 15m read". Chapters behind the day's reading front (an old
  chapter revisited mid-binge) don't stretch the range — they show
  as "· N reread(s)". Dates before the event log (2026-07-15) fall
  back to the aggregate chapter counter. Nil when nothing to say.
  """
  def history_stat_line(manga, chapter_reads, stints) do
    reads =
      for c <- chapter_reads, c.source == manga.source and c.slug == manga.slug, do: c

    sessions = Enum.count(stints, &(&1.item == "manga:#{manga.source}/#{manga.slug}"))
    time = format_reading_time(manga.reading_seconds)

    chapter_part =
      case Enum.uniq_by(reads, & &1.chapter) do
        [] ->
          if manga.chapters_read > 0 do
            "#{manga.chapters_read} #{if manga.chapters_read == 1, do: "chapter", else: "chapters"}"
          end

        uniq ->
          # Walk the day's reads in TIME order: a chapter read while
          # the day's front was already past it is a reread; anything
          # advancing (or matching) the front is forward progress —
          # even across gaps, since chapters that missed the counting
          # bar mid-binge leave holes in the log, not rereads.
          # Unparseable identifiers ("extra") count as forward.
          {forward, rereads, _maxn} =
            Enum.reduce(uniq, {[], 0, nil}, fn c, {fwd, re, maxn} ->
              n = Chapter.number(c.chapter)

              cond do
                n == nil -> {[c.chapter | fwd], re, maxn}
                maxn == nil or n >= maxn -> {[c.chapter | fwd], re, n}
                true -> {fwd, re + 1, maxn}
              end
            end)

          range =
            case Chapter.sort(forward) do
              [] ->
                nil

              [only] ->
                "ch #{display_chapter(only)}"

              sorted ->
                "ch #{display_chapter(List.first(sorted))}–#{display_chapter(List.last(sorted))}"
            end

          base =
            case range do
              nil -> "#{rereads} #{if rereads == 1, do: "reread", else: "rereads"}"
              r -> "#{r} · #{length(forward)} today"
            end

          if range != nil and rereads > 0 do
            base <> " · #{rereads} #{if rereads == 1, do: "reread", else: "rereads"}"
          else
            base
          end
      end

    parts =
      Enum.reject(
        [
          chapter_part,
          if(sessions > 0,
            do: "#{sessions} #{if sessions == 1, do: "session", else: "sessions"}"
          ),
          if(time, do: "#{time} read")
        ],
        &is_nil/1
      )

    if parts != [], do: Enum.join(parts, " · ")
  end

  # "062" → "62" for display; fractional/odd identifiers stay as-is.
  defp display_chapter(ch), do: String.replace(ch, ~r/^0+(?=\d)/, "")

  @doc """
  A stint's slice of the given local date as {start, end} seconds-of-day
  (0..86_400), or nil when the stint doesn't touch the date.
  """
  def stint_day_seconds(stint, date, tz_offset) do
    case Stint.clamp_to_date(stint, date, utc_offset: tz_offset) do
      nil ->
        nil

      {s, e} ->
        day_start =
          date
          |> DateTime.new!(~T[00:00:00], "Etc/UTC")
          |> DateTime.add(-tz_offset, :second)

        {DateTime.diff(s, day_start), DateTime.diff(e, day_start)}
    end
  end

  @doc """
  SVG path along the history clock's continuous 24-hour spiral. Midnight
  starts on the outside and time moves clockwise through two turns, ending
  beside the clock face at the close of the day. Enforces a four-minute
  minimum span so very short sessions remain visible.
  """
  def clock_spiral_path(start_sec, end_sec) do
    start_sec = max(start_sec, 0)
    end_sec = min(max(end_sec, start_sec + 240), 86_400)
    steps = max(ceil((end_sec - start_sec) / 300), 1)

    0..steps
    |> Enum.map(fn step ->
      seconds = start_sec + (end_sec - start_sec) * step / steps
      clock_spiral_point(seconds)
    end)
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {point, index} ->
      if index == 0, do: "M #{point}", else: "L #{point}"
    end)
  end

  defp clock_spiral_point(seconds) do
    fraction = seconds / 86_400
    radius = 98 - 30 * fraction
    angle = fraction * 4 * :math.pi() - :math.pi() / 2
    clock_point(radius, angle)
  end

  defp clock_point(r, angle) do
    x = 120 + r * :math.cos(angle)
    y = 120 + r * :math.sin(angle)
    "#{Float.round(x, 2)} #{Float.round(y, 2)}"
  end

  @doc """
  Smooth heatmap segments for the average-reading spiral. Each hour's
  average is sampled at the centre of its slot and linearly interpolated
  with its neighbours across the full day at 5-minute resolution, so noon
  flows continuously and busy hours fade gradually into quieter ones.
  Opacity is the ratio to the busiest hour **squared** — a contrast curve
  so peaks read clearly and light hours fade toward the bare track rather
  than washing the whole spiral in one tone. Returns
  `[%{start_sec, end_sec, opacity}]`.
  """
  @avg_clock_steps 12
  def avg_clock_arcs(hourly_averages, avg_max) when avg_max > 0 do
    by_hour = Map.new(hourly_averages, fn h -> {h.hour, h.avg_seconds} end)

    for step_i <- 0..(24 * @avg_clock_steps - 1) do
      x = step_i / @avg_clock_steps
      v = interp_hour_value(by_hour, x + 0.5 / @avg_clock_steps)
      ratio = min(v / avg_max, 1.0)

      %{
        start_sec: round(x * 3600),
        end_sec: round((x + 1 / @avg_clock_steps) * 3600),
        opacity: Float.round(ratio * ratio, 3)
      }
    end
  end

  def avg_clock_arcs(_hourly_averages, _avg_max), do: []

  # Interpolated average at fractional day-position `x` (0–24 hours),
  # sampling each hour at its centre and clamping only at day boundaries.
  defp interp_hour_value(by_hour, x) do
    cond do
      x <= 0.5 ->
        Map.get(by_hour, 0, 0)

      x >= 23.5 ->
        Map.get(by_hour, 23, 0)

      true ->
        i = trunc(x - 0.5)
        frac = x - 0.5 - i
        a = Map.get(by_hour, i, 0)
        b = Map.get(by_hour, i + 1, 0)
        a * (1 - frac) + b * frac
    end
  end

  def clean_image_url(url), do: String.replace(url, ~r/#scrambled_\d+$/, "")

  def scramble_offset(url) do
    case Regex.run(~r/#scrambled_(\d+)$/, url) do
      [_, offset] -> offset
      _ -> nil
    end
  end

  # --- Fresco-test reader helpers ------------------------------------------
  # Used by show_fresco.html.heex (test route). Not used by the production
  # reader templates.

  @doc """
  Returns the canonical list of "spread start" page numbers for a chapter
  in double-page mode. Page 1 is always its own start (solo first spread).
  Subsequent pages pair up unless one of the pair is wide (>1.2 aspect),
  in which case the wide page goes solo and pairing resumes after it.

  Used to compute prev/next navigation in `prev_page/3` and `next_page/3`.
  """
  def fresco_spread_starts(images, solo_set \\ %MapSet{}) do
    total = length(images)

    if total == 0 do
      []
    else
      do_spread_starts(2, total, images, solo_set, [1])
    end
  end

  defp do_spread_starts(n, total, _images, _solo_set, acc) when n > total,
    do: Enum.reverse(acc)

  defp do_spread_starts(n, total, images, solo_set, acc) do
    # Same short-circuit branches as the wide-page handling — user-
    # marked solo pages (via chapter_page_overrides kind="solo")
    # consume their own spread slot too.
    step =
      cond do
        wide_page?(images, n) -> 1
        MapSet.member?(solo_set, n) -> 1
        n + 1 > total -> 1
        wide_page?(images, n + 1) -> 1
        MapSet.member?(solo_set, n + 1) -> 1
        true -> 2
      end

    do_spread_starts(n + step, total, images, solo_set, [n | acc])
  end

  @doc """
  True when the page at index `n` (1-based) is wider than it is tall
  (likely a glued-together spread that should be shown solo).
  """
  def wide_page?(images, n) do
    case Enum.at(images, n - 1) do
      %{width: w, height: h} when is_number(w) and is_number(h) and h > 0 -> w > h * 1.2
      _ -> false
    end
  end

  @doc """
  Fold a user's chapter page overrides into the natural image list.

  Returns `{new_images, solo_set, inserted_set}`:

    * `new_images` — image list with synthetic blanks spliced before
      each `insert_blank_before.page_index` (in natural coords). Each
      synthetic image carries `synthetic: true` so the canvas + client
      can label or style it.
    * `solo_set` — `MapSet` of 1-based indices (in the new list) that
      should be displayed alone in double-page mode (`kind = "solo"`).
    * `inserted_set` — `MapSet` of 1-based indices (in the new list)
      of the synthetic blanks themselves. Currently unused server-side,
      handed to the client so it can mark them visually.

  Overrides with `page_index` outside `[1, length(images)]` are ignored
  silently — keeps the UI forgiving when a chapter's page count changes
  upstream.
  """
  def apply_overrides(images, overrides) when is_list(images) and is_list(overrides) do
    inserts =
      overrides
      |> Enum.filter(&(&1.kind == "insert_blank_before"))
      |> Enum.map(& &1.page_index)
      |> MapSet.new()

    solos_natural =
      overrides
      |> Enum.filter(&(&1.kind == "solo"))
      |> Enum.map(& &1.page_index)
      |> MapSet.new()

    total = length(images)

    {rev_new, solo_set, inserted_set, _final_offset} =
      Enum.reduce(1..total//1, {[], MapSet.new(), MapSet.new(), 0}, fn p,
                                                                       {acc, ss, ins, offset} ->
        img = Enum.at(images, p - 1)

        {acc, offset, ins} =
          if MapSet.member?(inserts, p) do
            new_pos_of_blank = p + offset
            {[blank_image_for(img) | acc], offset + 1, MapSet.put(ins, new_pos_of_blank)}
          else
            {acc, offset, ins}
          end

        new_pos_of_p = p + offset
        acc = [img | acc]

        ss =
          if MapSet.member?(solos_natural, p),
            do: MapSet.put(ss, new_pos_of_p),
            else: ss

        {acc, ss, ins, offset}
      end)

    {Enum.reverse(rev_new), solo_set, inserted_set}
  end

  # Synthetic blank that matches the neighbour's dimensions so the
  # canvas-height normalization in `fresco_canvas/3` keeps the spread
  # at a uniform height. Marked `synthetic: true` so JSON encoding +
  # the client can identify it.
  defp blank_image_for(neighbor) do
    w = (neighbor && Map.get(neighbor, :width)) || 1000
    h = (neighbor && Map.get(neighbor, :height)) || 1500

    svg =
      "<svg xmlns='http://www.w3.org/2000/svg' width='#{w}' height='#{h}'>" <>
        "<rect width='100%' height='100%' fill='white'/></svg>"

    %{
      url: "data:image/svg+xml;utf8," <> URI.encode(svg),
      width: w,
      height: h,
      synthetic: true
    }
  end

  @doc """
  Build a Fresco `:sources` list for the current page in double-page mode.

  Matches the production paged reader's "first page is solo with a blank
  facing panel" convention. Pagination in double-page mode therefore
  goes 1 → 2 → 4 → 6 → … so each spread (from page 2 onward) pairs an
  even-indexed page with the next page.

  Direction controls spread ordering:

    * "rtl" (manga default):
      - First (page=1):  `[page 1 | blank]`           (page 1 on left, blank on right)
      - Normal (page=N): `[page N+1 | page N]`        (N+1 on left, N on right)
    * "ltr":
      - First (page=1):  `[blank | page 1]`
      - Normal (page=N): `[page N | page N+1]`

  Single-page mode renders just the one image regardless of direction.
  """
  def fresco_sources(images, page, double_page?, direction \\ "rtl", solo_set \\ %MapSet{}) do
    one = fn n ->
      img = Enum.at(images, n - 1)
      image_src(img)
    end

    total = length(images)
    solo? = fn n -> wide_page?(images, n) or MapSet.member?(solo_set, n) end

    cond do
      # Single-page mode
      not double_page? ->
        [%{src: one.(page)}]

      # First spread — page 1 solo with a blank "cover-facing" panel.
      # A solo-marked or wide first page bypasses the blank.
      page == 1 and solo?.(1) ->
        [%{src: one.(1)}]

      page == 1 ->
        first = Enum.at(images, 0)
        blank = blank_source(first)

        if direction == "ltr" do
          [Map.put(blank, :x, 0), %{src: one.(1), x: 1.0}]
        else
          [%{src: one.(1), x: 0}, Map.put(blank, :x, 1.0)]
        end

      # Current page is wide / user-marked solo — show alone.
      solo?.(page) ->
        [%{src: one.(page)}]

      # No partner (past end). Render current page solo.
      page + 1 > total ->
        [%{src: one.(page)}]

      # Partner is wide / solo — show current alone; the partner gets
      # its own spread on the next navigation step.
      solo?.(page + 1) ->
        [%{src: one.(page)}]

      # Normal spread
      direction == "ltr" ->
        [%{src: one.(page), x: 0}, %{src: one.(page + 1), x: 1.0}]

      true ->
        [%{src: one.(page + 1), x: 0}, %{src: one.(page), x: 1.0}]
    end
  end

  # Synthetic blanks already carry a data: URL; only real fetched
  # images go through the proxy.
  defp image_src(%{synthetic: true, url: url}), do: url
  defp image_src(img), do: proxied_url(img.url)

  # Public delegate so MangaController.chapter_images/2 can build a
  # JSON payload that uses the SAME proxied URL the server-rendered
  # canvas placed in `data-src` — keeping JS-side `applyImageWindow`'s
  # swap-back a no-op identity match instead of a cross-origin re-fetch.
  def proxied_image_src(img), do: image_src(img)

  # A WHITE SVG matched to the real page's aspect ratio so the blank
  # "facing page" reads as a real (empty) page next to the cover-page,
  # not as a transparent gap. Matches production's white-canvas blank.
  defp blank_source(img) do
    w = (img && img.width) || 1000
    h = (img && img.height) || 1500

    svg =
      "<svg xmlns='http://www.w3.org/2000/svg' width='#{w}' height='#{h}'>" <>
        "<rect width='100%' height='100%' fill='white'/></svg>"

    %{src: "data:image/svg+xml;utf8," <> URI.encode(svg)}
  end

  defp proxied_url(url) do
    ~p"/manga/proxy/image?#{%{url: clean_image_url(url)}}"
  end

  @doc """
  JSON-encodes the chapter's image list for client-side use by the
  fresco-test reader: `[{url, width, height}, ...]` with proxied URLs.
  JS uses this to build fresco sources for any page without re-hitting
  the server (instant page navigation + image preloading).
  """
  def fresco_images_json(images) do
    Jason.encode!(
      Enum.map(images, fn img ->
        base = %{url: image_src(img), width: img.width, height: img.height}
        if Map.get(img, :synthetic), do: Map.put(base, :synthetic, true), else: base
      end)
    )
  end

  @doc """
  Build a Fresco `:sources` list for the scroll-mode (manhwa) reader:
  every chapter image stacked vertically, with `y` offsets accumulated
  from each preceding image's natural aspect ratio.

  Fresco's `:sources` layout convention: the first image anchors at
  `x: 0, y: 0, width: 1`, with height derived from natural aspect.
  Subsequent images at `x: 0, y: cumulative_height, width: 1` form a
  continuous vertical stack.

  Images with missing dimensions fall back to a 1:1.5 aspect (typical
  manga / manhwa portrait).
  """
  def fresco_scroll_sources(images) do
    {sources, _} =
      Enum.reduce(images, {[], 0.0}, fn img, {acc, y} ->
        aspect = scroll_aspect(img)
        source = %{src: proxied_url(img.url), x: 0, y: y, width: 1}
        {[source | acc], y + aspect}
      end)

    Enum.reverse(sources)
  end

  defp scroll_aspect(%{width: w, height: h}) when is_number(w) and is_number(h) and w > 0,
    do: h / w

  defp scroll_aspect(_), do: 1.5

  @doc """
  Build a `FrescoStrip.viewer` `:sources` list. Each entry is
  `%{url:, width:, height:}` where width/height are in source pixels —
  the component uses them to set `aspect-ratio` on each `<img>` so the
  layout doesn't collapse when memory-windowing evicts off-screen `src`s.

  Falls back to a 720×1080 placeholder (1:1.5 portrait) if an image lacks
  natural dimensions, matching `fresco_scroll_sources/1`'s fallback aspect.
  """
  def fresco_strip_sources(images) do
    Enum.map(images, fn img ->
      {w, h} = strip_dims(img)
      %{url: proxied_url(img.url), width: w, height: h}
    end)
  end

  defp strip_dims(%{width: w, height: h})
       when is_integer(w) and is_integer(h) and w > 0 and h > 0,
       do: {w, h}

  defp strip_dims(%{width: w, height: h}) when is_number(w) and is_number(h) and w > 0 and h > 0,
    do: {trunc(w), trunc(h)}

  defp strip_dims(_), do: {720, 1080}

  @doc """
  Build a `%Fresco.Canvas{}` containing **every page** of the chapter
  laid out side-by-side on a virtual canvas. This lets the paged reader
  navigate between pages purely by retargeting fresco's pan/zoom
  (`handle.fitImage("page-N")`) — no page reload, no DOM mutation.

  Layout: pages are ordered along the X axis according to reading
  direction. For LTR (Western comics, manhua), page 1 is at `x=0`
  and pages grow rightward. For RTL (manga default), page 1 is at
  the rightmost position and earlier pages have *larger* X — so a
  swipe-right gesture, which in RTL means "next page", aims at a
  smaller X. The canvas dimensions are the sum/max of page sizes.

  Each image carries `id = "page-N"` so JS can fit to it directly:

      handle.fitImage("page-3")    # snap to page 3 single-page
      handle.fitBounds(twoPageBbox) # double-page: fit a 2-page span

  Single-page vs double-page is a *fit decision*, not a layout one:
  same canvas, different bounding boxes. Cover-facing blanks (page 1
  in double mode) become an empty pan area outside the canvas, which
  works because the viewer is mounted with `:infinite_canvas`.
  """
  # Image-loading window radius — units differ per mode:
  #   * Single-page: in *pages* — load current ± @window_pages.
  #   * Double-page: in *spreads* — load current spread ± @window_spreads
  #     (the same N-spread radius is honored client-side too so a
  #     double-tap-Next lands on an already-loaded spread, not a
  #     placeholder that has to fetch).
  # Out-of-window pages render with an empty SVG data: URL so the
  # browser doesn't fetch them. `applyImageWindow` in
  # show_fresco.html.heex performs the same swap on every navigation.
  @window_pages 2
  @window_spreads 2

  def fresco_canvas(
        images,
        direction \\ "rtl",
        etcher_annotations \\ [],
        current_page \\ 1,
        double_page \\ false,
        spread_starts \\ []
      ) do
    total = length(images)
    max_h = images |> Enum.map(&page_height/1) |> Enum.max(fn -> 1500 end)

    in_window =
      compute_in_window(total, current_page, double_page, spread_starts)

    # `ordered` lists pages in canvas-X order, which differs by reading
    # direction. We always pair `{img, original_1_based_index}` so the
    # image id stays "page-N" regardless of layout.
    ordered =
      if direction == "ltr" do
        images |> Enum.with_index(1)
      else
        images |> Enum.with_index(1) |> Enum.reverse()
      end

    total_w = images |> Enum.map(&page_width/1) |> Enum.sum()

    canvas = Fresco.Canvas.new(width: total_w, height: max_h, background: "#ffffff")

    {canvas, _x} =
      Enum.reduce(ordered, {canvas, 0}, fn {img, n}, {c, x} ->
        w = page_width(img)
        h = page_height(img)

        # Pass natural_width / natural_height so fresco emits explicit
        # `data-canvas-height` at server-render time. Without it, the
        # JS engine waits for image load to compute the height — and
        # `handle.imageBoundsFor(id)` returns `height: 0` in the
        # meantime, which makes `fitBounds` silently bail (its guard
        # is `if (rect.height <= 0) return;`). Our nav code calls
        # fitBounds immediately on mount; passing natural dims here is
        # what makes the initial single-page fit actually take effect.
        #
        # Out-of-window pages get a placeholder src — the browser
        # never fetches the real image. JS swaps it in on the first
        # navigation that brings page N within range.
        src =
          if MapSet.member?(in_window, n),
            do: image_src(img),
            else: placeholder_src()

        c2 =
          Fresco.Canvas.add_image(c, %{
            id: "page-#{n}",
            src: src,
            x: x,
            y: div(max_h - h, 2),
            width: w,
            natural_width: w,
            natural_height: h
          })

        {c2, x + w}
      end)

    # Stash existing etcher annotations under the canvas extension key
    # so `<Etcher.layer>` hydrates them via `handle.getExtension("etcher")`.
    Fresco.Canvas.put_extension(canvas, "etcher", %{
      "version" => "1",
      "annotations" => etcher_annotations
    })
  end

  # Single-page mode → page-radius window centred on `current_page`.
  defp compute_in_window(total, current_page, false, _spread_starts) do
    lo = max(1, current_page - @window_pages)
    hi = min(total, current_page + @window_pages)
    MapSet.new(lo..hi)
  end

  # Double-page mode → spread-radius window. Find the spread anchor
  # for `current_page`, expand `@window_spreads` anchors in each
  # direction, then resolve the page-range as
  # `start_anchor .. (next_anchor_after_window - 1)` (or total when
  # we're at the tail).
  defp compute_in_window(total, current_page, true, []) do
    # No spread_starts data — fall back to page-radius scaled for
    # double mode (each spread is ~2 pages, so cover ~2 spreads of
    # buffer).
    lo = max(1, current_page - 2 * @window_spreads)
    hi = min(total, current_page + 2 * @window_spreads + 1)
    MapSet.new(lo..hi)
  end

  defp compute_in_window(total, current_page, true, spread_starts) do
    current_anchor = spread_anchor_for_starts(spread_starts, current_page)
    idx = Enum.find_index(spread_starts, &(&1 == current_anchor)) || 0

    start_idx = max(0, idx - @window_spreads)
    end_idx = min(length(spread_starts) - 1, idx + @window_spreads)

    start_page = Enum.at(spread_starts, start_idx)

    end_page =
      case Enum.at(spread_starts, end_idx + 1) do
        nil -> total
        next_anchor -> next_anchor - 1
      end

    MapSet.new(start_page..end_page)
  end

  defp spread_anchor_for_starts([], _page), do: 1

  defp spread_anchor_for_starts(starts, page) do
    Enum.reduce_while(starts, hd(starts), fn s, acc ->
      if s <= page, do: {:cont, s}, else: {:halt, acc}
    end)
  end

  # Empty-SVG data URL — the browser keeps the img element at its
  # CSS-driven dimensions but doesn't issue any network request.
  defp placeholder_src do
    "data:image/svg+xml;utf8,%3Csvg%20xmlns='http://www.w3.org/2000/svg'%2F%3E"
  end

  defp page_width(%{width: w}) when is_number(w) and w > 0, do: trunc(w)
  defp page_width(_), do: 1000

  defp page_height(%{height: h}) when is_number(h) and h > 0, do: trunc(h)
  defp page_height(_), do: 1500

  @doc """
  Build a URL for the same chapter+page with overridden flags. Used by
  the settings modal toggles (direction, double-page) that DO require
  a server-side re-render — the canvas's page-X layout differs by
  reading direction, so flipping it can't be done in place client-side.
  Page-by-page nav stays JS-driven (no reload).
  """
  def paged_self_url(
        %{source: source, slug: slug, chapter: chapter, page: page} = assigns,
        overrides
      ) do
    double = Map.get(overrides, :double, assigns.double_page)
    dir = Map.get(overrides, :dir, assigns.direction)

    qs =
      [{"page", Integer.to_string(page)}]
      |> then(fn list -> if double, do: [{"double", "1"} | list], else: list end)
      |> then(fn list -> if dir == "ltr", do: [{"dir", "ltr"} | list], else: list end)

    base = "/manga/#{source}/#{slug}/#{chapter}"
    if qs == [], do: base, else: base <> "?" <> URI.encode_query(qs)
  end

  @doc """
  daisyUI button class string for active/inactive switcher buttons in
  the paged-test settings modal. Used for the direction + double-page
  toggle anchors so the chosen state is visually distinct.
  """
  def paged_btn_class(true),
    do: "btn btn-sm btn-outline btn-active no-animation pointer-events-none"

  def paged_btn_class(false), do: "btn btn-sm btn-outline"

  @doc """
  Navigate one spread back in double-page mode (or one page back in single-
  page mode). In double-page mode the caller passes the precomputed spread
  starts so prev/next correctly skip wide-page slots.
  """
  def prev_page(page, false = _double, _starts), do: max(1, page - 1)

  def prev_page(page, true, starts) do
    case Enum.filter(starts, &(&1 < page)) do
      [] -> 1
      list -> List.last(list)
    end
  end

  @doc """
  Navigate one spread forward. Returns a number greater than `total` when
  the user is on the last spread (so the next-link can be disabled).
  """
  def next_page(page, false = _double, _starts, _total), do: page + 1

  def next_page(page, true, starts, total) do
    Enum.find(starts, total + 1, &(&1 > page))
  end

  def page_params(page, double_page?, direction \\ "rtl") do
    base = %{"page" => page}
    base = if double_page?, do: Map.put(base, "double", "1"), else: base
    if direction == "ltr", do: Map.put(base, "dir", "ltr"), else: base
  end

  def double_param(double_page?, direction \\ "rtl") do
    base = if double_page?, do: %{"double" => "1"}, else: %{}
    if direction == "ltr", do: Map.put(base, "dir", "ltr"), else: base
  end
end
