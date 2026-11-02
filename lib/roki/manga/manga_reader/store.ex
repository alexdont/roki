defmodule Roki.Manga.MangaReader.Store do
  @moduledoc """
  `Manhwa.Store` implementation backing the packaged readers with this
  app's existing persistence: `Library` for per-series state/progress,
  `Sources` + `SourceThrottle`/`Cache` for content, `ImageDimensions`
  for probing, `Guise` for proxy headers.

  Series come in as the two URL segments: `[source, slug]`.
  """

  @behaviour Manhwa.Store

  alias Roki.Manga.{Cache, ImageDimensions, Library, SourceThrottle, Sources}
  alias Guise

  @impl true
  def valid_series?([source, _slug]), do: Sources.valid?(source)
  def valid_series?(_), do: false

  @impl true
  def list_chapters(_user, [source, slug]) do
    case Library.get_manga_metadata(source, slug) do
      %{data: %{"chapters" => ch}} when ch != [] ->
        ch

      _ ->
        Cache.fetch({source, slug, :chapters}, :timer.hours(1), fn ->
          with mod when not is_nil(mod) <- Sources.module(source),
               {:ok, manga} <- mod.get_manga(slug) do
            manga.chapters
          else
            _ -> []
          end
        end)
    end
  end

  @impl true
  def fetch_pages(user, [source, slug], chapter, opts) do
    case Sources.module(source) do
      nil ->
        {:error, :unknown_source}

      mod ->
        user_id = (user && user.uuid) || "anon"

        result =
          SourceThrottle.throttled_fetch(
            source,
            user_id,
            {source, slug, chapter, :images},
            :timer.hours(6),
            fn -> mod.get_chapter_images(slug, chapter) end
          )

        case result do
          {:ok, urls} ->
            # :precise — full per-page dims (double-page spread pairing
            # needs exact aspect ratios); :fast — sampled + median-filled
            # (strip chapters can be 500+ panels).
            probed =
              case Keyword.get(opts, :dims, :fast) do
                :precise -> ImageDimensions.probe_paged(urls)
                _ -> ImageDimensions.probe_sampled(urls)
              end

            {:ok, probed}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @impl true
  def reader_state(user, [source, slug]) do
    # A series that is not saved has no row, but it can be tried: what was chosen for it in the
    # reader (scroll mode, a direction) is held for a while, so the page opens that way. Saving
    # the series keeps it (`Roki.Manga.Trial`).
    Library.get_saved_manga(user.uuid, source, slug) ||
      Roki.Manga.Trial.get(user.uuid, source, slug)
  end

  @impl true
  def put_setting(user, [source, slug], setting, value, device) do
    if Library.saved?(user.uuid, source, slug),
      do: put_saved_setting(user, [source, slug], setting, value, device),
      else: Roki.Manga.Trial.put(user.uuid, source, slug, setting, value, device)
  end

  defp put_saved_setting(user, [source, slug], setting, value, device) do
    case setting do
      :reading_mode ->
        Library.update_reading_mode(user.uuid, source, slug, value, device)
        :ok

      :reading_direction ->
        Library.update_reading_direction(user.uuid, source, slug, value)
        :ok

      :reading_rotation ->
        Library.update_reading_rotation(user.uuid, source, slug, value)
        :ok

      :smart_crop ->
        Library.update_smart_crop(user.uuid, source, slug, value)
        :ok

      :comments_visible ->
        Library.update_comments_visible(user.uuid, source, slug, value)
        :ok

      :tap_zone_preset ->
        case Library.update_tap_zone_preset(user.uuid, source, slug, value, device) do
          {:error, reason} -> {:error, reason}
          _ -> :ok
        end
    end
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
      user.user_timezone,
      progress.total_pages,
      progress.fraction
    )
  end

  @impl true
  def snap_to_chapter(user, [source, slug], chapter) do
    Library.snap_to_chapter(user.uuid, source, slug, chapter, user.user_timezone)
    :ok
  end

  @impl true
  def image_request(url, user) do
    if Roki.Manga.KotatsuSource.sidecar_image_url?(url) do
      # Sidecar proxy URLs (extension-backed series) — loopback fetch,
      # the sidecar supplies the source site's own headers upstream.
      {:ok, []}
    else
      do_image_request(url, user)
    end
  end

  defp do_image_request(url, user) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        case Sources.image_referer(host) do
          nil -> :forbidden
          referer -> {:ok, Guise.headers(referer, {user && user.uuid, referer})}
        end

      _ ->
        :forbidden
    end
  end

  @impl true
  def list_page_overrides(user, [source, slug], chapter) do
    Library.list_page_overrides(user.uuid, source, slug, chapter)
  end

  @impl true
  def toggle_page_override(user, [source, slug], chapter, page_index, kind) do
    Library.toggle_page_override(user.uuid, source, slug, chapter, page_index, kind)
  end
end
