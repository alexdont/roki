defmodule RokiWeb.WatchComponents do
  @moduledoc """
  The pieces of the watching pages (sources, player): the
  list of releases, the external-player panel, the "starting the best source" pop-up. Shared by
  `SourcesLive` and `WatchLive`.
  """
  use Phoenix.Component

  import RokiWeb.CoreComponents, only: [icon: 1]

  alias Phoenix.LiveView.JS
  alias Roki.Watch
  alias Roki.Watch.Resolver

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

  attr :checks, :list, default: []

  @doc """
  The releases being checked, one row each as they are tried: a spinner while it is asked, a green
  tick when it plays, grey with the reason when it does not. So there is always something to see.
  """
  def checks_list(assigns) do
    assigns =
      assign(assigns,
        good: Enum.count(assigns.checks, &(&1.state == :ok)),
        done: Enum.count(assigns.checks, &(&1.state != :checking))
      )

    ~H"""
    <div :if={@checks != []} class="space-y-1.5">
      <div class="flex items-center justify-between text-xs text-base-content/60">
        <span>Checking releases</span>
        <span>
          <span :if={@good > 0} class="font-semibold text-success">✓ {@good}</span>
          {@done}/{length(@checks)}
        </span>
      </div>
      <ul class="max-h-52 space-y-1 overflow-y-auto pr-0.5">
        <li
          :for={c <- @checks}
          class={[
            "flex items-center gap-2 rounded-lg px-2 py-1.5 text-sm transition-colors",
            c.state == :ok && "bg-success/15",
            c.state == :checking && "bg-base-200",
            match?({:bad, _}, c.state) && "opacity-45",
            match?({:later, _}, c.state) && "bg-base-200/60"
          ]}
        >
          <span class="flex h-5 w-5 shrink-0 items-center justify-center">
            <span :if={c.state == :checking} class="loading loading-spinner loading-xs"></span>
            <.icon :if={c.state == :ok} name="hero-check-circle-solid" class="h-5 w-5 text-success" />
            <.icon
              :if={match?({:bad, _}, c.state)}
              name="hero-x-circle"
              class="h-5 w-5 text-base-content/50"
            />
            <.icon
              :if={match?({:later, _}, c.state)}
              name="hero-clock"
              class="h-5 w-5 text-base-content/40"
            />
          </span>
          <span class={["min-w-0 flex-1 truncate", match?({:bad, _}, c.state) && "line-through"]}>
            {c.name}
          </span>
          <span class="shrink-0 text-xs text-base-content/60">
            {if match?({:bad, _}, c.state) or match?({:later, _}, c.state),
              do: elem(c.state, 1),
              else: c.resolution}
          </span>
        </li>
      </ul>
    </div>
    """
  end

  attr :name, :string, required: true

  @doc "The wait after a release is chosen: the video is being got ready, and then the page opens."
  def starting(assigns) do
    ~H"""
    <div class="fixed inset-0 z-[70] flex items-center justify-center bg-black/50 p-6" id="starting">
      <div class="w-full max-w-sm space-y-4 rounded-2xl bg-base-100 p-6 shadow-2xl">
        <div class="flex items-center gap-3">
          <span class="loading loading-spinner loading-md text-primary"></span>
          <h2 class="text-lg font-bold">Getting the video ready</h2>
        </div>
        <p class="break-words text-sm text-base-content/70">{@name}</p>
        <p class="text-xs text-base-content/50">The player opens as soon as it can play.</p>
      </div>
    </div>
    """
  end

  attr :probe, :any, default: nil
  attr :what, :string, default: nil
  attr :checks, :list, default: []

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
        <.checks_list checks={@checks} />
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
  attr :next, :any, default: nil
  attr :prev, :any, default: nil

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

      <%!-- After watching: one tap to the next episode (this one is marked watched), which opens
            in the same player by itself. --%>
      <button :if={@next} phx-click="next" class="btn btn-primary btn-lg w-full gap-2 sm:w-auto">
        Play next episode · {elem(@next, 2)} <.icon name="hero-forward" class="h-5 w-5" />
      </button>

      <div class="flex flex-wrap gap-2">
        <button :if={@prev} phx-click="previous" class="btn gap-1.5" title="The episode before">
          <.icon name="hero-backward" class="h-4 w-4" /> Previous · {elem(@prev, 2)}
        </button>
        <a :if={@external.launch} href={@external.launch} class={["btn", !@next && "btn-primary"]}>
          Open in {app_label(@external.app)}
        </a>
        <a
          href={@m3u}
          download={@m3u_name}
          class={["btn", !@next && !@external.launch && "btn-primary"]}
        >
          {if @external.launch, do: "Download .m3u", else: "Open in VLC (.m3u file)"}
        </a>
        <button
          :if={@platform in [:desktop, :mac]}
          type="button"
          class="btn"
          data-cmd={"vlc '" <> @url <> "'"}
          onclick="navigator.clipboard.writeText(this.dataset.cmd).then(() => { this.textContent = 'Copied' })"
          title="Paste into a terminal"
        >
          Copy VLC command
        </button>
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
          <a :if={@platform not in [:desktop, :mac]} href={@links.vlc_desktop} class="btn btn-sm">
            VLC (desktop)
          </a>
          <a href={@links.infuse} class="btn btn-sm">Infuse</a>
          <a href={@links.mpv} class="btn btn-sm">mpv</a>
        </div>
      </details>

      <p :if={!@external.launch and @platform == :desktop} class="text-sm text-base-content/60">
        Linux and Windows browsers can't open VLC from a link. The .m3u file opens in VLC when you
        open it (set VLC as the default for .m3u files once, and a click is enough); or paste the
        command into a terminal.
      </p>

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
  def now_playing(%{type: "tv"} = title, season, episode)
      when is_integer(season) and is_integer(episode),
      do: " · #{Map.get(title, :tag) || "S#{season}E#{episode}"}"

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
      {_, :mac} -> links.vlc_desktop
      # Linux and Windows do not register `vlc://` links: the click would do nothing. The .m3u
      # file is what they open.
      {_, _} -> nil
    end
  end

  # `vlc://` is registered by VLC on iOS and macOS only; Android takes an intent; mpv needs the
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
