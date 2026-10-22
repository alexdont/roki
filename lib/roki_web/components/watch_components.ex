defmodule RokiWeb.WatchComponents do
  @moduledoc """
  The pieces of the watching pages (sources, player): the Browser / External player switch, the
  list of releases, the external-player panel, the "starting the best source" pop-up. Shared by
  `SourcesLive` and `WatchLive`.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias Roki.Watch
  alias Roki.Watch.Resolver

  attr :mode, :atom, required: true

  def mode_switch(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2 text-sm">
      <span class="hidden text-base-content/60 sm:inline">Play in</span>
      <div class="join">
        <button
          phx-click="set_mode"
          phx-value-mode="browser"
          class={["btn btn-xs join-item sm:btn-sm", @mode == :browser && "btn-primary"]}
        >
          Browser
        </button>
        <button
          phx-click="set_mode"
          phx-value-mode="external"
          class={["btn btn-xs join-item sm:btn-sm", @mode == :external && "btn-primary"]}
        >
          External player
        </button>
      </div>
      <span :if={@mode == :external} class="hidden text-base-content/60 sm:inline">
        full quality, 4K included; nothing is converted on the server
      </span>
    </div>
    """
  end

  attr :at, :integer, required: true
  attr :busy, :boolean, default: false

  def cache_note(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2 text-sm text-base-content/70">
      <span class="badge badge-success badge-outline gap-1">⚡ cached sources</span>
      <span>found {ago(@at)}, nothing to check.</span>
      <button phx-click="retry" class="btn btn-xs" disabled={@busy}>Retry</button>
      <span class="text-base-content/50">looks for new ones</span>
    </div>
    """
  end

  defp ago(at) do
    secs = max(System.os_time(:second) - at, 0)

    cond do
      secs < 90 -> "just now"
      secs < 3600 -> "#{div(secs, 60)} min ago"
      true -> "#{div(secs, 3600)} h ago"
    end
  end

  attr :probe, :any, default: nil
  attr :text, :string, default: "Searching for releases…"

  @doc "A line with a bar: what is being checked and how far."
  def progress_line(assigns) do
    ~H"""
    <div class="space-y-2 rounded-box bg-base-200 p-4 text-sm">
      <div class="flex flex-wrap items-center gap-3">
        <span class="loading loading-spinner loading-sm"></span>
        <span>{if @probe, do: "Checking releases", else: @text}</span>
        <span :if={@probe} class="text-base-content/60">
          {@probe.done}/{@probe.total} checked · {@probe.ok} {if @probe.ok == 1,
            do: "plays",
            else: "play"}
        </span>
      </div>
      <progress
        class="progress progress-primary w-full"
        value={if @probe && @probe.total > 0, do: @probe.done}
        max={if @probe && @probe.total > 0, do: @probe.total}
      ></progress>
    </div>
    """
  end

  attr :probe, :any, default: nil
  attr :what, :string, default: nil

  @doc """
  The pop-up while the best source is being found and started on its own. Cancel, a click
  outside it, or Escape leaves the list to pick from.
  """
  def auto_start(assigns) do
    ~H"""
    <div class="fixed inset-0 z-[70] flex items-center justify-center bg-black/50 p-6" id="auto-start">
      <div
        class="w-full max-w-sm space-y-4 rounded-2xl bg-base-100 p-6 shadow-2xl"
        phx-click-away="cancel_auto"
        phx-window-keydown="cancel_auto"
        phx-key="escape"
      >
        <div>
          <h2 class="text-lg font-bold">Starting the best source</h2>
          <p class="mt-1 text-sm text-base-content/70">
            It's set up to start the best one by itself{if @what, do: " for #{@what}"}, as soon as it
            finds a good one.
          </p>
        </div>
        <div class="space-y-2">
          <progress
            class="progress progress-primary w-full"
            value={if @probe && @probe.total > 0, do: @probe.done}
            max={if @probe && @probe.total > 0, do: @probe.total}
          ></progress>
          <p class="text-xs text-base-content/60">
            {if @probe,
              do: "#{@probe.done}/#{@probe.total} checked · #{@probe.ok} play",
              else: "Searching…"}
          </p>
        </div>
        <button phx-click="cancel_auto" class="btn btn-block">Cancel — let me choose</button>
      </div>
    </div>
    """
  end

  attr :mode, :atom, default: :browser
  attr :playable, :list, required: true
  attr :rest, :list, required: true
  attr :current, :any, default: nil
  attr :busy, :boolean, default: false

  attr :limit, :string,
    default: nil,
    doc: "highest resolution to list (the browser's cap); nil lists everything"

  def sources(assigns) do
    entries =
      for {{source, _stream} = pair, i} <- Enum.with_index(assigns.playable),
          Laev.Sources.resolution_at_most?(source.resolution, assigns.limit),
          do: {pair, i}

    assigns =
      assign(assigns,
        entries: entries,
        hidden: length(assigns.playable) - length(entries)
      )

    ~H"""
    <section class="space-y-3">
      <h2 class="text-xl font-semibold">
        Releases
        <span class="text-sm font-normal text-base-content/60">{length(@entries)} playable</span>
      </h2>
      <p :if={@hidden > 0} class="text-sm text-base-content/60">
        {@hidden} above {Resolver.label(@limit)} {if @hidden == 1, do: "is", else: "are"} hidden — a
        browser can't play them well. Switch to External player to see them.
      </p>
      <p :if={@entries == []} class="alert alert-warning text-sm">
        Nothing at {Resolver.label(@limit)} or below was found. Switch to External player.
      </p>
      <ul :if={@entries != []} class="divide-y divide-base-300 rounded-box border border-base-300">
        <li :for={{{source, stream}, i} <- @entries} class="flex items-center gap-3 p-3">
          <div class="min-w-0 flex-1 space-y-1">
            <div class="truncate text-sm font-medium" title={source.name}>{source.name}</div>
            <div class="flex flex-wrap items-center gap-1.5 text-xs">
              <span :if={source.resolution} class="badge badge-sm badge-primary">
                {Resolver.label(source.resolution)}
              </span>
              <span class="badge badge-sm badge-ghost">{source.size_human}</span>
              <span class="badge badge-sm badge-ghost">{provider(stream)}</span>
              <span
                :if={Watch.heavy?(source)}
                class="badge badge-sm badge-warning"
                title="Not h264: re-encoded on the server, slower to start"
              >
                re-encoded
              </span>
              <span :if={source[:cached] == :library} class="badge badge-sm badge-success">
                in your library
              </span>
              <span :if={source[:codec]} class="badge badge-sm badge-ghost">{source.codec}</span>
              <span :if={langs(source, stream) != ""} class="text-base-content/60">
                🔊 {langs(source, stream)}
              </span>
              <span :if={subs(stream) != ""} class="text-base-content/60">💬 {subs(stream)}</span>
            </div>
          </div>
          <button phx-click="choose" phx-value-idx={i} class="btn btn-sm" disabled={@busy}>
            {cond do
              @current && elem(@current, 0).hash == source.hash -> "Selected"
              @mode == :external -> "Open"
              true -> "Play"
            end}
          </button>
          <button
            :if={@mode == :browser}
            phx-click="choose"
            phx-value-idx={i}
            phx-value-via="external"
            class="btn btn-sm btn-ghost"
            title="Open this release in your external player"
            disabled={@busy}
          >
            External
          </button>
        </li>
      </ul>
      <button :if={@rest != []} phx-click="more" class="btn btn-sm btn-ghost" disabled={@busy}>
        Load more — check {min(length(@rest), 8)} of {length(@rest)} unchecked
      </button>
    </section>
    """
  end

  defp provider(%{provider: :torbox}), do: "TorBox"
  defp provider(_), do: "Real-Debrid"

  defp langs(source, stream) do
    case stream do
      %{tracks: %{audio: [_ | _] = audio}} ->
        audio |> Enum.map(&Watch.language/1) |> Enum.join(" · ")

      _ ->
        source |> Map.get(:langs, []) |> Enum.map(&Watch.language/1) |> Enum.join(" · ")
    end
  end

  defp subs(%{tracks: %{subs: [_ | _] = subs}}),
    do: subs |> Enum.map(&Watch.language/1) |> Enum.take(4) |> Enum.join(" · ")

  defp subs(_), do: ""

  attr :external, :map, required: true
  attr :platform, :atom, required: true
  attr :title, :map, required: true
  attr :season, :any, default: nil
  attr :episode, :any, default: nil

  def external_panel(assigns) do
    url = assigns.external.url
    name = assigns.external.filename || assigns.title.title

    assigns =
      assign(assigns,
        url: url,
        links: external_links(url, name),
        m3u:
          "data:audio/x-mpegurl;charset=utf-8," <>
            URI.encode(
              "#EXTM3U\n#EXTINF:-1," <> name <> "\n" <> url <> "\n",
              &URI.char_unreserved?/1
            ),
        m3u_name: Path.rootname(name) <> ".m3u"
      )

    ~H"""
    <section
      id="external-panel"
      phx-mounted={JS.dispatch("roki:reveal")}
      class="space-y-3 rounded-box border border-base-300 p-4"
    >
      <div>
        <h2 class="text-lg font-semibold">
          Opening in {app_label(@external.app)}{now_playing(@title, @season, @episode)}
        </h2>
        <p class="break-all text-sm text-base-content/60">
          {@external.name}{if @external.resolution, do: " · #{Resolver.label(@external.resolution)}"}
        </p>
      </div>

      <div class="flex flex-wrap gap-2">
        <a :if={@external.launch} href={@external.launch} class="btn btn-primary">
          Open in {app_label(@external.app)}
        </a>
        <a href={@m3u} download={@m3u_name} class="btn">Download .m3u</a>
        <button
          type="button"
          class="btn"
          data-url={@url}
          onclick="navigator.clipboard.writeText(this.dataset.url).then(() => { this.textContent = 'Copied' })"
        >
          Copy link
        </button>
        <button phx-click="mark_watched" class="btn btn-ghost">Mark as watched</button>
      </div>

      <details class="text-sm">
        <summary class="cursor-pointer text-base-content/60">Other apps</summary>
        <div class="mt-2 flex flex-wrap gap-2">
          <a :if={@platform != :ios} href={@links.vlc_ios} class="btn btn-sm">VLC (iPhone/iPad)</a>
          <a :if={@platform != :android} href={@links.vlc_android} class="btn btn-sm">
            VLC (Android)
          </a>
          <a :if={@platform != :desktop} href={@links.vlc_desktop} class="btn btn-sm">
            VLC (desktop)
          </a>
          <a href={@links.infuse} class="btn btn-sm">Infuse</a>
          <a href={@links.mpv} class="btn btn-sm">mpv</a>
        </div>
      </details>

      <p class="text-sm text-base-content/60">
        <span :if={@external.resume_at > 0}>
          You were at {format_time(@external.resume_at)}. Seek there in your player.
        </span>
        Your player can't report progress back, so use “Mark as watched” when you finish.
        The link is private to your debrid account; don't share it.
      </p>
    </section>
    """
  end

  @doc "A suffix like '· S2E5' for an episode, nothing for a film."
  def now_playing(%{type: "tv"}, season, episode) when is_integer(season) and is_integer(episode),
    do: " · S#{season}E#{episode}"

  def now_playing(_, _, _), do: ""

  def app_label(app),
    do: Roki.Laev.web_setting_specs()["external_app"].labels[app] || "your player"

  @doc """
  Where the chosen app is opened on this device; `nil` for the .m3u download, which is a file the
  user opens themselves.
  """
  def launch_url("m3u", _platform, _url, _name), do: nil

  def launch_url(app, platform, url, name) do
    links = external_links(url, name)

    case {app, platform} do
      {"infuse", _} -> links.infuse
      {"mpv", _} -> links.mpv
      {_, :ios} -> links.vlc_ios
      {_, :android} -> links.vlc_android
      {_, _} -> links.vlc_desktop
    end
  end

  # `vlc://` is registered by VLC on iOS and macOS; Android takes an intent; mpv needs the
  # mpv-handler protocol. All carry the same direct link.
  defp external_links(url, name) do
    enc = URI.encode_www_form(url)
    %URI{host: host} = uri = URI.parse(url)
    rest = url |> String.replace_prefix("#{uri.scheme}:", "")

    %{
      vlc_ios: "vlc-x-callback://x-callback-url/stream?url=#{enc}",
      vlc_android:
        "intent:#{rest}#Intent;scheme=#{uri.scheme};package=org.videolan.vlc;type=video/*;S.title=#{URI.encode_www_form(name)};end",
      vlc_desktop: "vlc://#{url}",
      infuse: "infuse://x-callback-url/play?url=#{enc}",
      mpv: "mpv://#{Base.url_encode64(url)}",
      host: host
    }
  end

  def format_time(s) do
    s = trunc(s)
    h = div(s, 3600)
    m = div(rem(s, 3600), 60)
    sec = rem(s, 60)
    if h > 0, do: "#{h}:#{pad(m)}:#{pad(sec)}", else: "#{m}:#{pad(sec)}"
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
