defmodule Roki.Manga.Shelf do
  @moduledoc """
  The rules of the saved-manga page (`RokiWeb.MangaShelfLive`): which titles each chip keeps,
  how each sort orders them, and what a click on a chip does next. Pure functions over the
  saved rows (`Roki.Manga.Library.list_saved_manga/1`), so the page and its tests share them.

  Ported from the page's former inline script, keeping its behaviour:

    * **Chips** — five built-in ones (`modes/0`) and the account's own categories. Each cycles
      on click: off → on (only those) → excluded (all but those) → off. A category chip
      clicked while excluded comes back on rather than off, as before. "All" clears both.
    * **Caught up** — read up to the newest known chapter: the floor of `last_chapter` at or
      above `last_chapter_number` (else `total_chapters`). Not for a completed title.
    * **Sorts** — `sorts/0`; the dates newest first with missing dates last, chapter counts
      either way, and "fastest to catch up" by chapters left (unknown last).
  """

  @modes [
    {"reading", "Reading"},
    {"caughtup", "Caught Up"},
    {"mangatoread", "Manga To Read"},
    {"manhwatoread", "Manhwa To Read"},
    {"completed", "Completed"}
  ]
  @mode_ids Enum.map(@modes, &elem(&1, 0))

  @sorts [
    {"updated_at", "Last read"},
    {"newest_chapter_at", "Newest chapter"},
    {"inserted_at", "Date added"},
    {"chapters_desc", "Most chapters"},
    {"chapters_asc", "Fewest chapters"},
    {"catch_up", "Nearly caught up"}
  ]
  @sort_ids Enum.map(@sorts, &elem(&1, 0))

  @filters [{"all", "All"}, {"read", "Read"}, {"unread", "Unread"}]
  @filter_ids Enum.map(@filters, &elem(&1, 0))

  @statuses [
    {"any", "Any"},
    {"ongoing", "Ongoing"},
    {"completed", "Completed"},
    {"hiatus", "Hiatus"},
    {"unknown", "Unknown"}
  ]
  @status_ids Enum.map(@statuses, &elem(&1, 0))

  def modes, do: @modes
  def sorts, do: @sorts
  def filters, do: @filters
  def statuses, do: @statuses

  def mode?(id), do: id in @mode_ids
  def sort?(id), do: id in @sort_ids
  def filter?(id), do: id in @filter_ids
  def status?(id), do: id in @status_ids

  @typedoc "What the chips say: nothing, a built-in chip on or excluded, a category on or excluded."
  @type chip ::
          nil
          | {:mode, String.t()}
          | {:exclude_mode, String.t()}
          | {:category, integer()}
          | {:exclude, integer()}

  @doc "The chip state after a click on `clicked` (`:all`, `{:mode, id}` or `{:category, id}`)."
  def next_chip(_current, :all), do: nil
  def next_chip({:mode, m}, {:mode, m}), do: {:exclude_mode, m}
  def next_chip({:exclude_mode, m}, {:mode, m}), do: nil
  def next_chip(_current, {:mode, m}), do: {:mode, m}
  def next_chip({:category, id}, {:category, id}), do: {:exclude, id}
  def next_chip(_current, {:category, id}), do: {:category, id}

  # ── which titles a chip keeps ──────────────────────────────────────

  @doc "Started (a chapter saved) and not finished."
  def started?(m), do: m.last_chapter not in [nil, ""]

  def unstarted?(m), do: not started?(m) and not truthy(m.completed)

  def caught_up?(m) do
    with true <- started?(m) and not truthy(m.completed),
         threshold when is_number(threshold) <- threshold(m),
         read when is_integer(read) <- chapter_floor(m.last_chapter) do
      read >= threshold
    else
      _ -> false
    end
  end

  @doc "Chapters left to read up to the newest known one; `:infinity` when that is unknown."
  def chapters_left(m) do
    case threshold(m) do
      nil -> :infinity
      t -> max(0, t - (chapter_floor(m.last_chapter) || 0))
    end
  end

  @doc "Whether a title belongs to a built-in chip. `kind` is `\"paged\"` (manga) or `\"scroll\"` (manhwa)."
  def in_mode?(m, _kind, "reading"),
    do: started?(m) and not truthy(m.completed) and not caught_up?(m)

  def in_mode?(m, _kind, "caughtup"), do: caught_up?(m)
  def in_mode?(m, kind, "mangatoread"), do: unstarted?(m) and kind == "paged"
  def in_mode?(m, kind, "manhwatoread"), do: unstarted?(m) and kind == "scroll"
  def in_mode?(m, _kind, "completed"), do: truthy(m.completed)
  def in_mode?(_m, _kind, _), do: true

  @doc """
  The titles to show, in order. `items` are maps carrying the saved row as `:m`, its `:kind`
  and `:status` (publication status) and its `:key` (`"source:slug"`); `members` is the set
  of keys in the chosen category (only consulted for a category chip).
  """
  def visible(items, chip, filter, status, sort, members \\ MapSet.new()) do
    items
    |> Enum.filter(&chip_keeps?(&1, chip, members))
    |> Enum.filter(&filter_keeps?(&1.m, filter))
    |> Enum.filter(&(status in [nil, "any"] or &1.status == status))
    |> sort(sort)
  end

  defp chip_keeps?(_item, nil, _), do: true
  defp chip_keeps?(item, {:mode, mode}, _), do: in_mode?(item.m, item.kind, mode)
  defp chip_keeps?(item, {:exclude_mode, mode}, _), do: not in_mode?(item.m, item.kind, mode)
  defp chip_keeps?(item, {:category, _}, members), do: MapSet.member?(members, item.key)
  defp chip_keeps?(item, {:exclude, _}, members), do: not MapSet.member?(members, item.key)

  defp filter_keeps?(m, "read"), do: started?(m)
  defp filter_keeps?(m, "unread"), do: not started?(m)
  defp filter_keeps?(_m, _), do: true

  # ── order ──────────────────────────────────────────────────────────

  def sort(items, "inserted_at"), do: newest_first(items, :inserted_at)
  def sort(items, "newest_chapter_at"), do: newest_first(items, :newest_chapter_at)
  def sort(items, "chapters_desc"), do: Enum.sort_by(items, &(-chapters(&1.m)))
  def sort(items, "chapters_asc"), do: Enum.sort_by(items, &chapters(&1.m))

  def sort(items, "catch_up") do
    Enum.sort_by(items, fn i ->
      case chapters_left(i.m) do
        :infinity -> {1, 0}
        n -> {0, n}
      end
    end)
  end

  def sort(items, _updated_at), do: newest_first(items, :updated_at)

  # Newest first, a title without the date last; stable, so ties keep the list's own order.
  defp newest_first(items, field) do
    {dated, undated} = Enum.split_with(items, &(not is_nil(Map.get(&1.m, field))))
    Enum.sort_by(dated, &stamp(Map.get(&1.m, field)), :desc) ++ undated
  end

  defp stamp(%DateTime{} = d), do: DateTime.to_unix(d, :microsecond)

  defp stamp(%NaiveDateTime{} = d),
    do: d |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:microsecond)

  defp stamp(_), do: 0

  defp chapters(m), do: (is_integer(m.total_chapters) && m.total_chapters) || 0

  # ── the counts each chip carries in its tooltip ────────────────────

  @doc "How many titles each built-in chip holds, over the whole library."
  def counts(items) do
    Map.new(@mode_ids, fn mode -> {mode, Enum.count(items, &in_mode?(&1.m, &1.kind, mode))} end)
  end

  # ── helpers ────────────────────────────────────────────────────────

  defp threshold(m) do
    cond do
      is_number(m.last_chapter_number) -> m.last_chapter_number
      is_integer(m.total_chapters) and m.total_chapters > 0 -> m.total_chapters
      true -> nil
    end
  end

  @doc "`\"42.5\"` → 42; nil when it is not a number."
  def chapter_floor(nil), do: nil

  def chapter_floor(s) when is_binary(s) do
    case Float.parse(String.trim(s)) do
      {f, _} -> floor(f)
      :error -> nil
    end
  end

  def chapter_floor(n) when is_number(n), do: floor(n)
  def chapter_floor(_), do: nil

  defp truthy(v), do: v not in [nil, false]
end
