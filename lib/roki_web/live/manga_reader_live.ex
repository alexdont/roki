defmodule RokiWeb.Live.MangaReaderLive do
  use RokiWeb, :live_view

  alias Roki.Manga.{Sources, Library}

  @impl true
  def mount(
        %{"source" => source, "slug" => slug, "chapter" => chapter} = params,
        _session,
        socket
      ) do
    with true <- Sources.valid?(source),
         mod when not is_nil(mod) <- Sources.module(source) do
      user = socket.assigns.phoenix_kit_current_scope.user

      search_back_url =
        case params do
          %{"sq" => q} when q != "" ->
            query = if params["ss"], do: %{q: q, source: params["ss"]}, else: %{q: q}
            ~p"/manga/search?#{query}"

          _ ->
            nil
        end

      search_params =
        case params do
          %{"sq" => q} when q != "" ->
            if params["ss"], do: %{sq: q, ss: params["ss"]}, else: %{sq: q}

          _ ->
            %{}
        end

      saved_manga = if user, do: Library.get_saved_manga(user.uuid, source, slug)

      {mode_desktop, mode_mobile} =
        if saved_manga do
          {saved_manga.reading_mode_desktop || saved_manga.reading_mode,
           saved_manga.reading_mode_mobile || saved_manga.reading_mode}
        else
          {"scroll", "scroll"}
        end

      metadata = Library.get_manga_metadata(source, slug)

      user_default_direction = (user.custom_fields || %{})["default_reading_direction"] || "rtl"

      reading_direction =
        cond do
          saved_manga && saved_manga.reading_direction ->
            saved_manga.reading_direction

          metadata && metadata.data["reading_direction"] ->
            normalize_reading_direction(metadata.data["reading_direction"])

          true ->
            user_default_direction
        end

      chapters =
        case metadata do
          %{data: %{"chapters" => ch}} when ch != [] ->
            ch

          _ ->
            Roki.Manga.Cache.fetch({source, slug, :chapters}, :timer.hours(1), fn ->
              case mod.get_manga(slug) do
                {:ok, manga} -> manga.chapters
                _ -> []
              end
            end)
        end

      idx = Enum.find_index(chapters, &(&1 == chapter))
      prev_chapter = if idx && idx > 0, do: Enum.at(chapters, idx - 1)
      next_chapter = if idx, do: Enum.at(chapters, idx + 1)

      user_id = if user, do: user.uuid, else: "anon"

      chapter_images_result =
        Roki.Manga.SourceThrottle.throttled_fetch(
          source,
          user_id,
          {source, slug, chapter, :images},
          :timer.hours(6),
          fn ->
            mod.get_chapter_images(slug, chapter)
          end
        )

      case chapter_images_result do
        {:ok, images} ->
          images = Roki.Manga.ImageDimensions.probe_all(images)

          start_page =
            case params["page"] do
              val when is_binary(val) ->
                case Integer.parse(val) do
                  {n, ""} when n >= 1 -> n
                  _ -> 1
                end

              _ ->
                if saved_manga && saved_manga.last_chapter == chapter && saved_manga.last_page do
                  saved_manga.last_page
                else
                  1
                end
            end

          manga_title = if(saved_manga, do: saved_manga.title, else: slug)
          comments_visible = if saved_manga, do: saved_manga.comments_visible, else: false
          smart_crop = if saved_manga, do: saved_manga.smart_crop, else: false

          user_default_tap_zone = (user.custom_fields || %{})["default_tap_zone"] || "default"

          {tap_zone_desktop, tap_zone_mobile} =
            if saved_manga do
              {saved_manga.tap_zone_preset_desktop || saved_manga.tap_zone_preset ||
                 user_default_tap_zone,
               saved_manga.tap_zone_preset_mobile || saved_manga.tap_zone_preset ||
                 user_default_tap_zone}
            else
              {user_default_tap_zone, user_default_tap_zone}
            end

          tap_zone_preset =
            case params["device"] do
              "mobile" -> tap_zone_mobile
              _ -> tap_zone_desktop
            end

          default_smart_scroll = (user.custom_fields || %{})["default_smart_scroll"] == true

          smart_scroll_config =
            (user.custom_fields || %{})["smart_scroll_config"] ||
              %{
                "jump_style" => "smooth",
                "scan_distance" => 3,
                "long_panel_steps" => true,
                "gutter_tolerance" => 300,
                "min_gutter_width" => 50
              }

          chapter_annotation_counts =
            Library.count_annotations_by_chapter(source, slug, user.uuid)

          device_mode =
            case params["device"] do
              "mobile" -> mode_mobile
              _ -> mode_desktop
            end

          {:ok,
           assign(socket,
             source: source,
             slug: slug,
             chapter: chapter,
             mode: device_mode,
             mode_desktop: mode_desktop,
             mode_mobile: mode_mobile,
             images: images,
             start_page: start_page,
             prev_chapter: prev_chapter,
             next_chapter: next_chapter,
             chapters: chapters,
             current_user: user,
             manga_title: manga_title,
             comments_visible: comments_visible,
             chapter_annotation_counts: chapter_annotation_counts,
             search_back_url: search_back_url,
             search_params: search_params,
             tap_zone_preset: tap_zone_preset,
             reading_direction: reading_direction,
             smart_crop: smart_crop,
             default_smart_scroll: default_smart_scroll,
             smart_scroll_config: smart_scroll_config,
             page_title: "#{manga_title} — Ch. #{chapter}",
             template: if(device_mode in ["paged", "double_page"], do: :paged, else: :scroll),
             comment_modal_open: false,
             comment_resource_uuid: nil,
             comment_chapter: nil,
             comment_page: nil,
             comment_annotation_id: nil,
             comment_annotation_color: nil,
             comment_annotation_visibility: nil,
             comment_annotation_is_own: false
           )}

        {:error, reason} ->
          {:ok,
           socket
           |> put_flash(:error, "Failed to load chapter: #{inspect(reason)}")
           |> redirect(to: ~p"/manga/#{source}/#{slug}")}
      end
    else
      _ ->
        {:ok, socket |> put_flash(:error, "Unknown source") |> redirect(to: ~p"/manga")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="comment-bridge" phx-hook="CommentBridge"></div>

    <%= if @comment_modal_open do %>
      <div
        id="comment-modal-root"
        phx-hook="CommentModalScrollLock"
        class="fixed inset-0 z-[10000] flex items-end sm:items-center justify-center"
      >
        <div
          id="comment-modal-backdrop"
          class="fixed inset-0 bg-black/50"
          phx-click="close_comment_modal"
        >
        </div>
        <div
          id="comment-modal-scroll"
          phx-hook="CommentModalScroll"
          class="relative z-10 w-full sm:max-w-lg max-h-[85vh] overflow-y-auto bg-base-100 rounded-t-2xl sm:rounded-2xl shadow-2xl"
          style="overscroll-behavior: contain; touch-action: auto;"
        >
          <div class="sticky top-0 z-10 flex items-center justify-between px-4 py-3 bg-base-100 border-b border-base-300 rounded-t-2xl">
            <h3 class="font-bold text-lg">Comments</h3>
            <button phx-click="close_comment_modal" class="btn btn-ghost btn-sm btn-circle">✕</button>
          </div>
          <div class="p-4 space-y-3">
            <%= if @comment_annotation_is_own and @comment_annotation_id do %>
              <div
                id={"ann-settings-#{@comment_annotation_id}"}
                class="rounded-lg border border-base-300 bg-base-200 p-3 space-y-2"
              >
                <div class="text-xs font-semibold opacity-70">Annotation settings</div>

                <div class="flex items-center gap-2">
                  <span class="text-xs opacity-60">Color:</span>
                  <%= for c <- ~w(blue pink green purple) do %>
                    <button
                      type="button"
                      title={c}
                      class={[
                        "w-6 h-6 rounded-full cursor-pointer border-2",
                        if(c == @comment_annotation_color,
                          do: "border-base-content",
                          else: "border-transparent"
                        )
                      ]}
                      style={"background: #{ann_color_rgb(c)}"}
                      onclick={"window.updateAnnotationField(#{Jason.encode!(to_string(@comment_annotation_id))}, #{Jason.encode!(@source)}, #{Jason.encode!(@slug)}, #{Jason.encode!(@comment_chapter)}, {color: #{Jason.encode!(c)}})"}
                    ></button>
                  <% end %>
                </div>

                <label class="flex items-center gap-2 text-xs cursor-pointer">
                  <input
                    type="checkbox"
                    class="checkbox checkbox-xs"
                    checked={@comment_annotation_visibility == "private"}
                    onclick={"window.updateAnnotationField(#{Jason.encode!(to_string(@comment_annotation_id))}, #{Jason.encode!(@source)}, #{Jason.encode!(@slug)}, #{Jason.encode!(@comment_chapter)}, {visibility: this.checked ? 'private' : 'public'})"}
                  />
                  <span>🔒 Private (only you can see)</span>
                </label>

                <button
                  type="button"
                  class="btn btn-xs btn-outline"
                  onclick={"window.redrawAnnotation(#{Jason.encode!(to_string(@comment_annotation_id))}, #{Jason.encode!(@source)}, #{Jason.encode!(@slug)}, #{Jason.encode!(@comment_chapter)})"}
                >
                  ✏️ Redraw box
                </button>
              </div>
            <% end %>

            <.live_component
              module={PhoenixKitComments.Web.CommentsComponent}
              id={"comments-#{@comment_resource_uuid}"}
              resource_type="manga_annotation"
              resource_uuid={@comment_resource_uuid}
              current_user={@current_user}
              title="Annotation Comments"
              show_title={false}
              composer_position={:bottom}
            />
          </div>
        </div>
      </div>
    <% end %>

    <%= if @template == :paged do %>
      {RokiWeb.MangaHTML.show_paged(assigns)}
    <% else %>
      {RokiWeb.MangaHTML.show(assigns)}
    <% end %>
    """
  end

  @impl true
  def handle_event("open_comment_modal", params, socket) do
    resource_uuid =
      params["comment_uuid"] ||
        Library.deterministic_uuid(
          "#{socket.assigns.source}:#{socket.assigns.slug}:#{params["chapter"]}:#{params["page"]}"
        )

    is_own = params["is_own"] in [true, "true"]

    annotation_id =
      case params["annotation_id"] do
        nil -> nil
        "" -> nil
        v -> to_string(v)
      end

    {:noreply,
     assign(socket,
       comment_modal_open: true,
       comment_resource_uuid: resource_uuid,
       comment_chapter: params["chapter"],
       comment_page: params["page"],
       comment_annotation_id: annotation_id,
       comment_annotation_color: params["color"] || "blue",
       comment_annotation_visibility: params["visibility"] || "public",
       comment_annotation_is_own: is_own
     )}
  end

  def handle_event("close_comment_modal", _, socket) do
    {:noreply, assign(socket, comment_modal_open: false)}
  end

  def handle_event("annotation_updated", %{"annotation_id" => id} = params, socket) do
    current_id = socket.assigns[:comment_annotation_id]

    if current_id && to_string(current_id) == to_string(id) do
      {:noreply,
       assign(socket,
         comment_annotation_color: params["color"] || socket.assigns.comment_annotation_color,
         comment_annotation_visibility:
           params["visibility"] || socket.assigns.comment_annotation_visibility
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("annotation_updated", _, socket), do: {:noreply, socket}

  defp ann_color_rgb("pink"), do: "rgb(236,72,153)"
  defp ann_color_rgb("green"), do: "rgb(74,222,128)"
  defp ann_color_rgb("purple"), do: "rgb(168,85,247)"
  defp ann_color_rgb(_), do: "rgb(59,130,246)"

  defp normalize_reading_direction(dir) when is_binary(dir) do
    d = String.downcase(dir)

    cond do
      String.contains?(d, "left") ->
        "ltr"

      String.contains?(d, "manhwa") or String.contains?(d, "manhua") or
          String.contains?(d, "webtoon") ->
        "ltr"

      true ->
        "rtl"
    end
  end

  defp normalize_reading_direction(_), do: "rtl"
end
