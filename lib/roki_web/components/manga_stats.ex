defmodule RokiWeb.MangaStats do
  @moduledoc """
  Reading time, as the reader's own stats page drew it: the total, and every series
  as a bar of on-site and off-site time with the longest first.

  It lives here so `/:username/stats` can show reading next to watching rather than
  the reader keeping a stats page of its own. The markup is the reader's, and the
  numbers still come from `Roki.Manga.Library.list_reading_stats/1` — manga tables,
  not laev's, so this shows whether or not the terminal app is connected.
  """
  use RokiWeb, :html

  import RokiWeb.MangaHTML, only: [format_reading_time: 1, reading_time_parts: 1]

  @doc """
  `{total, on-site, off-site}` seconds across every series, the reader's own split:
  on-site is the manual override when one is set, else what the reader timed; off-site
  is what the person entered by hand.
  """
  def totals(stats) do
    Enum.reduce(stats, {0, 0, 0}, fn m, {total, onsite, offsite} ->
      on = m.reading_seconds_adjusted || m.reading_seconds || 0
      off = m.reading_seconds_offsite || 0
      {total + on + off, onsite + on, offsite + off}
    end)
  end

  attr :stats, :list, required: true, doc: "`Library.list_reading_stats/1`, longest first"
  attr :total_seconds, :integer, required: true
  attr :onsite_seconds, :integer, required: true
  attr :offsite_seconds, :integer, required: true

  def reading(assigns) do
    ~H"""
    <section id="reading" class="scroll-mt-4">
      <%!-- Title + legend on one line, wrapping to two on narrow viewports.
         Each pair shows the dark (on-site) + light (off-site) swatch for
         a status: primary = in progress, success = completed. --%>
      <div class="flex items-center justify-between mb-4 flex-wrap gap-x-4 gap-y-2">
        <h2 class="text-xl font-semibold">Reading</h2>
        <div
          :if={@stats != []}
          class="flex items-center gap-x-4 gap-y-1 text-xs text-base-content/70 flex-wrap"
        >
          <div class="flex items-center gap-3">
            <span class="flex items-center gap-1">
              <span class="w-3 h-3 rounded-sm bg-primary"></span>
              <span>on-site</span>
            </span>
            <span class="flex items-center gap-1">
              <span class="w-3 h-3 rounded-sm bg-primary/40"></span>
              <span>off-site</span>
            </span>
          </div>
          <div class="flex items-center gap-3">
            <span class="flex items-center gap-1">
              <span class="w-3 h-3 rounded-sm bg-success"></span>
              <span>completed on-site</span>
            </span>
            <span class="flex items-center gap-1">
              <span class="w-3 h-3 rounded-sm bg-success/40"></span>
              <span>completed off-site</span>
            </span>
          </div>
        </div>
      </div>

      <%= if @stats != [] do %>
        <div class="bg-base-200 rounded-xl p-4 mb-6 text-center">
          <p class="text-xs text-base-content/50 uppercase tracking-wide mb-1">Total Reading Time</p>
          <p class="text-3xl font-bold">{format_reading_time(@total_seconds)}</p>
          <p
            :if={@offsite_seconds > 0 || @onsite_seconds > 0}
            class="text-xs text-base-content/60 mt-1"
          >
            <span :if={@offsite_seconds > 0}>{format_reading_time(@offsite_seconds)} offsite</span>
            <span :if={@offsite_seconds > 0 && @onsite_seconds > 0}> · </span>
            <span :if={@onsite_seconds > 0}>{format_reading_time(@onsite_seconds)} on site</span>
          </p>
        </div>

        <% top = Enum.at(@stats, 0) %>
        <% max_seconds =
          (top.reading_seconds_adjusted || top.reading_seconds || 0) +
            (top.reading_seconds_offsite || 0) %>
        <% max_seconds = max(max_seconds, 1) %>
        <div class="flex flex-col gap-3">
          <a
            :for={{manga, rank} <- Enum.with_index(@stats, 1)}
            href={~p"/manga/#{manga.source}/#{manga.slug}"}
            class="flex items-center gap-3 hover:opacity-80 transition-opacity"
          >
            <%!-- Leaderboard rank. Top 3 get a podium accent (gold / silver /
               bronze); everything else falls back to the muted base style. --%>
            <span class={[
              "flex-shrink-0 w-8 text-right tabular-nums font-bold",
              cond do
                rank == 1 -> "text-yellow-500 text-xl"
                rank == 2 -> "text-zinc-400 text-lg"
                rank == 3 -> "text-amber-700 text-lg"
                true -> "text-base-content/40 text-sm"
              end
            ]}>
              {rank}
            </span>
            <img
              src={~p"/manga/proxy/image?#{%{url: manga.cover_url}}"}
              alt={manga.title}
              class="w-12 h-16 rounded-lg object-cover flex-shrink-0"
            />
            <div class="flex-1 min-w-0">
              <p class="text-sm font-medium truncate mb-1">{manga.title}</p>
              <% onsite = manga.reading_seconds_adjusted || manga.reading_seconds || 0 %>
              <% offsite = manga.reading_seconds_offsite || 0 %>
              <% total = onsite + offsite %>
              <%!-- In-progress in the theme's `primary` (still actively
                 growing); completed in the theme's `success` — green
                 across nearly every DaisyUI theme, which reads as
                 "done!" much better than the muted gray that
                 `secondary` / `accent` land on. Themes that already
                 make `primary` green will see a near-collision, but
                 those are rare enough to live with. Same dark-onsite /
                 light-offsite split in both palettes. --%>
              <div
                class="rounded-sm h-10 flex overflow-hidden"
                style={"width: #{Float.round(total / max_seconds * 100, 1)}%"}
              >
                <div
                  :if={offsite > 0}
                  class={if manga.completed, do: "bg-success/40 h-full", else: "bg-primary/40 h-full"}
                  style={"width: #{Float.round(offsite / total * 100, 1)}%"}
                >
                </div>
                <div
                  :if={onsite > 0}
                  class={if manga.completed, do: "bg-success h-full", else: "bg-primary h-full"}
                  style={"width: #{Float.round(onsite / total * 100, 1)}%"}
                >
                </div>
              </div>
            </div>
            <% row_total =
              (manga.reading_seconds_adjusted || manga.reading_seconds || 0) +
                (manga.reading_seconds_offsite || 0) %>
            <% row_approx =
              !!manga.reading_seconds_offsite_approximate && (manga.reading_seconds_offsite || 0) > 0 %>
            <% {row_h, row_m} = reading_time_parts(row_total) %>
            <p class="text-base font-bold flex-shrink-0 tabular-nums whitespace-nowrap text-right w-24">
              <span class="inline-block w-12 text-right"><span
                :if={row_approx}
                class="text-base-content/40 font-normal mr-px"
              >~</span>{row_h}</span><span class="inline-block w-9 text-right ml-1">{row_m}</span>
            </p>
          </a>
        </div>
      <% else %>
        <div class="text-center py-16">
          <p class="text-base-content/70">
            No reading time recorded yet. Start reading to see your stats here.
          </p>
        </div>
      <% end %>
    </section>
    """
  end
end
