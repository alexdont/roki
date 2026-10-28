defmodule Roki.Manga.MangaReader.Annotations do
  @moduledoc """
  `Manhwa.Annotations` implementation over `Roki.Manga.Library.Marks`
  (etcher shapes + the typed marks store, comment threads via
  PhoenixKitComments underneath).
  """

  @behaviour Manhwa.Annotations

  alias Roki.Manga.Library.Marks

  @impl true
  def list_shapes(viewer, [source, slug], chapter) do
    Marks.list_visible_etcher_shape_payloads(source, slug, chapter, viewer && viewer.uuid)
  end

  @impl true
  def replace_shapes(user_or_uuid, [source, slug], chapter, annotations, opts) do
    Marks.replace_etcher_shapes(uuid(user_or_uuid), source, slug, chapter, annotations, opts)
    :ok
  end

  @impl true
  def attach_comment_to_shape(user, [source, slug], chapter, shape_uuid, attrs) do
    Marks.attach_comment_to_etcher_shape(user, source, slug, chapter, shape_uuid, attrs)
  end

  @impl true
  def list_items(user, [source, slug], chapter) do
    Marks.list_visible_items(source, slug, chapter, user.uuid)
  end

  @impl true
  def create_annotation(user, [source, slug], chapter, attrs) do
    case Marks.create_annotation(user, source, slug, chapter, attrs) do
      {:ok, item} -> {:ok, Map.put(item, "_user_id", user.uuid)}
      error -> error
    end
  end

  @impl true
  def delete_item(user, [source, slug], chapter, item_id) do
    # Annotation deletes also remove the linked comment thread, so look
    # up the item type first and dispatch. Non-annotation items are a
    # simple array splice.
    case Marks.get_user_row(user.uuid, source, slug, chapter) do
      nil ->
        {:error, :not_found}

      %{items: items} ->
        case Enum.find(items, &(&1["id"] == item_id)) do
          nil ->
            {:error, :not_found}

          %{"type" => "annotation"} ->
            Marks.delete_annotation(user, source, slug, chapter, item_id)

          _ ->
            Marks.delete_item(user.uuid, source, slug, chapter, item_id)
        end
    end
  end

  defp uuid(%{uuid: u}), do: u
  defp uuid(u) when is_binary(u), do: u
end
