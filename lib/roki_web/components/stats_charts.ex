defmodule RokiWeb.StatsCharts do
  @moduledoc """
  The charts at the foot of the stats page: the hours over time, drawn in HTML.

  Four column charts over the same days the heatmap draws (`Roki.Spent.days_by_kind/4`): the
  last twelve months and every year, stacked by kind in the colours the chips above use, and
  the days of the week; and, from the sessions the player records, the hours of the day. They
  follow the kind chips (a kind left out is left out here) and not the range tabs, since each
  chart is its own span of time and says so.

  A column is its own hit target: hover or focus shows the month, the total and the split; the
  biggest column carries its figure; and every chart has its table under "As a table", so no
  number lives only in a tooltip. Marks are kept thin (24 px at most), the segments of a stack
  are parted by the page's own colour, and the grid is three hairlines.
  """
  use Phoenix.Component

  alias Roki.{Laev, Spent}

  @hours ~w(0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23)

  attr :months, :list, required: true
  attr :years, :list, required: true
  attr :weekdays, :list, required: true
  attr :hours, :map, required: true, doc: "`Roki.Stints.by_hour/2`"
  attr :sessions, :integer, required: true, doc: "how many sessions the hours come from"
  attr :kinds, :list, required: true, doc: "the kinds the filter leaves in, in order"

  def charts(assigns) do
    hour_cols =
      for {h, label} <- Enum.with_index(@hours, fn l, i -> {i, l} end) do
        seconds = Map.get(assigns.hours, h, 0)
        %{key: h, label: label, sub: nil, by_kind: %{all: seconds}, total: seconds}
      end

    assigns =
      assign(assigns,
        hour_cols: hour_cols,
        labels: Map.new(Spent.kinds()),
        several_years: length(assigns.years) > 1,
        enough_sessions: assigns.sessions >= 10
      )

    ~H"""
    <section class="space-y-6">
      <div>
        <h2 class="text-xl font-semibold">Over time</h2>
        <p class="text-sm text-base-content/60">
          The same days as above, added up. The kinds chosen at the top are the kinds here;
          each chart spans its own time and says which.
        </p>
      </div>

      <div class="grid gap-8 lg:grid-cols-2">
        <.columns
          id="chart-months"
          title="By month"
          note="the last twelve months"
          cols={@months}
          kinds={@kinds}
          labels={@labels}
          every={1}
        />
        <.columns
          :if={@several_years}
          id="chart-years"
          title="By year"
          note="all time"
          cols={@years}
          kinds={@kinds}
          labels={@labels}
          every={years_every(length(@years))}
        />
        <.columns
          id="chart-weekdays"
          title="By day of the week"
          note="all time"
          cols={@weekdays}
          kinds={@kinds}
          labels={@labels}
          every={1}
        />
        <.columns
          :if={@enough_sessions}
          id="chart-hours"
          title="By time of day"
          note={"from #{@sessions} sessions the player recorded"}
          cols={@hour_cols}
          kinds={[:all]}
          labels={%{all: "Watched"}}
          every={6}
        />
      </div>

      <div
        :if={length(@kinds) > 1}
        class="flex flex-wrap gap-x-4 gap-y-1 text-xs text-base-content/70"
      >
        <span :for={kind <- @kinds} class="flex items-center gap-1.5">
          <span class={["h-2.5 w-2.5 rounded-sm", fill(kind)]}></span>
          {@labels[kind]}
        </span>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :note, :string, required: true
  attr :cols, :list, required: true, doc: "`[%{key:, label:, sub:, by_kind:, total:}]`"
  attr :kinds, :list, required: true, doc: "the series, bottom of the stack first"
  attr :labels, :map, required: true
  attr :every, :integer, default: 1, doc: "label every nth column (the first always)"

  defp columns(assigns) do
    max = assigns.cols |> Enum.map(& &1.total) |> Enum.max(fn -> 0 end)
    top = Spent.nice_top(max)
    n = length(assigns.cols)

    assigns =
      assign(assigns,
        max: max,
        top: top,
        n: n,
        ticks: [{0, axis(top)}, {50, axis(div(top, 2))}, {100, "0"}],
        empty?: max == 0
      )

    ~H"""
    <div id={@id} class="space-y-2">
      <div class="flex flex-wrap items-baseline justify-between gap-x-3">
        <h3 class="font-medium">{@title}</h3>
        <p class="text-xs text-base-content/60">{@note}</p>
      </div>

      <div class="flex gap-2">
        <div class="relative h-40 w-9 shrink-0 text-right text-[11px] tabular-nums text-base-content/50">
          <span
            :for={{pct, label} <- @ticks}
            class="absolute right-0 -translate-y-1/2 leading-none"
            style={"top: #{pct}%"}
          >
            {label}
          </span>
        </div>

        <div class="relative min-w-0 flex-1">
          <div class="pointer-events-none absolute inset-x-0 top-0 h-40">
            <div
              :for={{pct, _} <- @ticks}
              class={[
                "absolute inset-x-0 border-t",
                if(pct == 100, do: "border-base-content/20", else: "border-base-content/10")
              ]}
              style={"top: #{pct}%"}
            >
            </div>
          </div>

          <ol class="relative flex h-40 items-end gap-1 sm:gap-1.5" role="list">
            <li
              :for={{col, i} <- Enum.with_index(@cols)}
              class="group relative flex h-full min-w-0 flex-1 flex-col justify-end outline-none"
              tabindex="0"
              aria-label={"#{col.label}#{if col.sub, do: " " <> col.sub}: #{Laev.duration(col.total)}"}
            >
              <div
                class="relative mx-auto flex w-full max-w-6 flex-col-reverse gap-[2px] rounded-t transition-opacity group-hover:opacity-75 group-focus:opacity-75"
                style={"height: #{height(col.total, @top)}%"}
              >
                <%!-- The biggest column carries its figure; the rest are read off the axis, the
                     tooltip or the table. It sits over the slot rather than in it, so a narrow
                     column never cuts it short. --%>
                <span
                  :if={col.total == @max and @max > 0}
                  class="absolute bottom-full left-1/2 mb-1 -translate-x-1/2 whitespace-nowrap text-[11px] tabular-nums leading-none text-base-content/70"
                >
                  {cap(col.total)}
                </span>
                <div
                  :for={{kind, j} <- Enum.with_index(@kinds)}
                  :if={Map.get(col.by_kind, kind, 0) > 0}
                  class={[fill(kind), top?(col.by_kind, @kinds, j) && "rounded-t"]}
                  style={"flex: #{Map.get(col.by_kind, kind, 0)} 0 0"}
                >
                </div>
              </div>

              <div
                :if={col.total > 0}
                class={[
                  "pointer-events-none absolute bottom-full z-10 mb-1.5 hidden w-max max-w-[13rem] rounded-box bg-base-100 p-2 text-xs shadow-lg ring-1 ring-base-content/10 group-hover:block group-focus:block",
                  side(i, @n)
                ]}
                role="tooltip"
              >
                <div class="text-base-content/70">{col.label}{if col.sub, do: " " <> col.sub}</div>
                <div class="font-semibold tabular-nums">{Laev.duration(col.total)}</div>
                <div
                  :for={kind <- Enum.reverse(@kinds)}
                  :if={length(@kinds) > 1 and Map.get(col.by_kind, kind, 0) > 0}
                  class="mt-0.5 flex items-center gap-1.5 text-base-content/70"
                >
                  <span class={["h-2 w-2 shrink-0 rounded-sm", fill(kind)]}></span>
                  <span>{@labels[kind]}</span>
                  <span class="ml-auto pl-3 tabular-nums">{Laev.duration(col.by_kind[kind])}</span>
                </div>
              </div>
            </li>
          </ol>

          <ol class="mt-1 flex gap-1 text-[11px] leading-tight text-base-content/60 sm:gap-1.5">
            <li :for={{col, i} <- Enum.with_index(@cols)} class="min-w-0 flex-1 text-center">
              <%!-- A label may be wider than its slot (a year on a phone); the slots beside a
                   labelled one are blank when `every` says so, and it is let out into them. --%>
              <span :if={rem(i, @every) == 0} class="block whitespace-nowrap">{col.label}</span>
              <span :if={col.sub != nil and rem(i, @every) == 0} class="block text-base-content/40">
                {col.sub}
              </span>
            </li>
          </ol>
        </div>
      </div>

      <p :if={@empty?} class="text-xs text-base-content/50">Nothing in this span.</p>

      <details :if={!@empty?} class="text-xs">
        <summary class="cursor-pointer text-base-content/60 hover:text-base-content">
          As a table
        </summary>
        <div class="mt-1 overflow-x-auto">
          <table class="table table-xs">
            <thead>
              <tr>
                <th></th>
                <th :for={kind <- @kinds} :if={length(@kinds) > 1} class="text-right">
                  {@labels[kind]}
                </th>
                <th class="text-right">Total</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={col <- @cols} :if={col.total > 0}>
                <td>{col.label}{if col.sub, do: " " <> col.sub}</td>
                <td :for={kind <- @kinds} :if={length(@kinds) > 1} class="text-right tabular-nums">
                  {Laev.duration(Map.get(col.by_kind, kind, 0))}
                </td>
                <td class="text-right font-medium tabular-nums">{Laev.duration(col.total)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </details>
    </div>
    """
  end

  # The same colour a kind has in the list and the chips above (`RokiWeb.StatsLive`); one
  # series alone takes the page's ink, since it is not any one kind.
  defp fill(:movie), do: "bg-primary/80"
  defp fill(:tv), do: "bg-info/80"
  defp fill(:anime), do: "bg-secondary/80"
  defp fill(:manga), do: "bg-success/80"
  defp fill(_all), do: "bg-base-content/55"

  # The topmost segment of a stack is the one with rounded corners.
  defp top?(by_kind, kinds, j) do
    kinds |> Enum.drop(j + 1) |> Enum.all?(&(Map.get(by_kind, &1, 0) == 0))
  end

  # The figure on the biggest column: whole hours past ten, so it stays short.
  defp cap(seconds) when seconds >= 10 * 3600, do: "#{div(seconds, 3600)}h"
  defp cap(seconds), do: axis(seconds)

  defp height(_seconds, 0), do: 0
  defp height(seconds, top), do: Float.round(seconds * 100 / top, 2)

  # An axis figure: hours as a whole number once there is an hour, minutes before that.
  defp axis(seconds) when seconds >= 3600 do
    hours = seconds / 3600
    if hours == Float.floor(hours), do: "#{round(hours)}h", else: "#{Float.round(hours, 1)}h"
  end

  defp axis(seconds), do: "#{div(seconds, 60)}m"

  # The tooltip stays inside the chart: the first columns' open to the right, the last to the
  # left, the rest sit centred over their column.
  defp side(i, _n) when i < 2, do: "left-0"
  defp side(i, n) when i >= n - 2, do: "right-0"
  defp side(_i, _n), do: "left-1/2 -translate-x-1/2"

  # Years get a label each while they fit, then every other, then every third.
  defp years_every(n) when n <= 8, do: 1
  defp years_every(n) when n <= 16, do: 2
  defp years_every(_n), do: 3
end
