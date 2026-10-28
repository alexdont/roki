defmodule RokiWeb.KotatsuController do
  @moduledoc """
  Browse surface for kotatsu-backed manga source extensions: the
  per-user extensions picker, a title's details page, and a simple
  vertical chapter reader. Search/explore integration lives in
  `MangaController`; images flow through `KotatsuProxyController`.
  """
  use RokiWeb, :controller

  alias Roki.Manga.MangaSource.Extensions
  alias Roki.Manga.MangaSource.Kotatsu

  # ── Extensions picker ─────────────────────────────────────────────

  def extensions(conn, _params) do
    user = conn.assigns[:phoenix_kit_current_user]
    enabled = Extensions.enabled(user)

    common = [
      # [{"English", [{key, label}, …]}, {"Russian", […]}] — same
      # language grouping the search page uses.
      native_sources: Roki.Manga.Sources.grouped(),
      native_enabled: MapSet.new(Extensions.enabled_native(user)),
      enabled: MapSet.new(enabled)
    ]

    case Kotatsu.list_sources() do
      {:ok, sources} ->
        render(conn, :extensions, [sources: sources, error: nil] ++ common)

      {:error, reason} ->
        render(
          conn,
          :extensions,
          [sources: [], error: "Extension backend unavailable: #{inspect(reason)}"] ++ common
        )
    end
  end

  def update_extensions(conn, params) do
    user = conn.assigns[:phoenix_kit_current_user]

    pick = fn key ->
      case params[key] do
        list when is_list(list) -> Enum.filter(list, &is_binary/1)
        _ -> []
      end
    end

    # Only names that exist in the catalog survive.
    valid_kotatsu =
      case Kotatsu.list_sources() do
        {:ok, sources} ->
          known = MapSet.new(sources, & &1.id)
          Enum.filter(pick.("sources"), &MapSet.member?(known, &1))

        {:error, _} ->
          pick.("sources")
      end

    native_known = MapSet.new(Roki.Manga.Sources.all(), &elem(&1, 0))
    valid_native = Enum.filter(pick.("native"), &MapSet.member?(native_known, &1))

    case Extensions.set_all(user, valid_kotatsu, valid_native) do
      {:ok, _} ->
        conn
        |> put_flash(
          :info,
          "#{length(valid_native)} scrapers + #{length(valid_kotatsu)} extensions enabled"
        )
        |> redirect(to: ~p"/manga/extensions")

      {:error, _} ->
        conn
        |> put_flash(:error, "Could not save extensions")
        |> redirect(to: ~p"/manga/extensions")
    end
  end

  # ── Details page ──────────────────────────────────────────────────
  # Kotatsu titles are first-class now: the NATIVE details page
  # (/manga/kotatsu/<slug>) carries save/read/categories.
  # This route remains as a redirect for old links.

  def manga(conn, %{"name" => name, "url" => url}) do
    slug = Roki.Manga.KotatsuSource.build_slug(name, url)
    redirect(conn, to: ~p"/manga/kotatsu/#{slug}")
  end

  # ── Simple vertical reader ────────────────────────────────────────
  # Deliberately minimal (plain <img> strip through the image proxy):
  # enough to read end-to-end and judge the catalog; the full
  # Fresco/FrescoStrip integration comes later behind the
  # MangaSource behaviour.

  def read(conn, %{"name" => name, "url" => manga_url, "chapter" => chapter_url}) do
    with {:ok, manga, chapters} <- Kotatsu.details(%{source: name, url: manga_url}),
         {:ok, pages} <- Kotatsu.pages(name, chapter_url) do
      idx = Enum.find_index(chapters, &(&1.url == chapter_url))

      {prev_ch, next_ch, current} =
        case idx do
          nil -> {nil, nil, nil}
          i -> {if(i > 0, do: Enum.at(chapters, i - 1)), Enum.at(chapters, i + 1), Enum.at(chapters, i)}
        end

      render(conn, :read,
        source: name,
        manga: manga,
        manga_url: manga_url,
        chapter: current,
        chapter_url: chapter_url,
        pages: pages,
        prev_chapter: prev_ch,
        next_chapter: next_ch,
        error: nil
      )
    else
      {:error, reason} ->
        render(conn, :read,
          source: name,
          manga: nil,
          manga_url: manga_url,
          chapter: nil,
          chapter_url: chapter_url,
          pages: [],
          prev_chapter: nil,
          next_chapter: nil,
          error: source_error_message(reason)
        )
    end
  end

  defp source_error_message({:cloudflare, src}),
    do: "#{src || "This source"} is behind a Cloudflare challenge right now — try again later or pick another source."

  defp source_error_message(:not_found), do: "Not found on this source."
  defp source_error_message(:rate_limited), do: "The source is rate-limiting us — wait a moment and retry."
  defp source_error_message(:auth_required), do: "This source requires an account (not supported)."
  defp source_error_message({:transport, _}), do: "Extension backend is not running."
  defp source_error_message({:upstream, %{detail: d}}) when is_binary(d), do: "Source error: #{d}"
  defp source_error_message(other), do: "Source error: #{inspect(other)}"
end
