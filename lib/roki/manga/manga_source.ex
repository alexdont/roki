defmodule Roki.Manga.MangaSource do
  @moduledoc """
  The manga source backend contract the reader codes against.

  Implementations resolve catalogs of external manga sites: list the
  available sources, search within one, fetch a title's details +
  chapters, and fetch a chapter's page images. The reader UI only
  ever talks to this behaviour — individual sources can later be
  reimplemented natively in Elixir without touching the UI.

  The first implementation is `Roki.Manga.MangaSource.Kotatsu`,
  backed by the kotatsu-parsers sidecar (see `kotatsu_sidecar/`).

  All callbacks return errors as values — scraper sources flake
  constantly, and the UI must degrade per-source, never crash.
  """

  @type source :: %{id: String.t(), title: String.t(), locale: String.t()}

  @type manga_ref :: %{source: String.t(), url: String.t()}

  @type manga :: %{
          ref: manga_ref,
          title: String.t(),
          cover_url: String.t() | nil,
          description: String.t() | nil,
          state: atom | nil,
          authors: [String.t()],
          tags: [String.t()]
        }

  @type chapter :: %{
          url: String.t(),
          title: String.t() | nil,
          number: float,
          volume: integer,
          branch: String.t() | nil,
          scanlator: String.t() | nil,
          uploaded_at: DateTime.t() | nil
        }

  @type page :: %{
          index: non_neg_integer,
          image_url: String.t(),
          proxy_path: String.t()
        }

  @typedoc """
  Common error reasons:

    * `:not_found` — unknown source or missing title/chapter
    * `:auth_required` — the source needs credentials (unsupported)
    * `:rate_limited` — upstream 429
    * `{:cloudflare, source_id}` — interactive Cloudflare challenge;
      show a per-source "temporarily unavailable" message
    * `{:upstream, detail}` — parse/HTTP failure at the source
    * `{:transport, reason}` — the backend itself is unreachable
  """
  @type error :: term

  @callback list_sources() :: {:ok, [source]} | {:error, error}

  @callback search(source_id :: String.t(), query :: String.t(), page :: pos_integer) ::
              {:ok, [manga]} | {:error, error}

  @doc "The source's default catalog listing (browse without a query)."
  @callback catalog(source_id :: String.t(), page :: pos_integer) ::
              {:ok, [manga]} | {:error, error}

  @callback details(manga_ref) :: {:ok, manga, [chapter]} | {:error, error}

  @callback pages(source_id :: String.t(), chapter_url :: String.t()) ::
              {:ok, [page]} | {:error, error}
end
