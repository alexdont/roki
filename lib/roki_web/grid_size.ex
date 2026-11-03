defmodule RokiWeb.GridSize do
  @moduledoc """
  How big the posters are in a grid — small, medium or large (on a phone 3, 2 or 1 a row) — one
  choice for every poster grid on the site (search, lists, the shelf, Watched, a mood, a profile;
  Movies/Shows/Anime keep theirs in the same place). It is the device's: kept in the browser
  (`localStorage["roki:grid"]`, sent as the `grid` connect param, written back on the
  `roki:grid` event by app.js), so a phone and a laptop can differ.

  `on_mount(:default)` (the `:site` live session) assigns `@grid_size` (nil until chosen) and
  answers the switch's `grid_size` event on any page. A page draws its grid with
  `cols(@grid_size, default)` — its default being what it looked like before there was a choice —
  and the switch with `<.grid_switch size={@grid_size} default="s" />`.
  """
  use Phoenix.Component

  import Phoenix.LiveView,
    only: [attach_hook: 4, connected?: 1, get_connect_params: 1, push_event: 3]

  @sizes ~w(s m l)

  @cols %{
    "s" => "grid-cols-3 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-8",
    "m" => "grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6",
    "l" => "grid-cols-1 min-[420px]:grid-cols-2 md:grid-cols-3 lg:grid-cols-4"
  }

  def sizes, do: @sizes

  def on_mount(:default, _params, _session, socket) do
    stored =
      if connected?(socket), do: (get_connect_params(socket) || %{})["grid"], else: nil

    {:cont,
     socket
     |> Phoenix.Component.assign(:grid_size, if(stored in @sizes, do: stored))
     |> attach_hook(:grid_size, :handle_event, &event/3)}
  end

  defp event("grid_size", %{"size" => size}, socket) when size in @sizes do
    {:halt,
     socket
     |> Phoenix.Component.assign(:grid_size, size)
     |> push_event("roki:grid", %{size: size})}
  end

  defp event(_event, _params, socket), do: {:cont, socket}

  @doc "The grid's column classes for the chosen size, or the page's own default."
  def cols(size, default \\ "s"), do: @cols[current(size, default)]

  def current(size, default \\ "s"), do: if(size in @sizes, do: size, else: default)

  attr :size, :string, default: nil
  attr :default, :string, default: "s"
  attr :class, :any, default: nil

  attr :step_on_phone, :boolean,
    default: false,
    doc: "on a phone, one button that steps through the sizes (a crowded toolbar), as Movies has"

  @doc """
  Small / medium / large, as three buttons side by side (a phone included: they are small), or on
  a phone one button stepping through them where a toolbar has no room.
  """
  def grid_switch(assigns) do
    on = current(assigns.size, assigns.default)
    next = Enum.at(@sizes, rem(Enum.find_index(@sizes, &(&1 == on)) + 1, length(@sizes)))
    assigns = assign(assigns, on: on, next: next)

    ~H"""
    <button
      :if={@step_on_phone}
      type="button"
      phx-click="grid_size"
      phx-value-size={@next}
      title="Poster size"
      aria-label="Poster size"
      class={[
        "flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-base-200 text-base-content sm:hidden",
        @class
      ]}
    >
      <.size_icon size={@on} />
    </button>
    <div
      class={[
        "inline-flex shrink-0 rounded-full bg-base-200 p-0.5",
        @step_on_phone && "max-sm:hidden",
        @class
      ]}
      role="group"
      aria-label="Poster size"
    >
      <button
        :for={{size, label} <- [{"s", "Small"}, {"m", "Medium"}, {"l", "Large"}]}
        type="button"
        phx-click="grid_size"
        phx-value-size={size}
        title={"#{label} posters"}
        aria-label={"#{label} posters"}
        aria-pressed={to_string(@on == size)}
        class={[
          "flex h-8 w-9 items-center justify-center rounded-full transition",
          @on == size && "bg-base-100 text-base-content shadow-sm",
          @on != size && "text-base-content/60 hover:text-base-content"
        ]}
      >
        <.size_icon size={size} />
      </button>
    </div>
    """
  end

  attr :size, :string, required: true

  # Three, two or one squares: as many posters a row as that size gives a phone.
  defp size_icon(assigns) do
    ~H"""
    <span class="flex items-center gap-[2px]" aria-hidden="true">
      <span
        :for={_ <- 1..%{"s" => 3, "m" => 2, "l" => 1}[@size]}
        class={[
          "block rounded-[2px] bg-current",
          %{"s" => "h-3 w-[5px]", "m" => "h-3.5 w-[7px]", "l" => "h-4 w-[11px]"}[@size]
        ]}
      ></span>
    </span>
    """
  end
end
