defmodule RokiWeb.StudyLive do
  @moduledoc """
  `/study` — a player on the left and, on the right, every subtitle line: the live one
  highlighted, kept in view as the video plays, free to scroll, and a click on any line
  plays from there. For learning a language from what you watch. Desktop first: on a
  narrow screen the list sits under the video.

  This is the sidebar on its own, before the real watch flow exists: the video is a
  file from your computer, a direct URL, or the built-in demo, and the subtitles are an
  uploaded file (SubRip, ASS/SSA or WebVTT) or the demo. All the behaviour is in the
  `StudySidebar` hook (`assets/js/study/`); the server only turns an upload into WebVTT.
  """
  use RokiWeb, :live_view

  @max_bytes 5_000_000
  @extensions ~w(.srt .vtt .ass .ssa)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Study player")
     |> assign(:error, nil)
     # `accept: :any`: LiveView only takes extensions the MIME database knows, and it has
     # never heard of .srt/.ass. The extension is checked when the file arrives instead.
     |> allow_upload(:subtitles,
       accept: :any,
       max_entries: 1,
       max_file_size: @max_bytes,
       auto_upload: true,
       progress: &handle_progress/3
     )}
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  # The file is in: check it is a subtitle file, convert it, hand the WebVTT to the hook.
  # Nothing is kept.
  defp handle_progress(:subtitles, entry, socket) do
    cond do
      not entry.done? ->
        {:noreply, socket}

      String.downcase(Path.extname(entry.client_name)) not in @extensions ->
        {:noreply,
         socket
         |> cancel_upload(:subtitles, entry.ref)
         |> assign(
           :error,
           "#{entry.client_name} is not a subtitle file — use .srt, .vtt, .ass or .ssa."
         )}

      true ->
        content =
          consume_uploaded_entry(socket, entry, fn %{path: path} -> {:ok, File.read!(path)} end)

        vtt = Roki.Subtitles.to_vtt(entry.client_name, content)

        {:noreply,
         socket
         |> assign(:error, nil)
         |> push_event("study:subtitles", %{vtt: vtt, name: entry.client_name})}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      wide
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path="/study"
    >
      <div id="study" phx-hook="StudySidebar" data-video="study-video" class="space-y-4">
        <div>
          <h1 class="text-2xl font-bold tracking-tight sm:text-3xl">Study player</h1>
          <p class="text-sm text-base-content/60">
            Load a video and a subtitle file, or try the demo. Click a line to play from it.
          </p>
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <%!-- Where the video comes from — all in the browser, so LiveView leaves it be. --%>
          <div id="study-sources" phx-update="ignore" class="flex flex-wrap items-center gap-2">
            <button type="button" data-role="demo" class="btn btn-sm">Try the demo</button>
            <label class="btn btn-sm">
              Video file…
              <input type="file" data-role="video-file" accept="video/*,audio/*" class="hidden" />
            </label>
            <form data-role="video-url-form" class="join">
              <input
                name="url"
                placeholder="…or a direct video URL"
                class="input input-sm join-item w-56"
                autocomplete="off"
              />
              <button class="btn btn-sm join-item">Load</button>
            </form>
          </div>

          <.form
            for={%{}}
            id="subtitles-form"
            phx-change="validate"
            phx-submit="validate"
            class="flex items-center gap-2"
          >
            <label class="btn btn-sm">
              Subtitle file… <.live_file_input upload={@uploads.subtitles} class="hidden" />
            </label>
            <span :for={e <- @uploads.subtitles.entries} class="text-xs text-base-content/60">
              {e.client_name} {if e.progress < 100, do: "#{e.progress}%"}
            </span>
            <span :for={err <- upload_errors(@uploads.subtitles)} class="text-xs text-error">
              {error_text(err)}
            </span>
            <span :if={@error} class="text-xs text-error">{@error}</span>
          </.form>
        </div>

        <div class="grid gap-4 lg:grid-cols-[minmax(0,1fr)_24rem]">
          <div id="study-player" phx-update="ignore">
            <video
              id="study-video"
              controls
              playsinline
              class="aspect-video w-full rounded-box bg-black"
            ></video>
          </div>

          <%!-- The sidebar is exactly as tall as the video (the grid row is the video's height;
                the box is laid over it), so the two always line up. On a narrow screen it is a
                fixed height under the video. --%>
          <aside id="study-sidebar" phx-update="ignore" class="relative h-[28rem] lg:h-auto">
            <div class="flex h-full flex-col overflow-hidden rounded-box border border-base-300 bg-base-100 lg:absolute lg:inset-0">
              <header class="flex items-baseline justify-between gap-2 border-b border-base-300 px-3 py-2 text-sm">
                <span data-role="title" class="truncate font-medium">Subtitles</span>
                <span data-role="count" class="shrink-0 text-xs tabular-nums text-base-content/50"></span>
              </header>
              <div class="relative min-h-0 flex-1">
                <div data-role="list" class="absolute inset-0 overflow-y-auto p-1"></div>
                <p data-role="empty" class="p-4 text-sm text-base-content/50">
                  Load a subtitle file — or the demo — and its lines appear here.
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
    </Layouts.app>
    """
  end

  defp error_text(:too_large), do: "That file is over 5 MB."
  defp error_text(:too_many_files), do: "One subtitle file at a time."
  defp error_text(other), do: "Upload failed (#{inspect(other)})."
end
