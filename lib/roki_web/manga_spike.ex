defmodule RokiWeb.MangaSpike do
  @moduledoc """
  The Phase 1 spike of `dev_docs/manga-migration-plan.md`, and nothing more: a `Manhwa.Store`
  that serves five pages of a made-up series out of `priv/static/images/spike`, so the packaged
  reader can be mounted here and proved to render before any table, sidecar or scraper exists.

  Nothing is persisted — settings and progress are accepted and dropped. **Delete this module,
  its route and its `config :manhwa` block once the real store lands.**
  """
  @behaviour Manhwa.Store

  @pages 5
  @chapters ~w(1 2 3)
  # The reader always fetches a page through its own proxy, so the pages need an address the
  # server can `Req.get`. For the spike that is this server's own static files, over the loopback.
  @origin "http://localhost:4000"
  @prefix @origin <> "/images/spike/"

  @doc """
  The reader asks the host who is reading. On roki's `:browser` pipeline PhoenixKit assigns the
  *scope*, not the user — a reader route that only reads `:phoenix_kit_current_user` gets `nil`,
  and the reader then quietly falls back to its defaults (no saved state, paged mode). Both are
  read here, scope last.
  """
  def current_user(conn) do
    conn.assigns[:phoenix_kit_current_user] ||
      PhoenixKit.Users.Auth.Scope.user(conn.assigns[:phoenix_kit_current_scope])
  end

  @doc "Where the reader's own \"back to the series\" link goes. The spike has no series page."
  def series_url(_series), do: "/home"

  @impl true
  def valid_series?(["spike", _slug]), do: true
  def valid_series?(_), do: false

  @impl true
  def list_chapters(_user, _series), do: @chapters

  @impl true
  def fetch_pages(_user, _series, chapter, _opts) do
    if chapter in @chapters do
      {:ok, for(n <- 1..@pages, do: %{url: "#{@prefix}page-#{n}.png", width: 800, height: 1200})}
    else
      {:error, :no_such_chapter}
    end
  end

  @impl true
  def reader_state(_user, [_source, slug]) do
    # The slug picks the engine, so the spike can prove both: "strip-*" scrolls, anything else
    # is the paged/fresco reader.
    mode = if String.starts_with?(slug, "strip"), do: "scroll", else: "paged"

    %{
      title: "Spike · #{slug}",
      reading_mode: mode,
      reading_mode_desktop: mode,
      reading_mode_mobile: mode,
      reading_direction: "ltr",
      last_chapter: "1"
    }
  end

  @impl true
  def put_setting(_user, _series, _setting, _value, _device), do: :ok

  @impl true
  def save_progress(_user, _series, _chapter, _progress), do: :ok

  @doc "Only the spike's own pages may be proxied — nothing else, not even another local path."
  @impl true
  def image_request(url, _user) do
    if String.starts_with?(url, @prefix), do: {:ok, []}, else: :forbidden
  end
end
