defmodule Roki.Manga.Store do
  @moduledoc """
  What the packaged reader asks this application for: where a series' chapters and pages come
  from, and where someone's place in it is kept. The reader owns the reading — the page and strip
  engines, the settings, the progress ticking — and this is the whole of the seam between them.

  A series arrives as the two segments of the address, `[source, slug]`, exactly as they were
  saved in the old reader, so an imported row opens at the same address it always did.
  """
  @behaviour Manhwa.Store

  alias Roki.Manga.{Library, Sidecar, Sources}
  alias Roki.TTLCache

  # A chapter list is worth an hour; a page list six, since re-reading a chapter should not fetch
  # it again. Both are the old reader's numbers.
  @chapters_ttl 3600
  @pages_ttl 21_600

  @impl true
  def valid_series?([source, _slug]), do: Sources.known?(source)
  def valid_series?(_), do: false

  @impl true
  def list_chapters(_user, [source, slug]) do
    TTLCache.fetch({:manga_chapters, source, slug}, @chapters_ttl, fn ->
      with mod when not is_nil(mod) <- Sources.module(source),
           {:ok, manga} <- mod.get_manga(slug) do
        # Worth remembering: a shelf can then be drawn without asking the site again.
        id = Library.series_id(source, slug)
        Library.remember(id, title: manga[:title], cover_url: manga[:cover_url])
        {:ok, manga[:chapters] || []}
      else
        nil -> {:error, :unknown_source}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> case do
      {:ok, chapters} -> chapters
      _ -> []
    end
  end

  @impl true
  def fetch_pages(_user, [source, slug], chapter, opts) do
    case Sources.module(source) do
      nil ->
        {:error, :unknown_source}

      mod ->
        TTLCache.fetch({:manga_pages, source, slug, chapter}, @pages_ttl, fn ->
          mod.get_chapter_images(slug, chapter)
        end)
        |> case do
          {:ok, urls} -> {:ok, sized(urls, opts)}
          other -> other
        end
    end
  end

  # The reader lays a page out before its image has loaded, so it wants each one's size up front:
  # exactly, for the paged reader whose spread pairing depends on the aspect ratio, and sampled
  # for a strip chapter that may be five hundred panels long.
  defp sized(urls, opts) do
    case Keyword.get(opts, :dims, :fast) do
      :precise -> Dims.probe_all(urls)
      _ -> Dims.probe_sampled(urls)
    end
  rescue
    # A source that will not give up its dimensions is not a reason to refuse to read it: the
    # reader has defaults for a page whose size it does not know.
    _ -> for url <- urls, do: %{url: url}
  end

  @impl true
  def reader_state(user, [source, slug]), do: user && Library.state(user.uuid, source, slug)

  @impl true
  def put_setting(user, [source, slug], setting, value, device) do
    Library.put_setting(user.uuid, source, slug, setting, value, device)
  end

  @impl true
  def save_progress(user, [source, slug], chapter, progress) do
    Library.update_progress(
      user.uuid,
      source,
      slug,
      chapter,
      progress.page,
      progress.elapsed_seconds,
      progress[:total_pages],
      progress[:fraction]
    )
  end

  @impl true
  def snap_to_chapter(_user, _series, _chapter), do: :ok

  @impl true
  def image_request(url, _user) do
    cond do
      # The sidecar's own address: it adds the parser's headers upstream, so none are needed here.
      Sidecar.image_url?(url) ->
        {:ok, []}

      true ->
        case URI.parse(url) do
          %URI{host: host} when is_binary(host) ->
            case Sources.image_referer(host) do
              nil -> :forbidden
              referer -> {:ok, Guise.headers(referer)}
            end

          _ ->
            :forbidden
        end
    end
  end

  @impl true
  def list_page_overrides(user, [source, slug], chapter) do
    Library.page_overrides(user.uuid, source, slug, chapter)
  end

  @impl true
  def toggle_page_override(user, [source, slug], chapter, page_index, kind) do
    Library.toggle_page_override(user.uuid, source, slug, chapter, page_index, kind)
  end
end
