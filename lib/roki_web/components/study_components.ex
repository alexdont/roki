defmodule RokiWeb.StudyComponents do
  @moduledoc """
  The player: a `<video>` on the left and the subtitle sidebar on the right (`StudySidebar`
  hook, `assets/js/study/`). Used by the title page, which plays real releases, and by
  `/study`, which plays whatever file you hand it.

  Everything inside the two `phx-update="ignore"` regions belongs to JavaScript; LiveView only
  changes `data-player` on the root, which the hook reads on mount and on every update:

      %{url:, hls: bool, resume: seconds, tracks: [%{label:, lang:, url:}], prefer: "fr", key: "…"}
  """
  use Phoenix.Component

  attr :player, :map,
    default: nil,
    doc: "what to play (see above); nil for a player waiting for a source"

  attr :progress?, :boolean,
    default: false,
    doc: "post the playhead back to the LiveView (`progress` events)"

  slot :controls,
    doc: "extra controls above the video (the /study page puts its file pickers here)"

  def study_player(assigns) do
    assigns = assign(assigns, :data, if(assigns.player, do: Jason.encode!(assigns.player)))

    ~H"""
    <div
      id="study"
      phx-hook="StudySidebar"
      data-video="study-video"
      data-player={@data}
      data-progress={to_string(@progress?)}
      class="space-y-3"
    >
      {render_slot(@controls)}

      <div class="grid gap-4 lg:grid-cols-[minmax(0,1fr)_24rem]">
        <div class="space-y-2">
          <div id="study-player" phx-update="ignore">
            <video
              id="study-video"
              controls
              playsinline
              class="aspect-video w-full rounded-box bg-black"
            ></video>
            <div data-role="audio-wrap" hidden class="mt-2 flex items-center gap-2 text-sm">
              <span class="text-base-content/60">Audio</span>
              <select data-role="audio" class="select select-xs select-bordered"></select>
            </div>
          </div>
        </div>

        <%!-- Exactly as tall as the video: the grid row is the video's height and the box is
              laid over it. On a narrow screen it is a fixed height under the video. --%>
        <aside id="study-sidebar" phx-update="ignore" class="relative h-[28rem] lg:h-auto">
          <div class="flex h-full flex-col overflow-hidden rounded-box border border-base-300 bg-base-100 lg:absolute lg:inset-0">
            <header class="flex items-center justify-between gap-2 border-b border-base-300 px-3 py-2 text-sm">
              <span data-role="title" class="min-w-0 flex-1 truncate font-medium">Subtitles</span>
              <select data-role="track" hidden class="select select-xs select-bordered max-w-40"></select>
              <span data-role="count" class="shrink-0 text-xs tabular-nums text-base-content/50"></span>
            </header>
            <div class="relative min-h-0 flex-1">
              <div data-role="list" class="absolute inset-0 overflow-y-auto p-1"></div>
              <p data-role="empty" class="p-4 text-sm text-base-content/50">
                Subtitle lines appear here once a track is loaded.
              </p>
              <button
                type="button"
                data-role="resume"
                hidden
                class="btn btn-xs btn-primary absolute bottom-3 left-1/2 -translate-x-1/2 shadow"
              >
                ↓ Back to current line
              </button>
            </div>
          </div>
        </aside>
      </div>
    </div>
    """
  end
end
