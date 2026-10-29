defmodule Manhwa.Router do
  @moduledoc """
  Mounts the reader's routes into a host router.

      import Manhwa.Router

      scope "/" do
        pipe_through [:browser, :require_auth]
        manhwa_reader "/reader/manga"
      end

  With `series_segments: 2` (the default) a series is addressed as
  `/:source/:slug`, so the reader page lives at
  `/reader/manga/:source/:slug/:chapter`; with `series_segments: 1`
  it's `/reader/:series/:chapter`.

  All settings, progress, image-proxy, and annotation API endpoints are
  mounted under the same prefix, so the package's templates and JS know
  their own URLs — the host never builds a reader URL by hand except
  the entry link to `show`.

  Options:

    * `:series_segments` — 1 or 2 (default 2)
    * `:controller` — override the controller module (used by the
      `manga` package's `manga_reader/2` to layer paged-mode dispatch
      on the same route surface)
  """

  defmacro manhwa_reader(path, opts \\ []) do
    controller = Keyword.get(opts, :controller, Manhwa.ReaderController)
    segments = Keyword.get(opts, :series_segments, 2)

    series_path =
      case segments do
        1 -> "/:series"
        2 -> "/:source/:slug"
        other -> raise ArgumentError, "series_segments must be 1 or 2, got: #{inspect(other)}"
      end

    quote bind_quoted: [
            path: path,
            controller: controller,
            series_path: series_path,
            segments: segments
          ] do
      scope path do
        # Literal-prefix routes first so they aren't shadowed by the
        # dynamic series segments below.
        get "/proxy/image", controller, :proxy_image,
          private: %{manhwa: %{segments: segments}}

        scope "/api" do
          post "/debug-log", controller, :debug_log,
            private: %{manhwa: %{segments: segments}}

          get "/gifs/search", controller, :gif_search,
            private: %{manhwa: %{segments: segments}}

          get "/gifs/trending", controller, :gif_trending,
            private: %{manhwa: %{segments: segments}}

          scope series_path do
            get "/:chapter/images", controller, :chapter_images,
              private: %{manhwa: %{segments: segments}}

            post "/:chapter/page_overrides", controller, :toggle_page_override,
              private: %{manhwa: %{segments: segments}}

            get "/:chapter/marks", controller, :list_marks,
              private: %{manhwa: %{segments: segments}}

            post "/:chapter/marks/annotations", controller, :create_mark_annotation,
              private: %{manhwa: %{segments: segments}}

            post "/:chapter/marks/etcher-shapes/:shape_uuid/comment", controller, :attach_etcher_comment,
              private: %{manhwa: %{segments: segments}}

            delete "/:chapter/marks/:item_id", controller, :delete_mark,
              private: %{manhwa: %{segments: segments}}
          end
        end

        scope series_path do
          put "/reading_mode", controller, :update_reading_mode,
            private: %{manhwa: %{segments: segments}}

          put "/reading_direction", controller, :update_reading_direction,
            private: %{manhwa: %{segments: segments}}

          put "/comments_visible", controller, :update_comments_visible,
            private: %{manhwa: %{segments: segments}}

          put "/reading_rotation", controller, :update_reading_rotation,
            private: %{manhwa: %{segments: segments}}

          put "/smart_crop", controller, :update_smart_crop,
            private: %{manhwa: %{segments: segments}}

          put "/tap_zone_preset", controller, :update_tap_zone_preset,
            private: %{manhwa: %{segments: segments}}

          put "/progress", controller, :update_progress,
            private: %{manhwa: %{segments: segments}}

          get "/:chapter", controller, :show,
            private: %{manhwa: %{segments: segments}}
        end
      end
    end
  end
end
