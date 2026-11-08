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

      %{url:, hls: bool, resume: seconds, start: seconds, tracks: [%{label:, lang:, url:}], prefer: "fr", key: "…"}

  `start` is where the stream begins in the film (a conversion begun where the viewer left
  off): the player counts from it, and asks for the film from further back (`seek_back`) when
  the viewer seeks before it.
  """
  use Phoenix.Component

  import RokiWeb.CoreComponents, only: [icon: 1]

  attr :player, :map,
    default: nil,
    doc: "what to play (see above); nil for a player waiting for a source"

  attr :progress?, :boolean,
    default: false,
    doc: "post the playhead back to the LiveView (`progress` events)"

  attr :immersive?, :boolean,
    default: false,
    doc:
      "the watch page: the player fills the screen, with its own bar (timeline, menus) at the bottom"

  attr :study?, :boolean,
    default: false,
    doc: "a study session: the list of lines starts open (a plain watch starts without it)"

  attr :label, :string, default: nil, doc: "what is playing, in the bar (immersive)"

  attr :look, :string,
    default: "classic",
    doc:
      "the bar's look in the watch player: \"sleek\" or \"classic\" (the account's `player_look`)"

  attr :episodes, :list,
    default: [],
    doc: "the season's episodes, `%{number:, name:, aired?:}`, for the episode menu (immersive)"

  attr :current, :integer, default: nil, doc: "the episode that is playing"

  attr :seasons, :list,
    default: [],
    doc:
      "the title's seasons, `%{number:, name:, episodes:}`, for the season row of the episode menu"

  attr :season, :integer, default: nil, doc: "the season that is playing"
  attr :home, :string, default: "/", doc: "where closing goes when there is no page behind"

  attr :sources, :string,
    default: nil,
    doc: "the sources page, for a \"Change source\" button in the bar"

  slot :controls,
    doc: "extra controls above the video (the /study page puts its file pickers here)"

  def study_player(assigns) do
    assigns =
      assign(assigns,
        data: if(assigns.player, do: Jason.encode!(assigns.player)),
        eps_json:
          Jason.encode!(
            for e <- assigns.episodes,
                do: %{n: e.number, name: e.name, ok: e.aired?, now: e.number == assigns.current}
          ),
        seasons_json:
          Jason.encode!(
            for s <- assigns.seasons, do: %{n: s.number, name: s.name, count: s[:episodes] || 0}
          )
      )

    ~H"""
    <div
      id="study"
      phx-hook="StudySidebar"
      data-video="study-video"
      data-player={@data}
      data-progress={to_string(@progress?)}
      data-immersive={to_string(@immersive?)}
      data-look={@look}
      data-study={to_string(@study?)}
      data-episodes={@eps_json}
      data-seasons={@seasons_json}
      data-season={@season}
      data-home={@home}
      class={if @immersive?, do: "study-immersive", else: "space-y-3"}
    >
      {render_slot(@controls)}

      <div
        id="study-ui"
        phx-update="ignore"
        data-theater="false"
        data-panel={if @immersive? and !@study?, do: "closed", else: "open"}
        data-sheet="closed"
        class="study-ui"
      >
        <div class="study-layout">
          <div class="study-main">
            <div data-role="stage" class="study-stage">
              <video
                id="study-video"
                controls={!@immersive?}
                playsinline
                controlslist="nofullscreen"
                x-webkit-airplay="allow"
                class="study-video"
              ></video>
              <div :if={@immersive?} class="study-close">
                <button
                  type="button"
                  data-role="close"
                  class="btn btn-sm btn-square"
                  title="Close the player"
                  aria-label="Close the player"
                >
                  <.icon name="hero-x-mark" class="h-5 w-5" />
                </button>
              </div>
              <div data-role="overlay" class="study-overlay"></div>
              <%!-- While the picture is on a TV through AirPlay (Safari), see study/airplay.js. --%>
              <div data-role="airplay-note" class="study-airplay-note" hidden aria-live="polite">
                <svg
                  class="h-10 w-10"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="1.8"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  aria-hidden="true"
                >
                  <path d="M5 17H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2h-1" />
                  <path d="M12 15l5 6H7l5-6z" />
                </svg>
                <span data-role="airplay-title">Playing on AirPlay</span>
                <small data-role="airplay-sub">The AirPlay button brings it back here.</small>
              </div>
              <button
                :if={@immersive?}
                type="button"
                data-role="skip"
                hidden
                class="study-skip btn"
              >
                <span data-role="skip-label">Skip intro</span>
                <.icon name="hero-forward" class="h-4 w-4" />
              </button>
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
              <%!-- A prompt for an AI chat that explains this line: word by word, the grammar, what is
                    slang or formal, what is an idiom (never translated literally), and the meaning.
                    Beside the replay button, in study mode; the card for a word has its own. --%>
              <button
                type="button"
                data-role="copy-line"
                hidden
                class="study-copyline btn btn-sm btn-circle"
                title="Copy a prompt that explains this line (for an AI chat)"
                aria-label="Copy a prompt that explains this line"
              >
                <span data-copy-idle><.icon name="hero-clipboard-document" class="h-5 w-5" /></span>
                <span data-copy-done hidden><.icon name="hero-check" class="h-5 w-5 text-success" /></span>
              </button>
            </div>

            <div :if={@immersive?} class="study-controls">
              <div class="study-timeline">
                <span data-role="cur" class="study-clock">0:00</span>
                <input
                  type="range"
                  data-role="seek"
                  min="0"
                  max="1000"
                  value="0"
                  step="1"
                  class="study-range study-seek"
                  aria-label="Seek"
                />
                <span data-role="dur" class="study-clock">0:00</span>
              </div>

              <div class="study-bar2">
                <div class="study-bar-group">
                  <button
                    type="button"
                    data-role="play"
                    class="btn btn-sm btn-square"
                    aria-label="Play or pause"
                  >
                    <span data-icon="play"><.icon name="hero-play-solid" class="h-5 w-5" /></span>
                    <span data-icon="pause" class="hidden">
                      <.icon name="hero-pause-solid" class="h-5 w-5" />
                    </span>
                  </button>
                  <button
                    type="button"
                    data-role="mute"
                    class="btn btn-sm btn-square"
                    aria-label="Mute"
                  >
                    <span data-icon="on"><.icon name="hero-speaker-wave" class="h-5 w-5" /></span>
                    <span data-icon="off" class="hidden">
                      <.icon name="hero-speaker-x-mark" class="h-5 w-5" />
                    </span>
                  </button>
                  <input
                    type="range"
                    data-role="volume"
                    min="0"
                    max="1"
                    step="0.05"
                    value="1"
                    class="study-range study-volume"
                    aria-label="Volume"
                  />
                  <button
                    type="button"
                    data-role="ep-btn"
                    class="btn btn-sm gap-1.5"
                    aria-haspopup="menu"
                    title="Episodes"
                  >
                    <span class="study-ep-label">{@label}</span>
                    <.icon :if={@episodes != []} name="hero-queue-list" class="h-4 w-4 shrink-0" />
                  </button>
                  <button
                    type="button"
                    data-role="prev-btn"
                    hidden
                    class="btn btn-sm btn-square"
                    title="Play the previous episode"
                    aria-label="Previous episode"
                  >
                    <.icon name="hero-backward" class="h-4 w-4" />
                  </button>
                  <button
                    type="button"
                    data-role="next-btn"
                    hidden
                    class="btn btn-sm gap-1.5"
                    title="Play the next episode"
                    aria-label="Next episode"
                  >
                    <span class="hidden sm:inline">Next <span data-role="next-label"></span></span>
                    <.icon name="hero-forward" class="h-4 w-4" />
                  </button>
                </div>
                <div class="study-bar-group">
                  <%!-- Study mode's line tools (shown only while it is on): back a line, replay this one, on
                        a line, and the pause toggle (pause after every line). Keys , . and / the same. --%>
                  <div class="study-lines" role="group" aria-label="Lines" hidden>
                    <button
                      type="button"
                      data-role="line-prev"
                      class="btn btn-sm btn-circle"
                      title="Previous line ( , )"
                      aria-label="Previous line"
                    >
                      <.icon name="hero-chevron-left" class="h-5 w-5" />
                    </button>
                    <button
                      type="button"
                      data-role="line-replay"
                      class="btn btn-sm btn-circle"
                      title="Replay this line ( / )"
                      aria-label="Replay this line"
                    >
                      <.icon name="hero-arrow-path" class="h-5 w-5" />
                    </button>
                    <button
                      type="button"
                      data-role="line-next"
                      class="btn btn-sm btn-circle"
                      title="Next line ( . )"
                      aria-label="Next line"
                    >
                      <.icon name="hero-chevron-right" class="h-5 w-5" />
                    </button>
                    <button
                      type="button"
                      data-role="study-toggle"
                      class="btn btn-sm btn-circle"
                      title="Pause after every line"
                      aria-label="Pause after every line"
                      aria-pressed="false"
                    >
                      <.icon name="hero-pause" class="h-5 w-5" />
                    </button>
                  </div>
                  <.link
                    :if={@sources}
                    navigate={@sources}
                    class="btn btn-sm gap-1.5"
                    title="Change source"
                  >
                    <.icon name="hero-arrows-right-left" class="h-4 w-4 shrink-0" />
                    <span class="hidden sm:inline">Change source</span>
                  </.link>
                  <button
                    type="button"
                    data-role="settings-btn"
                    class="btn btn-sm btn-square"
                    aria-haspopup="menu"
                    title="Timing, text size, study mode"
                    aria-label="Settings"
                  >
                    <.icon name="hero-cog-6-tooth" class="h-5 w-5" />
                  </button>
                  <button
                    type="button"
                    data-role="audio-btn"
                    class="btn btn-sm gap-1.5"
                    aria-haspopup="menu"
                    title="Audio"
                  >
                    <svg
                      class="h-4 w-4 shrink-0"
                      viewBox="0 0 24 24"
                      fill="none"
                      stroke="currentColor"
                      stroke-width="2"
                      stroke-linecap="round"
                      aria-hidden="true"
                    >
                      <path d="M12 4v16M8 8v8M4 10.5v3M16 7v10M20 10v4" />
                    </svg>
                    <span data-role="audio-label" class="font-semibold">Audio</span>
                  </button>
                  <button
                    type="button"
                    data-role="subs-btn"
                    class="btn btn-sm gap-1.5"
                    aria-haspopup="menu"
                    title="Subtitles"
                  >
                    <svg
                      class="h-4 w-4 shrink-0"
                      viewBox="0 0 24 24"
                      fill="none"
                      stroke="currentColor"
                      stroke-width="1.8"
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      aria-hidden="true"
                    >
                      <rect x="2.5" y="5" width="19" height="14" rx="3" />
                      <path d="M10.4 9.9A2.4 2.4 0 1 0 10.4 14.1M17.9 9.9A2.4 2.4 0 1 0 17.9 14.1" />
                    </svg>
                    <span data-role="subs-label" class="max-w-[9rem] truncate">Subtitles</span>
                  </button>
                  <button
                    type="button"
                    data-role="lines-btn"
                    class="btn btn-sm gap-1.5"
                    title="Lines"
                    aria-pressed="false"
                  >
                    <.icon name="hero-queue-list" class="h-4 w-4" />
                    <span class="hidden sm:inline">Lines</span>
                  </button>
                  <button
                    type="button"
                    data-role="airplay"
                    hidden
                    class="btn btn-sm btn-square"
                    title="AirPlay"
                    aria-label="AirPlay"
                    aria-pressed="false"
                  >
                    <svg
                      class="h-5 w-5"
                      viewBox="0 0 24 24"
                      fill="none"
                      stroke="currentColor"
                      stroke-width="1.8"
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      aria-hidden="true"
                    >
                      <path d="M5 17H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2h-1" />
                      <path d="M12 15l5 6H7l5-6z" />
                    </svg>
                  </button>
                  <button
                    type="button"
                    data-role="fullscreen"
                    class="btn btn-sm btn-square"
                    title="Fullscreen, with the subtitles"
                    aria-label="Fullscreen"
                  >
                    <.icon name="hero-arrows-pointing-out" class="h-5 w-5" />
                  </button>
                </div>

                <.menus />

                <div data-role="ep-menu" class="study-pop" role="menu" hidden>
                  <%!-- Previous and Next live here too: on a phone the bar has no room for them. --%>
                  <div class="study-pop-head gap-2">
                    <button
                      type="button"
                      data-role="ep-prev"
                      hidden
                      class="btn btn-xs gap-1"
                      title="Play the previous episode"
                    >
                      <.icon name="hero-backward" class="h-3.5 w-3.5" /> Prev
                    </button>
                    <span class="min-w-0 flex-1 truncate">Episodes</span>
                    <button
                      type="button"
                      data-role="ep-next"
                      hidden
                      class="btn btn-xs gap-1"
                      title="Play the next episode"
                    >
                      Next <.icon name="hero-forward" class="h-3.5 w-3.5" />
                    </button>
                    <button
                      type="button"
                      data-role="pop-close"
                      class="btn btn-xs btn-ghost btn-circle"
                      aria-label="Close"
                    >
                      <.icon name="hero-x-mark-micro" class="h-4 w-4" />
                    </button>
                  </div>
                  <div data-role="ep-list" class="study-pop-body"></div>
                </div>
              </div>
            </div>

            <div :if={!@immersive?} class="study-bar">
              <div class="study-bar-group">
                <button
                  type="button"
                  data-role="subs-btn"
                  class="btn btn-sm gap-1.5"
                  aria-haspopup="menu"
                >
                  <svg
                    class="h-4 w-4 shrink-0"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="1.8"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    aria-hidden="true"
                  >
                    <rect x="2.5" y="5" width="19" height="14" rx="3" />
                    <path d="M10.4 9.9A2.4 2.4 0 1 0 10.4 14.1M17.9 9.9A2.4 2.4 0 1 0 17.9 14.1" />
                  </svg>
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
                  <svg
                    class="h-4 w-4 shrink-0"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="2"
                    stroke-linecap="round"
                    aria-hidden="true"
                  >
                    <path d="M12 4v16M8 8v8M4 10.5v3M16 7v10M20 10v4" />
                  </svg>
                  <span data-role="audio-label" class="font-semibold">AUDIO</span>
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
                  data-role="prev-btn"
                  hidden
                  class="btn btn-sm btn-square"
                  title="Play the previous episode"
                  aria-label="Previous episode"
                >
                  <.icon name="hero-backward" class="h-4 w-4" />
                </button>
                <button
                  type="button"
                  data-role="next-btn"
                  hidden
                  class="btn btn-sm btn-square sm:w-auto sm:gap-1.5 sm:px-3"
                  title="Play the next episode"
                  aria-label="Next episode"
                >
                  <.icon name="hero-forward" class="h-4 w-4" />
                  <span class="hidden sm:inline">Next <span data-role="next-label"></span></span>
                </button>
                <button
                  type="button"
                  data-role="lines-btn"
                  class="btn btn-sm gap-1.5"
                  aria-pressed="false"
                >
                  <.icon name="hero-queue-list" class="h-4 w-4" />
                  <span class="hidden sm:inline">Lines</span>
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
                  :if={!@immersive?}
                  type="button"
                  data-role="airplay"
                  hidden
                  class="btn btn-sm btn-square"
                  title="AirPlay"
                  aria-label="AirPlay"
                  aria-pressed="false"
                >
                  <svg
                    class="h-4 w-4"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="1.8"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    aria-hidden="true"
                  >
                    <path d="M5 17H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2h-1" />
                    <path d="M12 15l5 6H7l5-6z" />
                  </svg>
                </button>
                <button
                  :if={!@immersive?}
                  type="button"
                  data-role="fullscreen"
                  class="btn btn-sm btn-square"
                  title="Fullscreen, with the subtitles"
                  aria-label="Fullscreen"
                >
                  <.icon name="hero-arrows-pointing-out" class="h-4 w-4" />
                </button>
              </div>

              <.menus />
            </div>
          </div>

          <aside class="study-side">
            <div class="study-box">
              <header class="study-head">
                <button
                  type="button"
                  data-role="lines-close"
                  class="btn btn-xs btn-ghost btn-square"
                  title="Close the list"
                  aria-label="Close the list"
                >
                  <.icon name="hero-x-mark" class="h-4 w-4" />
                </button>
                <span data-role="title" class="min-w-0 flex-1 truncate font-medium">Subtitles</span>
                <span data-role="count" class="shrink-0 text-xs tabular-nums text-base-content/50"></span>
                <button
                  type="button"
                  data-role="study-quick"
                  class="btn btn-xs rounded-full"
                  title="Study mode: pause after every line"
                  aria-pressed="false"
                >
                  Study
                </button>
                <button
                  type="button"
                  data-role="compact"
                  class="btn btn-xs btn-ghost btn-square study-wide-only"
                  title="Smaller"
                  aria-label="Make the list smaller"
                >
                  <.icon name="hero-arrows-pointing-in" class="study-shrink h-4 w-4" />
                  <.icon name="hero-arrows-pointing-out" class="study-grow h-4 w-4" />
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

  # The three menus the buttons of the bar open (subtitles, audio, settings), built by the hook.
  defp menus(assigns) do
    ~H"""
    <%!-- Which tracks are on, in order, and the languages to add. Built by the hook. --%>
    <div data-role="subs-menu" class="study-pop" role="menu" hidden>
      <div class="study-pop-head">
        <span>Subtitles</span>
        <button type="button" data-role="subs-off" class="btn btn-xs btn-ghost ml-auto mr-1">
          Turn off
        </button>
        <%!-- The sleek look's discreet way to the subtitle services (its footer link is hidden). --%>
        <a
          href="/account/services#connections"
          target="_blank"
          rel="noopener"
          class="study-svc-mini btn btn-xs btn-ghost btn-circle"
          title="Add subtitles from OpenSubtitles or Jimaku"
          aria-label="Subtitle services"
        >
          <.icon name="hero-plus-micro" class="h-4 w-4" />
        </a>
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
      <%!-- OpenSubtitles: the files it has for what is playing, listed on request. Built by the hook. --%>
      <div data-role="os-box" hidden class="shrink-0 space-y-2 border-t border-base-300 p-2"></div>
      <%!-- Always last: the release may lack the language wanted, and OpenSubtitles / Jimaku
              are keys the user adds in Settings. Opens in a new tab so playback goes on. --%>
      <a
        href="/account/services#connections"
        target="_blank"
        rel="noopener"
        class="study-svc-foot btn btn-sm btn-ghost mx-2 mb-2 mt-1 justify-start gap-1.5 text-base-content/70"
      >
        <.icon name="hero-plus-micro" class="h-4 w-4" /> Subtitle services
        <span class="text-xs opacity-60">OpenSubtitles, Jimaku</span>
      </a>
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
        <div class="study-setting flex-wrap">
          <div>
            <div class="font-medium">Subtitle timing</div>
            <div class="text-xs text-base-content/60">
              Earlier or later than the picture — click the number to type one
            </div>
          </div>
          <div class="join mx-auto">
            <button
              type="button"
              data-role="nudge"
              data-step="-0.5"
              class="btn btn-sm join-item px-2 tabular-nums"
              aria-label="0.5 seconds earlier"
            >−0.5</button>
            <button
              type="button"
              data-role="nudge"
              data-step="-0.25"
              class="btn btn-sm join-item px-2 tabular-nums"
              aria-label="0.25 seconds earlier"
            >−0.25</button>
            <button
              type="button"
              data-role="offset"
              class="btn btn-sm join-item w-20 px-1 tabular-nums"
              title="Click to type an exact number of seconds"
            >
              0.0s
            </button>
            <input
              type="text"
              inputmode="decimal"
              data-role="offset-input"
              hidden
              aria-label="Subtitle timing in seconds"
              class="input input-sm join-item w-20 px-1 text-center tabular-nums"
            />
            <button
              type="button"
              data-role="nudge"
              data-step="0.25"
              class="btn btn-sm join-item px-2 tabular-nums"
              aria-label="0.25 seconds later"
            >+0.25</button>
            <button
              type="button"
              data-role="nudge"
              data-step="0.5"
              class="btn btn-sm join-item px-2 tabular-nums"
              aria-label="0.5 seconds later"
            >+0.5</button>
          </div>
          <button
            type="button"
            data-role="offset-reset"
            hidden
            class="btn btn-xs btn-ghost w-full text-base-content/60"
          >
            Reset to 0
          </button>
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

        <div class="study-setting flex-wrap">
          <div class="font-medium">Subtitle look</div>
          <button
            type="button"
            data-role="cap-reset"
            class="btn btn-xs btn-ghost text-base-content/60"
          >
            Reset
          </button>
          <div class="flex w-full flex-wrap items-center gap-1.5">
            <button
              :for={c <- ~w(#ffffff #ffe14d #67e8f9 #86efac #f9a8d4 #fdba74)}
              type="button"
              data-role="cap-swatch"
              data-color={c}
              class="study-swatch"
              style={"background: #{c}"}
              aria-label={"Text colour #{c}"}
            ></button>
            <input
              type="color"
              data-role="cap-color"
              value="#ffffff"
              class="study-swatch-input"
              aria-label="Pick a text colour"
              title="Any colour"
            />
          </div>
          <label class="flex w-full items-center gap-3 text-sm">
            <span class="w-24 shrink-0">Text opacity</span>
            <input
              type="range"
              data-role="cap-text"
              min="20"
              max="100"
              step="5"
              value="100"
              class="range range-xs flex-1"
            />
            <span data-role="cap-text-out" class="w-10 text-right tabular-nums">100%</span>
          </label>
          <label class="flex w-full items-center gap-3 text-sm">
            <span class="w-24 shrink-0">Translation size</span>
            <input
              type="range"
              data-role="cap-trans"
              min="40"
              max="120"
              step="5"
              value="65"
              class="range range-xs flex-1"
            />
            <span data-role="cap-trans-out" class="w-10 text-right tabular-nums">65%</span>
          </label>
          <label class="flex w-full items-center gap-3 text-sm">
            <span class="w-24 shrink-0">Background</span>
            <input
              type="range"
              data-role="cap-bg"
              min="0"
              max="100"
              step="5"
              value="66"
              class="range range-xs flex-1"
            />
            <span data-role="cap-bg-out" class="w-10 text-right tabular-nums">66%</span>
          </label>
          <div class="flex w-full items-center gap-3 text-sm">
            <span class="w-24 shrink-0">Edge</span>
            <div class="join">
              <button type="button" data-role="cap-edge" data-edge="none" class="btn btn-sm join-item">
                None
              </button>
              <button
                type="button"
                data-role="cap-edge"
                data-edge="shadow"
                class="btn btn-sm join-item"
              >
                Shadow
              </button>
              <button
                type="button"
                data-role="cap-edge"
                data-edge="outline"
                class="btn btn-sm join-item"
              >
                Outline
              </button>
            </div>
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

        <label class="study-setting cursor-pointer">
          <div>
            <div class="font-medium">Dialogue on timeline</div>
            <div class="text-xs text-base-content/60">
              Marks where people talk along the bar
            </div>
          </div>
          <input type="checkbox" data-role="talk" class="toggle toggle-primary" />
        </label>

        <label class="study-setting cursor-pointer">
          <div>
            <div class="font-medium">Skip intro &amp; credits</div>
            <div class="text-xs text-base-content/60">
              A button to skip openings and credits
            </div>
          </div>
          <input type="checkbox" data-role="skip-setting" class="toggle toggle-primary" />
        </label>
      </div>
    </div>
    """
  end
end
