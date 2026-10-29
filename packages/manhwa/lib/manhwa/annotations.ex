defmodule Manhwa.Annotations do
  @moduledoc """
  Optional adapter for the annotation layer (Etcher shapes + attached
  comment threads). When unconfigured the reader works fully — the
  annotate button and composer simply don't render.

      config :manhwa, annotations: MyApp.ReaderAnnotations

  Shapes are stored per `(user, series, chapter)`; the reader treats
  shape payloads and mark items as opaque maps that round-trip between
  your store and the Etcher JS layer.
  """

  @type user :: term
  @type series :: Manhwa.Store.series()
  @type chapter :: String.t()

  @doc """
  Every shape payload visible to `viewer` for the chapter — the viewer's
  own shapes (any visibility) plus other users' public shapes. `viewer`
  may be `nil` (anonymous → public only). Hydrated into the viewer's
  `"etcher"` extension at render time.
  """
  @callback list_shapes(viewer :: user | nil, series, chapter) :: [map]

  @doc """
  Replace the user's saved shapes for a chapter with `annotations`
  (the Etcher layer's full-state save). `opts` may carry `:author_name`
  to stamp tooltip metadata.
  """
  @callback replace_shapes(user, series, chapter, annotations :: [map], opts :: keyword) ::
              :ok | {:ok, term} | {:error, term}

  @doc """
  Attach a comment (composer post) to a drawn shape. `attrs` carries
  `title/content/visibility/giphy`. Returns
  `%{comment_uuid:, resource_uuid:, tooltip_metadata:}` on success.
  """
  @callback attach_comment_to_shape(user, series, chapter, shape_uuid :: String.t(), attrs :: map) ::
              {:ok, map} | {:error, term}

  @doc "List the user's visible mark items (typed overlay store) for a chapter."
  @callback list_items(user, series, chapter) :: [map]

  @doc "Create a standalone annotation mark item."
  @callback create_annotation(user, series, chapter, attrs :: map) :: {:ok, map} | {:error, term}

  @doc """
  Delete a mark item by id (adapter dispatches annotation-vs-plain-item
  cleanup, e.g. removing a linked comment thread).
  """
  @callback delete_item(user, series, chapter, item_id :: String.t()) ::
              {:ok, term} | {:error, :not_found | term}

  @optional_callbacks replace_shapes: 5, list_items: 3, create_annotation: 4, delete_item: 4
end
