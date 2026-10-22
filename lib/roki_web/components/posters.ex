defmodule RokiWeb.PosterComponents do
  @moduledoc "The poster card shared by every page that lists titles."
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: RokiWeb.Endpoint,
    router: RokiWeb.Router,
    statics: RokiWeb.static_paths()

  attr :item, :map,
    required: true,
    doc: "a title: %{title, poster, type, year?, note?, season?, episode?, vote?, seen?}"

  attr :seen, :boolean, default: nil, doc: "watched? Falls back to the item's own :seen"

  attr :cached_titles, :any,
    default: nil,
    doc: "MapSet of {type, id} with cached sources: those posters say so"

  attr :upcoming, :any,
    default: nil,
    doc: "map of {type, id} => release date for titles that are not out yet: a red mark"

  attr :compact, :boolean,
    default: false,
    doc: "no caption under the poster: progress sits on the poster, the rest on hover"

  def poster(assigns) do
    assigns =
      assign(
        assigns,
        :watched?,
        assigns.seen || (assigns.seen == nil && assigns.item[:seen] == true)
      )

    assigns =
      assign(assigns,
        href: href(assigns.item),
        prog: progress_of(assigns.item),
        due:
          if(is_map(assigns.upcoming),
            do: assigns.upcoming[{assigns.item[:type], assigns.item[:id]}]
          ),
        cached?:
          match?(%MapSet{}, assigns.cached_titles) and
            MapSet.member?(assigns.cached_titles, {assigns.item[:type], assigns.item[:id]})
      )

    ~H"""
    <.card href={@href} class={["group block space-y-1", @watched? && "opacity-50"]}>
      <div
        class="relative aspect-[2/3] overflow-hidden rounded-box bg-base-300 shadow"
        data-peek={peek_key(@item)}
        data-peek-title={@item.title}
        data-peek-progress={@prog && progress_text(@prog, @item)}
        data-peek-resume={@item[:resume_at] && resume_title(@item)}
        data-peek-cached={@cached? && "true"}
        data-peek-due={@due && "Not out yet: #{due_text(@due)}"}
      >
        <img
          :if={@item.poster}
          src={@item.poster}
          alt={@item.title}
          loading="lazy"
          class={[
            "h-full w-full object-cover transition group-hover:scale-105",
            @watched? && "grayscale"
          ]}
        />
        <span
          :if={@item[:badge]}
          class="badge badge-primary badge-sm absolute right-1.5 top-1.5 shadow"
        >
          {@item[:badge]}
        </span>
        <%!-- Where you are in it, on the poster: episodes or seasons done, and for a film or
              an episode in progress the spot you stopped at. Everything else is on hover. --%>
        <div
          :if={@prog || @item[:resume_at]}
          class="absolute inset-x-0 bottom-0 bg-gradient-to-t from-black/90 via-black/55 to-transparent px-2 pb-1.5 pt-8 text-white"
        >
          <div :if={@prog} class="flex items-baseline gap-1 text-xs font-semibold leading-tight">
            <span>{elem(@prog, 0)}<span class="font-normal text-white/60"> / {elem(@prog, 1)}</span></span>
            <span class="text-[0.65rem] font-normal text-white/70">{elem(@prog, 2)}</span>
          </div>
          <div
            :if={@item[:resume_at]}
            class="whitespace-nowrap text-[0.65rem] leading-tight text-white/85"
          >
            ▶ {clock(@item.resume_at)}{if left(@item), do: " · #{left(@item)}"}
          </div>
          <div class="mt-1 h-[3px] w-full overflow-hidden rounded-full bg-white/25">
            <div class="h-full rounded-full bg-primary" style={"width: #{bar(@prog, @item)}%"}></div>
          </div>
        </div>
        <span
          :if={@compact && !@prog && !@item[:resume_at] && rating(@item)}
          class="absolute bottom-1.5 right-1.5 rounded-md bg-black/65 px-1.5 py-0.5 text-[0.65rem] font-medium leading-none text-white"
        >
          ★ {rating(@item)}
        </span>
        <span
          :if={@due}
          class={[
            "absolute right-1.5 flex h-[1.1rem] w-[1.1rem] items-center justify-center rounded-full bg-error/90 text-error-content shadow-sm",
            if(@item[:badge], do: "top-8", else: "top-1.5")
          ]}
          title={"Not out yet: #{due_text(@due)}"}
        >
          <.icon_clock />
        </span>
        <%!-- A small dot, not a label: the hover card and the title page say what it means. --%>
        <span
          :if={@cached?}
          class={[
            "absolute right-1.5 flex h-[1.1rem] w-[1.1rem] items-center justify-center rounded-full bg-success/90 text-[0.6rem] leading-none text-success-content shadow-sm",
            if(@item[:badge], do: "top-8", else: "top-1.5")
          ]}
          title="Sources cached: plays right away"
        >
          ⚡
        </span>
        <span
          :if={@watched?}
          class="absolute left-1.5 top-1.5 flex h-6 w-6 items-center justify-center rounded-full bg-success text-success-content shadow"
          title="Watched"
        >
          <svg viewBox="0 0 20 20" fill="currentColor" class="h-4 w-4" aria-hidden="true">
            <path
              fill-rule="evenodd"
              d="M16.7 5.3a1 1 0 0 1 0 1.4l-7.5 7.5a1 1 0 0 1-1.4 0L3.3 9.7a1 1 0 1 1 1.4-1.4l3.8 3.8 6.8-6.8a1 1 0 0 1 1.4 0Z"
              clip-rule="evenodd"
            />
          </svg>
        </span>
        <div
          :if={!@item.poster}
          class="flex h-full items-center justify-center p-2 text-center text-xs"
        >
          {@item.title}
        </div>
      </div>
      <div class="truncate text-sm font-medium" title={@item.title}>{@item.title}</div>
      <div :if={!@compact} class="text-xs text-base-content/60">
        {if @watched?, do: "Watched · ", else: ""}{subtitle(@item)}
      </div>
    </.card>
    """
  end

  attr :href, :any, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true

  defp card(%{href: nil} = assigns), do: ~H"<div class={@class}>{render_slot(@inner_block)}</div>"

  defp card(assigns),
    do: ~H"<.link navigate={@href} class={@class}>{render_slot(@inner_block)}</.link>"

  @doc "Where a poster leads: the title page (a franchise season entry opens on its season)."
  def href(%{id: id, type: type} = item)
      when is_integer(id) and type in ["movie", "tv", "anime"] do
    type = if type == "movie", do: "movie", else: "tv"

    case item do
      %{season: s} when is_integer(s) -> ~p"/title/#{type}/#{id}?#{[s: s]}"
      _ -> ~p"/title/#{type}/#{id}"
    end
  end

  def href(_), do: nil

  # "7/13 episodes" / "1/3 seasons watched" in the note laev writes → {7, 13, "episodes"}.
  defp progress_of(%{note: note}) when is_binary(note) do
    case Regex.run(~r/(\d+)\s*\/\s*(\d+)\s+(episodes|seasons)/, note) do
      [_, done, total, unit] -> {String.to_integer(done), String.to_integer(total), unit}
      _ -> nil
    end
  end

  defp progress_of(_item), do: nil

  defp progress_text({done, total, unit}, item) do
    base = "#{done} of #{total} #{unit} watched"

    case item do
      %{ep_done: d, ep_total: t} when unit == "seasons" -> base <> " · #{d} of #{t} episodes"
      _ -> base
    end
  end

  # The bar: the share of episodes (or seasons) watched, else how far into the film.
  # Seasons are a coarse measure (1 of 3 reads a third however far into the second you are), so
  # when the episode count is known the bar follows episodes while the number keeps saying
  # seasons.
  defp bar(_prog, %{ep_done: d, ep_total: t}) when is_integer(t) and t > 0,
    do: min(round(d * 100 / t), 100)

  defp bar({done, total, _}, _item) when total > 0, do: min(round(done * 100 / total), 100)

  defp bar(nil, %{resume_at: at, runtime: rt}) when is_integer(rt) and rt > 0,
    do: progress(%{resume_at: at, runtime: rt})

  defp bar(_prog, _item), do: 0

  defp due_text(%Date{} = d), do: Calendar.strftime(d, "%-d %b %Y")

  defp icon_clock(assigns) do
    ~H"""
    <svg viewBox="0 0 20 20" fill="currentColor" class="h-3 w-3" aria-hidden="true">
      <path
        fill-rule="evenodd"
        d="M10 18a8 8 0 1 0 0-16 8 8 0 0 0 0 16Zm.75-12.25a.75.75 0 0 0-1.5 0V10c0 .2.08.39.22.53l2.5 2.5a.75.75 0 1 0 1.06-1.06l-2.28-2.28V5.75Z"
        clip-rule="evenodd"
      />
    </svg>
    """
  end

  defp rating(%{vote: v}) when is_number(v) and v > 0, do: Float.round(v * 1.0, 1)
  defp rating(_item), do: nil

  defp peek_key(%{type: type, id: id}) when type in ["movie", "tv", "anime"] and is_integer(id),
    do: "#{if type == "movie", do: "movie", else: "tv"}/#{id}"

  defp peek_key(_item), do: nil

  @doc "Seconds as `59:39`, or `1:02:03` past an hour."
  def clock(secs) when is_integer(secs) do
    h = div(secs, 3600)
    m = div(rem(secs, 3600), 60)
    s = rem(secs, 60)
    pad = &(&1 |> Integer.to_string() |> String.pad_leading(2, "0"))
    if h > 0, do: "#{h}:#{pad.(m)}:#{pad.(s)}", else: "#{m}:#{pad.(s)}"
  end

  @doc "How much is left, when the runtime is known: `37 min left`."
  def left(%{resume_at: at, runtime: rt}) when is_integer(rt) and rt > at do
    mins = div(rt - at + 59, 60)
    if mins >= 60, do: "#{div(mins, 60)} h #{rem(mins, 60)} min left", else: "#{mins} min left"
  end

  def left(_item), do: nil

  defp progress(%{resume_at: at, runtime: rt}), do: min(round(at * 100 / rt), 100)

  defp resume_title(item),
    do:
      "Continue from #{clock(item.resume_at)}" <> if(left(item), do: " · #{left(item)}", else: "")

  @doc "The grey line under a poster — where you are in it, else when it came out."
  def subtitle(%{note: n}) when is_binary(n) and n != "",
    do: n |> String.trim() |> String.trim_leading("·") |> String.trim()

  def subtitle(%{season: s, episode: e}) when is_integer(s) and is_integer(e),
    do: "S#{s} · E#{e}"

  def subtitle(%{episode: e}) when is_integer(e), do: "Episode #{e}"

  def subtitle(%{year: y, vote: v}) when is_binary(y) and y != "" and is_number(v) and v > 0,
    do: "#{y} · ★#{Float.round(v * 1.0, 1)}"

  def subtitle(%{year: y}) when is_binary(y) and y != "", do: y
  def subtitle(%{type: "movie"}), do: "Film"
  def subtitle(%{type: "tv"}), do: "Series"
  def subtitle(_), do: ""
end
