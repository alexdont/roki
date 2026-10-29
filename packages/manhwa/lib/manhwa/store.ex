defmodule Manhwa.Store do
  @moduledoc """
  The persistence contract between the reader and the host application.

  The reader owns *how it reads* — page/scroll engines, settings UI,
  progress ticking, chapter navigation. The host owns *what is read
  and where state lives*: where chapter lists and page URLs come from,
  and which table stores per-series reader state. This behaviour is
  that seam.

  Configure your implementation:

      config :manhwa, store: MyApp.ReaderStore

  ## Series identity

  A series is an opaque list of path segments, taken verbatim from the
  reader URL. With `series_segments: 2` in the router macro a URL like
  `/reader/manga/mangadex/one-piece/1057` yields
  `series = ["mangadex", "one-piece"]`; with 1 segment it's a single
  slug. The reader never interprets the segments — your store does.

  ## Users

  `user` is whatever your `:current_user` config function returns for
  the conn — the reader threads it through untouched (it may be `nil`
  for anonymous readers if your pipeline allows them).

  ## Reader state

  `c:reader_state/2` returns a map (or any struct — string keys are not
  supported) with any subset of these keys; missing keys fall back to
  reader defaults:

    * `:title` — display title for the series
    * `:reading_mode` / `:reading_mode_mobile` / `:reading_mode_desktop`
      — `"paged" | "double_page" | "scroll"`; per-device slots win over
      the generic one
    * `:reading_direction` — `"rtl" | "ltr"`
    * `:reading_rotation` — `0 | 90 | 180 | 270`
    * `:smart_crop` — boolean
    * `:comments_visible` — boolean
    * `:tap_zone_preset` / `:tap_zone_preset_mobile` / `:tap_zone_preset_desktop`
    * `:last_chapter` / `:last_page` / `:last_page_fraction` — resume state

  ## Settings

  `c:put_setting/5` receives one of the setting atoms
  `:reading_mode | :reading_direction | :reading_rotation | :smart_crop |
  :comments_visible | :tap_zone_preset` with an already-validated value,
  plus a device slot (`"mobile" | "desktop" | "all" | nil`) for the
  per-device settings (`:reading_mode`, `:tap_zone_preset`).
  """

  @type user :: term
  @type series :: [String.t()]
  @type chapter :: String.t()
  @type page :: %{
          required(:url) => String.t(),
          optional(:width) => pos_integer | nil,
          optional(:height) => pos_integer | nil
        }

  @doc "True when the series segments identify content this store can serve."
  @callback valid_series?(series) :: boolean

  @doc "Ordered chapter identifiers for the series (reading order)."
  @callback list_chapters(user, series) :: [chapter]

  @doc """
  Page list for a chapter. `opts[:dims]` hints the dimension fidelity the
  caller needs — `:precise` (paged reading; per-page dims drive spread
  pairing) or `:fast` (strip reading; sampled/estimated dims are fine).
  Stores may ignore the hint; pages missing dims get reader defaults —
  but real dims make layout, scroll restore, and panel snapping stable
  before any image loads. If your source only yields URLs, the
  [`dims`](https://hex.pm/packages/dims) package probes width × height
  cheaply (`Dims.probe_all/2` for `:precise`, `Dims.probe_sampled/2`
  for `:fast`).
  """
  @callback fetch_pages(user, series, chapter, opts :: keyword) ::
              {:ok, [page]} | {:error, term}

  @doc "Per-series reader state (see module doc). `nil` when nothing is saved."
  @callback reader_state(user, series) :: map | nil

  @doc "Persist a validated setting (see module doc)."
  @callback put_setting(user, series, setting :: atom, value :: term, device :: String.t() | nil) ::
              :ok | {:ok, term} | {:error, term}

  @doc """
  Persist reading progress. Called on the reader's progress tick with
  `%{page: pos_integer, fraction: float, total_pages: pos_integer | nil,
  elapsed_seconds: non_neg_integer}`.

  Optionally return `{:ok, %{chapter_read: boolean}}` to tell the reader
  whether this chapter now counts as read by the host's own rules —
  the reader shows a checkmark in the progress pill over the chapter's
  final stretch once it's confirmed. Any other return is ignored.
  """
  @callback save_progress(user, series, chapter, progress :: map) :: :ok | {:ok, term} | {:error, term}

  @doc """
  Forward-only snap of the resume pointer to `chapter` — fired when the
  user enters via an explicit jump-ahead link (`?from_max=1`).
  """
  @callback snap_to_chapter(user, series, chapter) :: :ok | {:ok, term} | {:error, term}

  @doc """
  Authorize + build request headers for proxying an external image URL.
  Return `:forbidden` for hosts you don't recognize (the proxy 403s).
  """
  @callback image_request(url :: String.t(), user) ::
              {:ok, headers :: [{String.t(), String.t()}]} | :forbidden

  @doc "Page overrides for the paged reader (`manga` package). Optional."
  @callback list_page_overrides(user, series, chapter) ::
              [%{page_index: pos_integer, kind: String.t()}]

  @doc """
  Toggle a page override (`"insert_blank_before" | "solo"`). Optional.
  Returns whether the override is now `:added` or `:removed`.
  """
  @callback toggle_page_override(user, series, chapter, page_index :: pos_integer, kind :: String.t()) ::
              {:ok, :added | :removed} | {:error, term}

  @optional_callbacks snap_to_chapter: 3, list_page_overrides: 3, toggle_page_override: 5
end
