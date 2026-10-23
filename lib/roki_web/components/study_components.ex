defmodule RokiWeb.StudyComponents do
  @moduledoc """
  The player: a `<video>` with the subtitles drawn over it (hover a word for what it means), a
  slim bar under it — **Subtitles** and **Settings** open menus, **Lines** shows the list of
  every line, plus theater and fullscreen — and the list itself: beside the picture on a wide
  screen (or under it in theater mode), a sheet that slides up on a phone. Driven by the
  `StudySidebar` hook (`assets/js/study/`).

  Everything inside `#study-ui` belongs to JavaScript (`phx-update="ignore"`): theater mode, the
  state of the list and which menu is open are attributes on it, kept in the browser. LiveView only
  changes `data-player` on the root, which the hook reads on mount and on every update:

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

      <div
        id="study-ui"
        phx-update="ignore"
        data-theater="false"
        data-panel="open"
        data-sheet="closed"
        class="study-ui"
      >
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
              <button
                type="button"
                data-role="replay"
                hidden
                class="study-replay btn btn-sm btn-circle"
                title="Replay this line"
                aria-label="Replay this line"
              >
                <.icon name="hero-arrow-path" class="h-5 w-5" />
              </button>
            </div>

            <div class="study-bar">
              <div class="study-bar-group">
                <button
                  type="button"
                  data-role="subs-btn"
                  class="btn btn-sm gap-1.5"
                  aria-haspopup="menu"
                >
                  <.icon name="hero-chat-bubble-bottom-center-text" class="h-4 w-4 shrink-0" />
                  <span data-role="subs-label" class="max-w-[9rem] truncate sm:max-w-[14rem]">Subtitles</span>
                  <.icon name="hero-chevron-down-micro" class="h-4 w-4 shrink-0 opacity-60" />
                </button>
                <button
                  type="button"
                  data-role="audio-btn"
                  hidden
                  class="btn btn-sm gap-1.5"
                  aria-haspopup="menu"
                  title="Audio track"
                >
                  <.icon name="hero-speaker-wave" class="h-4 w-4 shrink-0" />
                  <span data-role="audio-label" class="max-w-[7rem] truncate">Audio</span>
                </button>
                <button
                  type="button"
                  data-role="settings-btn"
                  class="btn btn-sm gap-1.5"
                  aria-haspopup="menu"
                  title="Timing, text size, study mode"
                >
                  <.icon name="hero-adjustments-horizontal" class="h-4 w-4" />
                  <span class="hidden sm:inline">Settings</span>
                </button>
              </div>
              <div class="study-bar-group">
                <button
                  type="button"
                  data-role="next-btn"
                  hidden
                  class="btn btn-sm btn-primary gap-1.5"
                  title="Play the next episode"
                >
                  <.icon name="hero-forward" class="h-4 w-4" />
                  <span>Next <span data-role="next-label" class="hidden sm:inline"></span></span>
                </button>
                <button
                  type="button"
                  data-role="lines-btn"
                  class="btn btn-sm gap-1.5"
                  aria-pressed="false"
                >
                  <.icon name="hero-queue-list" class="h-4 w-4" /> <span>Lines</span>
                </button>
                <button
                  type="button"
                  data-role="theater"
                  class="btn btn-sm btn-square study-wide-only"
                  aria-pressed="false"
                  title="Theater mode"
                  aria-label="Theater mode"
                >
                  <.icon name="hero-film" class="h-4 w-4" />
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

              <%!-- Which tracks are on, in order, and the languages to add. Built by the hook. --%>
              <div data-role="subs-menu" class="study-pop" role="menu" hidden>
                <div class="study-pop-head">
                  <span>Subtitles</span>
                  <button
                    type="button"
                    data-role="pop-close"
                    class="btn btn-xs btn-ghost btn-circle"
                    aria-label="Close"
                  >
                    <.icon name="hero-x-mark-micro" class="h-4 w-4" />
                  </button>
                </div>
                <div data-role="subs-list" class="study-pop-body"></div>
              </div>

              <div data-role="audio-menu" class="study-pop" role="menu" hidden>
                <div class="study-pop-head">
                  <span>Audio</span>
                  <button
                    type="button"
                    data-role="pop-close"
                    class="btn btn-xs btn-ghost btn-circle"
                    aria-label="Close"
                  >
                    <.icon name="hero-x-mark-micro" class="h-4 w-4" />
                  </button>
                </div>
                <div data-role="audio-list" class="study-pop-body"></div>
              </div>

              <div data-role="settings-menu" class="study-pop" role="menu" hidden>
                <div class="study-pop-head">
                  <span>Settings</span>
                  <button
                    type="button"
                    data-role="pop-close"
                    class="btn btn-xs btn-ghost btn-circle"
                    aria-label="Close"
                  >
                    <.icon name="hero-x-mark-micro" class="h-4 w-4" />
                  </button>
                </div>
                <div class="study-pop-body space-y-1">
                  <div class="study-setting">
                    <div>
                      <div class="font-medium">Subtitle timing</div>
                      <div class="text-xs text-base-content/60">
                        Earlier or later than the picture
                      </div>
                    </div>
                    <div class="join">
                      <button
                        type="button"
                        data-role="earlier"
                        class="btn btn-sm btn-square join-item"
                        aria-label="Earlier"
                      >
                        <.icon name="hero-minus-micro" class="h-4 w-4" />
                      </button>
                      <button
                        type="button"
                        data-role="offset"
                        class="btn btn-sm join-item w-16 px-1 tabular-nums"
                        title="Click to reset"
                      >
                        0.0s
                      </button>
                      <button
                        type="button"
                        data-role="later"
                        class="btn btn-sm btn-square join-item"
                        aria-label="Later"
                      >
                        <.icon name="hero-plus-micro" class="h-4 w-4" />
                      </button>
                    </div>
                  </div>

                  <div class="study-setting">
                    <div class="font-medium">Text size</div>
                    <div class="join">
                      <button
                        type="button"
                        data-role="smaller-text"
                        class="btn btn-sm join-item"
                        aria-label="Smaller text"
                      >A<span class="text-[0.6rem]">−</span></button>
                      <button
                        type="button"
                        data-role="scale"
                        class="btn btn-sm join-item w-16 px-1 tabular-nums"
                        title="Click to reset"
                      >
                        100%
                      </button>
                      <button
                        type="button"
                        data-role="bigger-text"
                        class="btn btn-sm join-item"
                        aria-label="Bigger text"
                      >A<span class="text-[0.6rem]">+</span></button>
                    </div>
                  </div>

                  <label class="study-setting cursor-pointer">
                    <div>
                      <div class="font-medium">Study mode</div>
                      <div class="text-xs text-base-content/60">Pause after every line</div>
                    </div>
                    <input type="checkbox" data-role="study" class="toggle toggle-primary" />
                  </label>

                  <label class="study-setting cursor-pointer">
                    <div>
                      <div class="font-medium">Peek</div>
                      <div class="text-xs text-base-content/60">
                        Hide translations until you click
                      </div>
                    </div>
                    <input type="checkbox" data-role="peek" class="toggle toggle-primary" />
                  </label>
                </div>
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
                  class="btn btn-xs btn-ghost btn-square study-wide-only"
                  title="Smaller"
                  aria-label="Make the list smaller"
                >
                  <.icon name="hero-arrows-pointing-in" class="h-4 w-4" />
                </button>
                <button
                  type="button"
                  data-role="collapse"
                  class="btn btn-xs btn-ghost btn-square"
                  title="Hide the list"
                  aria-label="Hide the list"
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

        <div data-role="backdrop" class="study-backdrop" hidden></div>
      </div>
    </div>
    """
  end
end
