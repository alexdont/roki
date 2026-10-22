defmodule RokiWeb.StudyComponents do
  @moduledoc """
  The player: a `<video>` with the subtitles drawn over it (hover a word for what it means), the
  subtitle tracks to pick from under it, and the subtitle box beside it — or under it in
  theater mode, where the player takes the width of the page. Driven by the `StudySidebar` hook
  (`assets/js/study/`).

  Everything inside `#study-ui` belongs to JavaScript (`phx-update="ignore"`): theater mode and
  the state of the box are attributes on it (`data-theater`, `data-panel`), kept in the browser.
  LiveView only changes `data-player` on the root, which the hook reads on mount and on every
  update:

      %{url:, hls: bool, resume: seconds, tracks: [%{label:, lang:, url:}], prefer: "fr", key: "…"}
  """
  use Phoenix.Component

  import RokiWeb.CoreComponents, only: [icon: 1]

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

      <div id="study-ui" phx-update="ignore" data-theater="false" data-panel="open" class="study-ui">
        <div class="study-layout">
          <div class="study-main">
            <div data-role="stage" class="study-stage">
              <video
                id="study-video"
                controls
                playsinline
                controlslist="nofullscreen"
                class="study-video"
              ></video>
              <div data-role="overlay" class="study-overlay"></div>
            </div>

            <div class="study-bar">
              <div data-role="tracks" class="study-tracks" role="group" aria-label="Subtitles"></div>
              <div class="study-tools">
                <div data-role="audio-wrap" hidden class="flex items-center gap-2 text-sm">
                  <span class="text-base-content/60">Audio</span>
                  <select data-role="audio" class="select select-sm select-bordered"></select>
                </div>
                <div class="join" role="group" aria-label="Subtitle timing">
                  <button
                    type="button"
                    data-role="earlier"
                    class="btn btn-sm btn-square join-item"
                    title="Subtitles half a second earlier"
                    aria-label="Subtitles earlier"
                  >
                    <.icon name="hero-minus-micro" class="h-4 w-4" />
                  </button>
                  <button
                    type="button"
                    data-role="offset"
                    class="btn btn-sm join-item w-16 px-1 tabular-nums"
                    title="Subtitle sync — click to reset"
                  >
                    0.0s
                  </button>
                  <button
                    type="button"
                    data-role="later"
                    class="btn btn-sm btn-square join-item"
                    title="Subtitles half a second later"
                    aria-label="Subtitles later"
                  >
                    <.icon name="hero-plus-micro" class="h-4 w-4" />
                  </button>
                </div>
                <div class="join" role="group" aria-label="Subtitle size">
                  <button
                    type="button"
                    data-role="smaller-text"
                    class="btn btn-sm join-item"
                    title="Smaller text"
                  >
                    A<span class="text-[0.6rem]">−</span>
                  </button>
                  <button
                    type="button"
                    data-role="bigger-text"
                    class="btn btn-sm join-item"
                    title="Bigger text"
                  >
                    A<span class="text-[0.6rem]">+</span>
                  </button>
                </div>
                <button
                  type="button"
                  data-role="study"
                  class="btn btn-sm gap-1.5"
                  aria-pressed="false"
                  title="Pause at the end of every line"
                >
                  <.icon name="hero-pause-circle" class="h-4 w-4" /> Study
                </button>
                <button
                  type="button"
                  data-role="replay"
                  hidden
                  class="btn btn-sm btn-square"
                  title="Replay this line"
                  aria-label="Replay this line"
                >
                  <.icon name="hero-arrow-path" class="h-4 w-4" />
                </button>
                <button
                  type="button"
                  data-role="peek"
                  class="btn btn-sm gap-1.5"
                  aria-pressed="false"
                  title="Hide the translation until you click it"
                >
                  <.icon name="hero-eye-slash" class="h-4 w-4" /> Peek
                </button>
                <button
                  type="button"
                  data-role="theater"
                  class="btn btn-sm gap-1.5"
                  aria-pressed="false"
                >
                  <.icon name="hero-film" class="h-4 w-4" /> Theater
                </button>
                <button
                  type="button"
                  data-role="fullscreen"
                  class="btn btn-sm btn-square"
                  title="Fullscreen, with the subtitles"
                  aria-label="Fullscreen"
                >
                  <.icon name="hero-arrows-pointing-out" class="h-4 w-4" />
                </button>
              </div>
            </div>
          </div>

          <aside class="study-side">
            <div class="study-box">
              <header class="study-head">
                <span data-role="title" class="min-w-0 flex-1 truncate font-medium">Subtitles</span>
                <span data-role="count" class="shrink-0 text-xs tabular-nums text-base-content/50"></span>
                <button
                  type="button"
                  data-role="compact"
                  class="btn btn-xs btn-ghost btn-square"
                  title="Smaller"
                  aria-label="Make the subtitle box smaller"
                >
                  <.icon name="hero-arrows-pointing-in" class="h-4 w-4" />
                </button>
                <button
                  type="button"
                  data-role="collapse"
                  class="btn btn-xs btn-ghost btn-square"
                  title="Hide the subtitle box"
                  aria-label="Hide or show the subtitle box"
                  aria-expanded="true"
                >
                  <.icon name="hero-chevron-up" class="h-4 w-4 study-chevron" />
                </button>
              </header>
              <div class="study-body">
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
    </div>
    """
  end
end
