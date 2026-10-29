defmodule Manhwa.ReaderController do
  @moduledoc """
  The reader's own controller, mounted by `Manhwa.Router.manhwa_reader/2`.

  Every action resolves the current user via `Manhwa.Config.current_user/1`
  and persists through the configured `Manhwa.Store` (plus the optional
  `Manhwa.Annotations` / `Manhwa.GifProvider` adapters). `show/2` renders
  the long-strip reader; the `manga` package overrides dispatch to add
  paged mode on the same surface.
  """

  use Phoenix.Controller, formats: [:html, :json]

  import Plug.Conn

  alias Manhwa.{Config, ReaderState}

  @valid_modes ~w(scroll paged double_page)
  @valid_directions ~w(rtl ltr)

  # ── Reader page ──────────────────────────────────────────────────

  def show(conn, params), do: strip(conn, params)

  @doc """
  Entry for the strip reader — validates the series, applies the
  `?from_max=1` resume snap, and renders. Public so a dispatching
  controller (the `manga` package) can route scroll-mode series here.
  """
  def strip(conn, params) do
    with_series(conn, params, fn series, user ->
      chapter = params["chapter"]

      if user && params["from_max"] == "1" do
        optional_store(:snap_to_chapter, [user, series, chapter])
      end

      render_strip(conn, params, series, user)
    end)
  end

  defp render_strip(conn, params, series, user) do
    store = Config.store()
    chapter = params["chapter"]
    state = user && store.reader_state(user, series)

    chapters = store.list_chapters(user, series)
    idx = Enum.find_index(chapters, &(&1 == chapter))
    prev_chapter = if idx && idx > 0, do: Enum.at(chapters, idx - 1)
    next_chapter = if idx, do: Enum.at(chapters, idx + 1)

    case store.fetch_pages(user, series, chapter, dims: :fast) do
      {:ok, images} ->
        title = ReaderState.get(state, :title) || List.last(series)

        {resume_page, resume_fraction} =
          if state && ReaderState.get(state, :last_chapter) == chapter &&
               ReaderState.get(state, :last_page) do
            {ReaderState.get(state, :last_page), ReaderState.get(state, :last_page_fraction) || 0.0}
          else
            {1, 0.0}
          end

        urls = url_assigns(conn, series, chapter)

        conn
        |> put_view(html: Manhwa.ReaderHTML)
        |> render(
          :strip,
          [
            series: series,
            chapter: chapter,
            images: images,
            total_pages: length(images),
            chapters: chapters,
            prev_chapter: prev_chapter,
            next_chapter: next_chapter,
            manga_title: title,
            current_user: user,
            etcher_annotations: list_shapes(user, series, chapter),
            resume_page: resume_page,
            resume_fraction: resume_fraction,
            # `?ann=` means the user landed here from a comment deep-link —
            # JS gates progress saves until they prove they're rereading.
            transient_mode: params["ann"] != nil,
            page_title: "#{title} — Ch. #{chapter}",
            extra_head: Config.extra_head()
          ] ++ urls ++ etcher_assigns(conn, user, series, chapter, "fresco-strip-reader")
        )

      {:error, reason} ->
        conn
        |> put_flash(:error, "Failed to load chapter: #{inspect(reason)}")
        |> redirect(to: Config.series_url(series))
    end
  end

  # ── Chapter images JSON API (in-place swap / infinite scroll) ────

  def chapter_images(conn, params) do
    with_series(conn, params, fn series, user ->
      case chapter_images_data(user, series, params["chapter"], dims: :fast) do
        {:ok, data} ->
          json(conn, data)

        {:error, _reason} ->
          conn |> put_status(404) |> json(%{error: "Chapter not found"})
      end
    end)
  end

  @doc """
  The mode-independent payload behind the images API. The `manga`
  package augments it with the paged canvas layout.
  """
  def chapter_images_data(user, series, chapter, opts) do
    store = Config.store()

    case store.fetch_pages(user, series, chapter, opts) do
      {:ok, images} ->
        chapters = store.list_chapters(user, series)
        idx = Enum.find_index(chapters, &(&1 == chapter))
        prev_chapter = if idx && idx > 0, do: Enum.at(chapters, idx - 1)
        next_chapter = if idx, do: Enum.at(chapters, idx + 1)

        {:ok,
         %{
           chapter: chapter,
           images: images,
           prev_chapter: prev_chapter,
           next_chapter: next_chapter,
           etcher_shapes: list_shapes(user, series, chapter)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Per-series settings ──────────────────────────────────────────

  def update_reading_mode(conn, %{"mode" => mode} = params) when mode in @valid_modes do
    with_series(conn, params, fn series, user ->
      device = ReaderState.effective_update_device(conn, params)
      Config.store().put_setting(user, series, :reading_mode, mode, device)

      redirect_url =
        case params["redirect_to"] do
          rt when is_binary(rt) and rt != "" -> append_device(rt, device)
          _ -> Config.series_url(series)
        end

      redirect(conn, to: redirect_url)
    end)
  end

  def update_reading_mode(conn, _params) do
    conn |> put_status(422) |> json(%{error: "Invalid mode"})
  end

  # Keep the device slot on the redirect URL so the page re-renders
  # under the same per-device override the user just wrote to.
  defp append_device(redirect_to, nil), do: redirect_to

  defp append_device(redirect_to, device) do
    uri = URI.parse(redirect_to)
    query = URI.decode_query(uri.query || "")
    %{uri | query: URI.encode_query(Map.put(query, "device", device))} |> to_string()
  end

  def update_reading_direction(conn, %{"direction" => direction} = params)
      when direction in @valid_directions do
    with_series(conn, params, fn series, user ->
      Config.store().put_setting(user, series, :reading_direction, direction, nil)
      json(conn, %{ok: true, reading_direction: direction})
    end)
  end

  def update_reading_direction(conn, _params) do
    conn |> put_status(422) |> json(%{error: "Invalid direction"})
  end

  def update_comments_visible(conn, %{"visible" => visible} = params) do
    with_series(conn, params, fn series, user ->
      val = visible in [true, "true", "1"]
      Config.store().put_setting(user, series, :comments_visible, val, nil)
      json(conn, %{ok: true, comments_visible: val})
    end)
  end

  def update_reading_rotation(conn, %{"rotation" => rotation} = params) do
    case normalize_rotation(rotation) do
      :error ->
        conn |> put_status(422) |> json(%{error: "Invalid rotation"})

      rot ->
        with_series(conn, params, fn series, user ->
          Config.store().put_setting(user, series, :reading_rotation, rot, nil)
          json(conn, %{ok: true, reading_rotation: rot})
        end)
    end
  end

  defp normalize_rotation(r) when is_integer(r), do: normalize_rotation_value(r)

  defp normalize_rotation(r) when is_binary(r) do
    case Integer.parse(r) do
      {n, _} -> normalize_rotation_value(n)
      :error -> :error
    end
  end

  defp normalize_rotation(_), do: :error

  # Map -90 → 270 to match Fresco's normalized [0, 360) representation.
  defp normalize_rotation_value(r) do
    snapped = rem(rem(r, 360) + 360, 360)
    if snapped in [0, 90, 180, 270], do: snapped, else: :error
  end

  def update_smart_crop(conn, %{"enabled" => enabled} = params) do
    with_series(conn, params, fn series, user ->
      val = enabled in [true, "true", "1"]
      Config.store().put_setting(user, series, :smart_crop, val, nil)
      json(conn, %{ok: true, smart_crop: val})
    end)
  end

  def update_tap_zone_preset(conn, %{"preset" => preset} = params) do
    with_series(conn, params, fn series, user ->
      device = ReaderState.normalize_device(params["device"])

      case Config.store().put_setting(user, series, :tap_zone_preset, preset, device) do
        {:error, _} -> conn |> put_status(422) |> json(%{error: "Invalid preset"})
        _ -> json(conn, %{ok: true, tap_zone_preset: preset})
      end
    end)
  end

  # ── Progress ─────────────────────────────────────────────────────

  def update_progress(conn, %{"chapter" => chapter, "page" => page} = params) do
    with_series(conn, params, fn series, user ->
      page = if is_binary(page), do: String.to_integer(page), else: page

      progress = %{
        page: page,
        fraction: parse_page_fraction(params["page_fraction"]),
        total_pages: parse_total_pages(params["total_pages"]),
        elapsed_seconds: parse_elapsed(params["elapsed"])
      }

      # A store may return `{:ok, %{chapter_read: boolean}}` to tell the
      # reader whether this chapter now counts as read — surfaced as a
      # checkmark in the progress pill. Plain `:ok` keeps the old shape.
      case Config.store().save_progress(user, series, chapter, progress) do
        {:ok, %{chapter_read: read}} -> json(conn, %{ok: true, chapter_read: read == true})
        _ -> json(conn, %{ok: true})
      end
    end)
  end

  defp parse_total_pages(n) when is_integer(n) and n > 0, do: n

  defp parse_total_pages(n) when is_binary(n) do
    case Integer.parse(n) do
      {v, _} when v > 0 -> v
      _ -> nil
    end
  end

  defp parse_total_pages(_), do: nil

  defp parse_page_fraction(nil), do: 0.0
  defp parse_page_fraction(f) when is_float(f), do: f |> max(0.0) |> min(1.0)
  defp parse_page_fraction(n) when is_integer(n), do: n |> max(0) |> min(1) |> :erlang.float()

  defp parse_page_fraction(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f |> max(0.0) |> min(1.0)
      :error -> 0.0
    end
  end

  defp parse_page_fraction(_), do: 0.0

  defp parse_elapsed(nil), do: 0
  defp parse_elapsed(val) when is_integer(val), do: val
  defp parse_elapsed(val) when is_float(val), do: round(val)

  defp parse_elapsed(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp parse_elapsed(_), do: 0

  # ── Page overrides (paged reader; optional store callbacks) ──────

  def toggle_page_override(
        conn,
        %{"chapter" => chapter, "page_index" => page_index, "kind" => kind} = params
      ) do
    with_series(conn, params, fn series, user ->
      page_index =
        case page_index do
          n when is_integer(n) ->
            n

          n when is_binary(n) ->
            case Integer.parse(n) do
              {v, ""} -> v
              _ -> 0
            end

          _ ->
            0
        end

      cond do
        page_index < 1 ->
          conn |> put_status(422) |> json(%{error: "page_index must be >= 1"})

        kind not in ["insert_blank_before", "solo"] ->
          conn |> put_status(422) |> json(%{error: "invalid kind"})

        true ->
          case optional_store(
                 :toggle_page_override,
                 [user, series, chapter, page_index, kind],
                 {:error, :not_supported}
               ) do
            {:ok, state} -> json(conn, %{ok: true, state: Atom.to_string(state)})
            {:error, _} -> conn |> put_status(422) |> json(%{error: "could not toggle"})
          end
      end
    end)
  end

  # ── Image proxy ──────────────────────────────────────────────────

  def proxy_image(conn, %{"url" => url}) do
    user = Config.current_user(conn)

    case Config.store().image_request(url, user) do
      {:ok, headers} -> stream_image(conn, url, headers)
      _ -> send_resp(conn, 403, "Forbidden")
    end
  end

  def proxy_image(conn, _params), do: send_resp(conn, 403, "Forbidden")

  defp stream_image(conn, url, headers) do
    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: body, headers: resp_headers}} ->
        content_type =
          resp_headers
          |> Enum.find_value("image/jpeg", fn
            {"content-type", [val | _]} -> val
            _ -> nil
          end)

        conn
        |> put_resp_content_type(content_type)
        |> put_resp_header("cache-control", "public, max-age=86400")
        |> send_resp(200, body)

      _ ->
        send_resp(conn, 502, "Failed to fetch image")
    end
  end

  # ── Debug log sink ───────────────────────────────────────────────

  def debug_log(conn, params) do
    if path = Config.debug_log_path() do
      line = Jason.encode!(%{ts: System.system_time(:millisecond), payload: params})
      File.write(path, line <> "\n", [:append])
    end

    json(conn, %{ok: true})
  end

  # ── GIF picker ───────────────────────────────────────────────────

  def gif_search(conn, params) do
    with_gifs(conn, fn gifs ->
      case params["q"] do
        q when is_binary(q) and q != "" ->
          case gifs.search(q, limit: parse_limit(params), offset: parse_offset(params)) do
            {:ok, list} -> json(conn, %{data: list})
            {:error, reason} -> conn |> put_status(502) |> json(%{error: inspect(reason)})
          end

        _ ->
          json(conn, %{data: []})
      end
    end)
  end

  def gif_trending(conn, params) do
    with_gifs(conn, fn gifs ->
      case gifs.trending(limit: parse_limit(params)) do
        {:ok, list} -> json(conn, %{data: list})
        {:error, reason} -> conn |> put_status(502) |> json(%{error: inspect(reason)})
      end
    end)
  end

  defp parse_limit(params) do
    case Integer.parse(params["limit"] || "20") do
      {n, _} -> min(n, 50)
      :error -> 20
    end
  end

  defp parse_offset(params) do
    case Integer.parse(params["offset"] || "0") do
      {n, _} -> max(n, 0)
      :error -> 0
    end
  end

  defp with_gifs(conn, fun) do
    case Config.gif_provider() do
      nil -> conn |> put_status(404) |> json(%{error: "No GIF provider configured"})
      gifs -> fun.(gifs)
    end
  end

  # ── Marks / annotations API ──────────────────────────────────────

  def list_marks(conn, %{"chapter" => chapter} = params) do
    with_annotations(conn, params, fn ann, series, user ->
      json(conn, %{items: ann.list_items(user, series, chapter)})
    end)
  end

  def create_mark_annotation(conn, %{"chapter" => chapter} = params) do
    with_annotations(conn, params, fn ann, series, user ->
      attrs = %{
        title: params["title"] || "",
        content: params["content"] || "",
        color: params["color"] || "blue",
        visibility: params["visibility"] || "public",
        anchor: params["anchor"] || %{},
        giphy: params["giphy"]
      }

      case ann.create_annotation(user, series, chapter, attrs) do
        {:ok, item} ->
          conn |> put_status(201) |> json(%{item: item})

        {:error, reason} ->
          conn |> put_status(422) |> json(%{error: inspect(reason)})
      end
    end)
  end

  def attach_etcher_comment(
        conn,
        %{"chapter" => chapter, "shape_uuid" => shape_uuid} = params
      ) do
    with_annotations(conn, params, fn ann, series, user ->
      # The composer sends `gif_url` on the wire; adapters store it
      # under `giphy` as `%{url, preview_url}`.
      giphy =
        case params["gif_url"] do
          url when is_binary(url) and url != "" -> %{"url" => url, "preview_url" => url}
          _ -> params["giphy"]
        end

      attrs = %{
        title: params["title"] || "",
        content: params["content"] || "",
        visibility: params["visibility"] || "public",
        giphy: giphy
      }

      if attrs.content == "" and is_nil(giphy) do
        conn |> put_status(422) |> json(%{error: "content or gif required"})
      else
        case ann.attach_comment_to_shape(user, series, chapter, shape_uuid, attrs) do
          {:ok, %{comment_uuid: cuuid, resource_uuid: ruuid, tooltip_metadata: meta}} ->
            conn
            |> put_status(201)
            |> json(%{
              shape_uuid: shape_uuid,
              comment_uuid: cuuid,
              resource_uuid: ruuid,
              tooltip_metadata: meta
            })

          {:error, reason} ->
            conn |> put_status(422) |> json(%{error: inspect(reason)})
        end
      end
    end)
  end

  def delete_mark(conn, %{"chapter" => chapter, "item_id" => item_id} = params) do
    with_annotations(conn, params, fn ann, series, user ->
      case ann.delete_item(user, series, chapter, item_id) do
        {:ok, _} -> json(conn, %{ok: true})
        {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "item not found"})
        {:error, reason} -> conn |> put_status(422) |> json(%{error: inspect(reason)})
      end
    end)
  end

  defp with_annotations(conn, params, fun) do
    case Config.annotations() do
      nil ->
        conn |> put_status(404) |> json(%{error: "Annotations not configured"})

      ann ->
        with_series(conn, params, fn series, user -> fun.(ann, series, user) end)
    end
  end

  # ── Shared plumbing (also used by the `manga` package) ───────────

  @doc "Series segments for the request, per the router macro's `series_segments`."
  def series(conn, params) do
    case seg_count(conn) do
      1 -> [params["series"]]
      2 -> [params["source"], params["slug"]]
    end
  end

  def seg_count(conn), do: conn.private.manhwa.segments

  @doc """
  Validate the series and resolve the user, running `fun.(series, user)`;
  404s on an unknown series. Wraps every series-scoped action.
  """
  def with_series(conn, params, fun) do
    series = series(conn, params)

    if Enum.all?(series, &is_binary/1) && Config.store().valid_series?(series) do
      fun.(series, Config.current_user(conn))
    else
      case get_format(conn) do
        "json" -> conn |> put_status(404) |> json(%{error: "Unknown series"})
        _ -> send_resp(conn, 404, "Unknown series")
      end
    end
  end

  @doc """
  The mount prefix of the reader routes, recovered from the request
  path by dropping this route's trailing segments — works no matter
  what host scopes wrap the macro.
  """
  def reader_base(conn, trailing) do
    "/" <>
      (conn.path_info
       |> Enum.drop(-trailing)
       |> Enum.map_join("/", fn seg -> URI.encode(seg, &URI.char_unreserved?/1) end))
  end

  @doc """
  URL assigns shared by both reader templates. Only valid from the
  `show` route (base = path minus series + chapter segments).
  """
  def url_assigns(conn, series, chapter) do
    base = reader_base(conn, seg_count(conn) + 1)
    joined = Enum.map_join(series, "/", fn seg -> URI.encode(seg, &URI.char_unreserved?/1) end)
    series_base = "#{base}/#{joined}"
    encoded_chapter = URI.encode(chapter, &URI.char_unreserved?/1)

    [
      reader_root: base,
      series_base: series_base,
      self_url: "#{series_base}/#{encoded_chapter}",
      api_base: "#{base}/api/#{joined}",
      proxy_url: "#{base}/proxy/image",
      debug_log_url: "#{base}/api/debug-log",
      gif_base: if(Config.gif_provider(), do: "#{base}/api/gifs"),
      series_url: Config.series_url(series),
      legacy_url: Config.legacy_url(series, chapter)
    ]
  end

  def etcher_assigns(conn, user, series, chapter, fresco_id) do
    case Config.etcher_host() do
      nil ->
        [etcher_host: nil, etcher_session: nil]

      mod ->
        base = %{"fresco_id" => fresco_id, "series" => series, "chapter" => chapter}

        base =
          case series do
            [source, slug] -> base |> Map.put("source", source) |> Map.put("slug", slug)
            [slug] -> Map.put(base, "slug", slug)
            _ -> base
          end

        [etcher_host: mod, etcher_session: Map.merge(base, Config.etcher_session(conn, user))]
    end
  end

  def list_shapes(user, series, chapter) do
    case Config.annotations() do
      nil -> []
      mod -> mod.list_shapes(user, series, chapter)
    end
  end

  @doc "Invoke an optional store callback, returning `default` when unimplemented."
  def optional_store(fun, args, default \\ :ok) do
    store = Config.store()

    if Code.ensure_loaded?(store) and function_exported?(store, fun, length(args)) do
      apply(store, fun, args)
    else
      default
    end
  end
end
