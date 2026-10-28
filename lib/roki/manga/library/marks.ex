defmodule Roki.Manga.Library.Marks do
  @moduledoc """
  CRUD on `manga_marks` items — the per-user-per-chapter overlay bag.

  Items live in the `items` jsonb array on the `MangaMark` row. We
  keep all item-touching operations in one place so the upsert /
  append / find-and-replace / find-and-remove patterns don't get
  reinvented at each callsite.

  Annotation items additionally drive a `phoenix_kit_comments` row,
  matching the existing production pattern — each annotation's text
  body, likes, and replies reuse PhoenixKitComments. The annotation's
  position + type metadata stays in the item.
  """

  import Ecto.Query
  alias Roki.Repo
  alias Roki.Manga.Library.MangaMark

  @resource_type "manga_mark"

  # When the composer was empty but a GIF was attached, swap in a
  # zero-width-space placeholder so phoenix_kit_comments' validations
  # (max-length only, but the comment shouldn't read as empty in lists)
  # accept the post. Matches production's pattern in
  # Roki.Manga.Library.create_annotation.
  @gif_placeholder "​"

  # ── Item ID generation ───────────────────────────────────────────
  # Random UUID-v4-shaped string. Stable per item, used as the lookup
  # key for update/delete operations. Generated server-side so clients
  # can't collide IDs.
  defp new_item_id, do: Ecto.UUID.generate()

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  # ── Row helpers ──────────────────────────────────────────────────

  @doc """
  Fetch the marks row for a (user, chapter). Returns nil if none yet.
  """
  def get_user_row(user_id, source, slug, chapter) do
    Repo.get_by(MangaMark,
      user_id: user_id,
      source: source,
      slug: slug,
      chapter: chapter
    )
  end

  @doc """
  List every items entry across all users for a chapter, returning a
  flat list of `%{item: ..., user_id: ...}` maps. The caller filters
  by visibility / requesting user.
  """
  def list_chapter_rows(source, slug, chapter) do
    from(m in MangaMark,
      where: m.source == ^source and m.slug == ^slug and m.chapter == ^chapter,
      select: %{user_id: m.user_id, items: m.items}
    )
    |> Repo.all()
  end

  @doc """
  Returns the visible items for a (user, chapter) — the user's own
  items (regardless of visibility) plus other users' public items.
  Each result item has `_user_id` attached so the caller can tell
  who owns it.
  """
  def list_visible_items(source, slug, chapter, requesting_user_id) do
    list_chapter_rows(source, slug, chapter)
    |> Enum.flat_map(fn %{user_id: uid, items: items} ->
      Enum.flat_map(items, fn item ->
        cond do
          uid == requesting_user_id -> [Map.put(item, "_user_id", uid)]
          item["visibility"] == "public" -> [Map.put(item, "_user_id", uid)]
          true -> []
        end
      end)
    end)
  end

  # ── Item CRUD ────────────────────────────────────────────────────

  @doc """
  Append an item to a user's row, creating the row if necessary.

  `partial_item` should NOT include `id`, `created_at`, `updated_at`
  — those are stamped server-side here. Must include `type` and
  `visibility`; any type-specific fields are passed through as-is.

  Returns `{:ok, item}` where `item` is the fully-stamped map that
  was stored, or `{:error, changeset}`.
  """
  def append_item(user_id, source, slug, chapter, partial_item) when is_map(partial_item) do
    now = now_iso()

    item =
      partial_item
      |> Map.merge(%{
        "id" => new_item_id(),
        "created_at" => now,
        "updated_at" => now
      })

    upsert_items(user_id, source, slug, chapter, fn current ->
      current ++ [item]
    end)
    |> case do
      {:ok, _row} -> {:ok, item}
      err -> err
    end
  end

  @doc """
  Update an item by id within a user's row. The `updater` function
  receives the current item map and must return the new item map
  (or `:delete` to remove it). Touches `updated_at` automatically
  unless the updater returns `:delete`.
  """
  def update_item(user_id, source, slug, chapter, item_id, updater)
      when is_function(updater, 1) do
    upsert_items(user_id, source, slug, chapter, fn current ->
      Enum.flat_map(current, fn it ->
        if it["id"] == item_id do
          case updater.(it) do
            :delete -> []
            new_it when is_map(new_it) -> [Map.put(new_it, "updated_at", now_iso())]
          end
        else
          [it]
        end
      end)
    end)
  end

  @doc """
  Remove an item by id.
  """
  def delete_item(user_id, source, slug, chapter, item_id) do
    update_item(user_id, source, slug, chapter, item_id, fn _ -> :delete end)
  end

  # ── Upsert helper ────────────────────────────────────────────────
  # Wraps the "find or insert row, then transform items, then save"
  # pattern. Centralized so concurrency semantics (a row-level lock
  # via the get → update flow on a unique constraint) are consistent.

  defp upsert_items(user_id, source, slug, chapter, transform) when is_function(transform, 1) do
    case get_user_row(user_id, source, slug, chapter) do
      nil ->
        attrs = %{
          user_id: user_id,
          source: source,
          slug: slug,
          chapter: chapter,
          items: transform.([])
        }

        %MangaMark{}
        |> MangaMark.changeset(attrs)
        |> Repo.insert()

      %MangaMark{items: items} = row ->
        row
        |> MangaMark.changeset(%{items: transform.(items)})
        |> Repo.update()
    end
  end

  # ── Etcher-flavored helpers ──────────────────────────────────────
  # Etcher manages its own shape array client-side and emits the
  # full array via `etcher:annotations-changed` whenever anything
  # changes. We mirror that here: keep one item per etcher shape
  # (type "etcher_shape", carrying the etcher payload verbatim in
  # the `etcher` field) and replace the whole set on every event.
  # Non-etcher items in the row (manual annotations / future drawings
  # of other kinds) are preserved untouched.

  @doc """
  Replace the user's `etcher_shape` items for this (source, slug,
  chapter) with the new annotations array Etcher just pushed.

  `annotations` is the list of maps Etcher emits via
  `etcher:annotations-changed`: each has at minimum `uuid`, `kind`,
  `geometry` and optionally `style`, `metadata`.

  Existing items are matched by `etcher.uuid` so we preserve our
  internal item id, `comment_uuid`, `visibility`, and `created_at`
  across updates (the position changed but it's still the same
  annotation). New uuids get a fresh item id and timestamps.
  """
  def replace_etcher_shapes(user_id, source, slug, chapter, annotations, opts \\ [])
      when is_list(annotations) do
    # Defensive: the etcher client has occasionally posted the same
    # annotation more than once in a single `etcher:annotations-changed`
    # payload (last seen: one shape repeated 18× in Sasha's row, which
    # stacked the SVG fills opaquely on every render). Dedup by the
    # shape's own uuid before any further work — the last occurrence
    # wins so the freshest geometry / metadata is what we persist.
    annotations =
      annotations
      |> Enum.reverse()
      |> Enum.uniq_by(& &1["uuid"])
      |> Enum.reverse()

    # Authorization: the etcher canvas hydrates with EVERY user's
    # visible shapes for the chapter — so an annotations-changed
    # payload may include shapes the current user doesn't own. Drop
    # those before we touch the row, so edits / deletes against
    # someone else's shape simply don't persist. (The next hydration
    # restores the foreign shape from its real owner's row.)
    foreign_uuids = other_user_shape_uuids(user_id, source, slug, chapter)

    annotations =
      Enum.reject(annotations, fn ann ->
        MapSet.member?(foreign_uuids, ann["uuid"])
      end)

    # Stamp the row owner's display name onto each shape's metadata.
    # `Map.put_new` preserves whatever the comment-link path already
    # wrote, so commented shapes keep their comment-author header.
    # Marker shapes (no comment_uuid) ride this for their tooltip.
    annotations =
      case Keyword.get(opts, :author_name) do
        nil -> annotations
        name -> Enum.map(annotations, &put_author_name(&1, name))
      end

    # Always stamp `owner_uuid` so the client can gate destructive UI
    # (the etcher tooltip's trash button) for shapes the viewer doesn't
    # own — server-side enforcement above ignores foreign edits, this
    # just keeps the user from being shown a "Delete" they can't use.
    annotations = Enum.map(annotations, &put_owner_uuid(&1, user_id))

    incoming_uuids = MapSet.new(annotations, & &1["uuid"])

    Repo.transaction(fn ->
      # Snapshot the existing etcher items BEFORE the upsert so we can
      # diff for removed shapes and soft-delete their linked comments.
      existing_etcher =
        case get_user_row(user_id, source, slug, chapter) do
          nil -> []
          %{items: items} -> Enum.filter(items, &(&1["type"] == "etcher_shape"))
        end

      orphaned_comment_uuids =
        existing_etcher
        |> Enum.reject(fn it -> MapSet.member?(incoming_uuids, get_in(it, ["etcher", "uuid"])) end)
        |> Enum.map(& &1["comment_uuid"])
        |> Enum.reject(&is_nil/1)

      upsert_result =
        upsert_items(user_id, source, slug, chapter, fn current ->
          non_etcher = Enum.reject(current, &(&1["type"] == "etcher_shape"))

          by_uuid =
            current
            |> Enum.filter(&(&1["type"] == "etcher_shape"))
            |> Enum.into(%{}, fn it -> {get_in(it, ["etcher", "uuid"]), it} end)

          now = now_iso()

          new_items =
            Enum.map(annotations, fn ann ->
              uuid = ann["uuid"]
              base =
                Map.get(by_uuid, uuid) ||
                  %{
                    "id" => new_item_id(),
                    "type" => "etcher_shape",
                    "visibility" => "public",
                    "created_at" => now,
                    "comment_uuid" => nil
                  }

              base
              |> Map.put("etcher", ann)
              |> Map.put("updated_at", now)
            end)

          non_etcher ++ new_items
        end)

      case upsert_result do
        {:ok, row} ->
          Enum.each(orphaned_comment_uuids, fn cuuid ->
            case PhoenixKitComments.get_comment(cuuid) do
              nil -> :ok
              comment -> PhoenixKitComments.delete_comment(comment)
            end
          end)

          row

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Return the list of etcher shape payloads (the maps Etcher itself
  emitted) for a (user, chapter), suitable for stuffing into
  `Fresco.Canvas.put_extension(canvas, "etcher", %{"version" => "1",
  "annotations" => ...})` at controller-render time.

  Comments linked to a shape (via `comment_uuid`) are fetched here
  and folded into the shape's `metadata` so Etcher's default
  tooltip slots show them on hover:

    * `metadata.title`    → author display name (header)
    * `metadata.body`     → comment content as HTML (body)
    * `metadata.subtitle` → comment date (footer)

  Etcher's `DEFAULT_TOOLTIP_SLOTS` reads these three keys, so the
  hover bubble works without registering any custom slot functions
  on the client side.
  """
  def list_etcher_shape_payloads(user_id, source, slug, chapter) do
    case get_user_row(user_id, source, slug, chapter) do
      nil -> []
      %{items: items} -> build_etcher_payloads(items)
    end
  end

  @doc """
  Same as `list_etcher_shape_payloads/4` but across ALL users' rows for
  the chapter, with visibility filtering: the requesting user sees
  their own shapes (any visibility) plus other users' shapes marked
  `visibility: "public"`. Pass `requesting_user_id: nil` for anonymous
  callers — those see only the public shapes.

  Used by the reader render path so a chapter shows everyone's
  public annotations, not just the viewer's own.
  """
  def list_visible_etcher_shape_payloads(source, slug, chapter, requesting_user_id) do
    rows = list_chapter_rows(source, slug, chapter)

    # Batch lookup the row owners' display names so build_etcher_payloads
    # can fall back to them for shapes whose saved metadata.author_name
    # is empty (e.g. marker strokes drawn before the author stamp
    # landed — their tooltip would otherwise read "marker").
    owner_uuids = rows |> Enum.map(& &1.user_id) |> Enum.uniq()
    usernames_by_uuid = fetch_usernames(owner_uuids)

    rows
    |> Enum.flat_map(fn %{user_id: uid, items: items} ->
      # Tag each visible item with whether the *requesting* user owns
      # it — `build_etcher_payloads/1` lifts that into the
      # `readonly` top-level field etcher 0.6.1+ uses to gate edit /
      # move / delete UI. Render-only flag: never echoed back on save.
      foreign? = uid != requesting_user_id
      author_fallback = Map.get(usernames_by_uuid, uid)

      items
      |> Enum.filter(fn item ->
        item["type"] == "etcher_shape" and
          (uid == requesting_user_id or item["visibility"] == "public")
      end)
      |> Enum.map(fn item ->
        item
        |> Map.put(:__readonly__, foreign?)
        |> Map.put(:__author_fallback__, author_fallback)
      end)
    end)
    |> build_etcher_payloads()
  end

  # Shared fold: take a list of etcher_shape items (already filtered),
  # batch-fetch the linked comments, and produce the Etcher-ready
  # payload (annotation map with metadata.title/body/subtitle slotted
  # in from the comment).
  defp build_etcher_payloads(items) do
    etcher_items = Enum.filter(items, &(&1["type"] == "etcher_shape"))
    comment_uuids =
      etcher_items |> Enum.map(& &1["comment_uuid"]) |> Enum.reject(&is_nil/1)

    comments_by_uuid = fetch_comments_with_authors(comment_uuids)

    Enum.map(etcher_items, fn it ->
      ann = it["etcher"] || %{}
      metadata = Map.get(ann, "metadata") || %{}

      metadata =
        case it["comment_uuid"] do
          nil ->
            metadata

          uuid ->
            comment = Map.get(comments_by_uuid, uuid)
            fold_comment_into_metadata(metadata, uuid, comment)
        end

      metadata =
        case it["resource_uuid"] do
          nil -> metadata
          rid -> Map.put(metadata, "resource_uuid", rid)
        end

      # Fall back to the row owner's username when no metadata.author_name
      # is set. Covers marker strokes saved before the author stamp
      # existed and any other shape kind whose save path didn't pass an
      # :author_name option.
      metadata =
        case Map.get(metadata, "author_name") do
          name when is_binary(name) and name != "" ->
            metadata

          _ ->
            case it[:__author_fallback__] do
              fallback when is_binary(fallback) and fallback != "" ->
                Map.put(metadata, "author_name", fallback)

              _ ->
                metadata
            end
        end

      # Same idea for the tooltip footer date: commented shapes get
      # `subtitle` from `fold_comment_into_metadata/3` (the comment's
      # `inserted_at`). Non-commented shapes (markers in particular)
      # fall back to the item's own `created_at` so the tooltip reads
      # "<author> · <date>" instead of just the author.
      metadata =
        case Map.get(metadata, "subtitle") do
          subtitle when is_binary(subtitle) and subtitle != "" ->
            metadata

          _ ->
            case format_iso_date(it["created_at"]) do
              "" -> metadata
              date -> Map.put(metadata, "subtitle", date)
            end
        end

      ann
      |> Map.put("metadata", metadata)
      |> maybe_put_readonly(it[:__readonly__])
    end)
  end

  defp maybe_put_readonly(ann, true), do: Map.put(ann, "readonly", true)
  defp maybe_put_readonly(ann, _), do: ann

  # Batch-fetch comment content + author info for a list of uuids.
  # Returns `%{uuid => %{content, author, inserted_at}}`.
  defp fetch_comments_with_authors([]), do: %{}

  defp fetch_comments_with_authors(uuids) do
    import Ecto.Query

    # The schema-less query (`"phoenix_kit_comments"` as a string) can't
    # infer that `c.uuid` is `Ecto.UUID`, so the string-form uuids
    # parameter fails to encode as a `uuid[]` array. Cast both sides.
    rows =
      from(c in "phoenix_kit_comments",
        join: u in "phoenix_kit_users",
        on: u.uuid == c.user_uuid,
        where:
          c.uuid in type(^uuids, {:array, Ecto.UUID}) and c.status == "published",
        select: %{
          uuid: type(c.uuid, Ecto.UUID),
          content: c.content,
          username: u.username,
          first_name: u.first_name,
          last_name: u.last_name,
          inserted_at: c.inserted_at
        }
      )
      |> Repo.all()

    Map.new(rows, fn row -> {row.uuid, row} end)
  end

  # Batch-fetch usernames (with first_name fallback) for a list of user
  # uuids. Returns `%{uuid => display_name}` — same name-pick order as
  # `fold_comment_into_metadata/3`'s `display_name/1` so comment-author
  # and row-owner labels stay consistent.
  defp fetch_usernames([]), do: %{}

  defp fetch_usernames(user_uuids) do
    import Ecto.Query

    from(u in "phoenix_kit_users",
      where: u.uuid in type(^user_uuids, {:array, Ecto.UUID}),
      select: %{
        uuid: type(u.uuid, Ecto.UUID),
        username: u.username,
        first_name: u.first_name
      }
    )
    |> Repo.all()
    |> Map.new(fn row ->
      name =
        cond do
          is_binary(row.username) and row.username != "" -> row.username
          is_binary(row.first_name) and row.first_name != "" -> row.first_name
          true -> "Anonymous"
        end

      {row.uuid, name}
    end)
  end

  defp fold_comment_into_metadata(metadata, comment_uuid, nil) do
    Map.put(metadata, "comment_uuid", comment_uuid)
  end

  defp fold_comment_into_metadata(metadata, comment_uuid, comment) do
    # Tooltip layout: no header (a custom Etcher tooltipSlot returns ""
    # for the header on the client side so the default shape-kind
    # fallback doesn't show). Body carries the author's display name
    # AND the comment content together; footer is the date.
    metadata
    |> Map.put("comment_uuid", comment_uuid)
    |> Map.put("author_name", display_name(comment))
    |> Map.put("body", comment_body_html(comment))
    |> Map.put("subtitle", format_date(comment.inserted_at))
  end

  defp display_name(%{username: u}) when is_binary(u) and u != "", do: u

  defp display_name(%{first_name: f}) when is_binary(f) and f != "", do: f

  defp display_name(_), do: "Anonymous"

  defp comment_body_html(%{content: content}) when is_binary(content) do
    # Etcher's body slot takes RAW HTML (the consumer owns escaping).
    # We escape and convert newlines to <br> so the comment renders
    # as plaintext in the tooltip.
    content
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
    |> String.replace("\n", "<br>")
  end

  defp comment_body_html(_), do: ""

  defp format_date(%NaiveDateTime{} = dt) do
    Calendar.strftime(dt, "%b %-d, %Y")
  end

  defp format_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %-d, %Y")
  end

  defp format_date(_), do: ""

  # Parse an ISO8601 string (items[].created_at is stored as one) into
  # a DateTime / NaiveDateTime and reuse `format_date/1`. Returns "" for
  # nil / unparseable input so callers can branch with `case`.
  defp format_iso_date(iso) when is_binary(iso) do
    cond do
      match?({:ok, _, _}, DateTime.from_iso8601(iso)) ->
        {:ok, dt, _} = DateTime.from_iso8601(iso)
        format_date(dt)

      match?({:ok, _}, NaiveDateTime.from_iso8601(iso)) ->
        {:ok, dt} = NaiveDateTime.from_iso8601(iso)
        format_date(dt)

      true ->
        ""
    end
  end

  defp format_iso_date(_), do: ""

  defp user_field(user, key) when is_map(user), do: Map.get(user, key)
  defp user_field(_, _), do: nil

  # ── Annotation-flavored helpers ──────────────────────────────────
  # Wraps `append_item` + phoenix_kit_comment create in one
  # transaction so we never end up with an item pointing at a
  # nonexistent comment (or a comment with no item).

  @doc """
  Create a new annotation: phoenix_kit_comment row + an `annotation`
  item appended to the user's chapter marks row.

  `attrs` must include: `:title`, `:content`, `:color`, `:visibility`,
  `:anchor` (map with at least `image_idx` or `page`, and x/y/w/h_pct).
  May include `:giphy` (passed through to the comment metadata).

  Returns `{:ok, item}` (with `comment_uuid` baked in) or
  `{:error, reason}`.
  """
  def create_annotation(user, source, slug, chapter, attrs) when is_map(attrs) do
    anchor = Map.fetch!(attrs, :anchor)
    title = Map.fetch!(attrs, :title)
    content = Map.fetch!(attrs, :content)
    color = Map.get(attrs, :color, "blue")
    visibility = Map.get(attrs, :visibility, "public")

    # phoenix_kit_comments requires a UUID for resource_uuid; generate
    # one per annotation. Source/slug/chapter back-refs live in metadata.
    resource_id = Ecto.UUID.generate()

    metadata =
      %{
        "source" => source,
        "slug" => slug,
        "chapter" => chapter,
        "title" => title,
        "anchor" => stringify_keys(anchor)
      }
      |> maybe_put_giphy(attrs[:giphy])

    Repo.transaction(fn ->
      case PhoenixKitComments.create_comment(
             @resource_type,
             resource_id,
             user.uuid,
             %{content: content, metadata: metadata}
           ) do
        {:ok, comment} ->
          item =
            %{
              "type" => "annotation",
              "visibility" => visibility,
              "comment_uuid" => comment.uuid,
              "title" => title,
              "color" => color,
              "anchor" => stringify_keys(anchor)
            }

          case append_item(user.uuid, source, slug, chapter, item) do
            {:ok, stored} -> stored
            {:error, changeset} -> Repo.rollback({:items, changeset})
          end

        {:error, reason} ->
          Repo.rollback({:comment, reason})
      end
    end)
  end

  @doc """
  Attach a phoenix_kit_comment to an existing etcher_shape item. The
  etcher shape itself already exists in the items array (Etcher's
  annotations-changed event created it); this just creates the
  comment and stamps the item's `comment_uuid`.

  Returns `{:ok, %{item_id: id, comment_uuid: uuid}}` or `{:error, reason}`.
  """
  def attach_comment_to_etcher_shape(user, source, slug, chapter, shape_uuid, attrs) do
    # phoenix_kit_comments expects a UUID for `resource_uuid`. We
    # generate one per comment (mirrors production's manga_annotation
    # pattern) and store back-references in `metadata` so it's easy
    # to look up the chapter context from the comment.
    resource_id = Ecto.UUID.generate()

    # Resolve the shape's page from the existing items array so the
    # comment metadata can carry it. Without this the `/slug/comments`
    # link can't navigate to the page when the shape gets deleted
    # later (the link only finds page via the live shape's image_id).
    page = lookup_shape_page(user.uuid, source, slug, chapter, shape_uuid)

    metadata =
      %{
        "source" => source,
        "slug" => slug,
        "chapter" => chapter,
        "title" => Map.get(attrs, :title, ""),
        "etcher_shape_uuid" => shape_uuid
      }
      |> maybe_put("page", page)
      |> maybe_put_giphy(attrs[:giphy])

    visibility = Map.get(attrs, :visibility, "public")
    raw_content = Map.fetch!(attrs, :content)
    has_gif? = is_map(attrs[:giphy])

    content =
      if String.trim(raw_content || "") == "" and has_gif?,
        do: @gif_placeholder,
        else: raw_content

    Repo.transaction(fn ->
      case PhoenixKitComments.create_comment(
             @resource_type,
             resource_id,
             user.uuid,
             %{content: content, metadata: metadata}
           ) do
        {:ok, comment} ->
          result =
            upsert_items(user.uuid, source, slug, chapter, fn current ->
              Enum.map(current, fn it ->
                if it["type"] == "etcher_shape" and
                     get_in(it, ["etcher", "uuid"]) == shape_uuid do
                  it
                  |> Map.put("comment_uuid", comment.uuid)
                  # Store the comment's resource_uuid so the comment-
                  # thread modal (PhoenixKitComments CommentsComponent)
                  # can fetch all comments + replies in this thread.
                  # Production passes resource_uuid (not comment_uuid)
                  # to openCommentModal; we follow the same convention.
                  |> Map.put("resource_uuid", resource_id)
                  |> Map.put("visibility", visibility)
                  |> Map.put("updated_at", now_iso())
                else
                  it
                end
              end)
            end)

          case result do
            {:ok, _row} ->
              # Build the same metadata patch the hydration path
              # would produce on a fresh load, so the JS side can
              # call `layer.patchShape/2` with it and the tooltip
              # shows the comment immediately — no reload needed.
              tooltip_metadata =
                fold_comment_into_metadata(%{}, comment.uuid, %{
                  content: content,
                  username: user_field(user, :username),
                  first_name: user_field(user, :first_name),
                  inserted_at: comment.inserted_at
                })
                |> Map.put("resource_uuid", resource_id)

              %{
                item_id: shape_uuid,
                comment_uuid: comment.uuid,
                resource_uuid: resource_id,
                tooltip_metadata: tooltip_metadata
              }

            {:error, changeset} ->
              Repo.rollback({:items, changeset})
          end

        {:error, reason} ->
          Repo.rollback({:comment, reason})
      end
    end)
  end


  @doc """
  Stamp an etcher shape with a freshly-allocated `resource_uuid` so the
  PhoenixKit CommentsComponent has a thread key to query against from
  the moment the shape is drawn — before any comment exists. Idempotent:
  if the shape already carries a `resource_uuid`, returns the existing
  one untouched. Returns `{:ok, resource_uuid}` (whichever value the
  item now holds) or `{:error, :not_found}`.
  """
  def preallocate_shape_thread(user_id, source, slug, chapter, shape_uuid, new_resource_uuid) do
    case get_user_row(user_id, source, slug, chapter) do
      nil ->
        {:error, :not_found}

      %{items: items} ->
        existing =
          items
          |> Enum.find(fn it ->
            it["type"] == "etcher_shape" and get_in(it, ["etcher", "uuid"]) == shape_uuid
          end)
          |> case do
            nil -> nil
            it -> it["resource_uuid"]
          end

        cond do
          is_binary(existing) and existing != "" ->
            {:ok, existing}

          true ->
            case upsert_items(user_id, source, slug, chapter, fn current ->
                   Enum.map(current, fn it ->
                     if it["type"] == "etcher_shape" and
                          get_in(it, ["etcher", "uuid"]) == shape_uuid do
                       it
                       |> Map.put("resource_uuid", new_resource_uuid)
                       |> Map.put_new("visibility", "public")
                       |> Map.put("updated_at", now_iso())
                     else
                       it
                     end
                   end)
                 end) do
              {:ok, _} -> {:ok, new_resource_uuid}
              other -> other
            end
        end
    end
  end

  @doc """
  After the CommentsComponent creates a comment for `resource_uuid`,
  link the comment back to the etcher shape: set `comment_uuid` on the
  matching shape item if it isn't already set (i.e. this was the first
  comment in the thread). No-op when the comment was a reply on a shape
  whose `comment_uuid` is already populated.

  Returns `{:ok, %{shape_uuid, comment_uuid, resource_uuid,
  tooltip_metadata}}` when the shape was newly linked (caller pushes a
  layer.patchShape so the tooltip / pin click work without a refresh)
  and `{:ok, :no_change}` for replies on already-linked shapes (or no
  matching shape).

  ## Strip-mode opts

  In strip mode the shape's `image_idx` can fall into an auto-appended
  chapter that isn't the URL chapter (the user reads forward across
  chapter boundaries without a page reload). The shape ends up in that
  other chapter's `manga_mark.items` row via `replace_etcher_shapes`'s
  per-chapter routing — so a URL-chapter-only lookup by
  `resource_uuid` finds nothing, returns `:no_change`, and the shape
  stays unlinked to its comment even after refresh.

    * `:etcher_shape_uuid` — when present, also matches shapes by their
      etcher uuid (not just `resource_uuid`), so a freshly-drawn shape
      whose `resource_uuid` never made it onto the persisted item still
      gets stamped on first-comment-post.
    * `:loaded_chapters` — list of `%{"chapter" => ..., ...}` maps from
      the strip's chapter snapshot; searched in order until a row
      containing the shape turns up.
  """
  def link_first_comment_to_shape(user_id, source, slug, chapter, resource_uuid, opts \\ []) do
    import Ecto.Query

    etcher_shape_uuid = Keyword.get(opts, :etcher_shape_uuid)
    loaded_chapters = Keyword.get(opts, :loaded_chapters)

    earliest =
      from(c in "phoenix_kit_comments",
        join: u in "phoenix_kit_users",
        on: u.uuid == c.user_uuid,
        where:
          c.resource_type == "manga_mark" and
            c.resource_uuid == type(^resource_uuid, Ecto.UUID),
        order_by: [asc: c.inserted_at],
        limit: 1,
        select: %{
          uuid: c.uuid,
          content: c.content,
          inserted_at: c.inserted_at,
          username: u.username,
          first_name: u.first_name
        }
      )
      |> Roki.Repo.one()

    case earliest do
      nil ->
        {:ok, :no_change}

      comment ->
        comment_uuid = elem(Ecto.UUID.cast(comment.uuid), 1)

        candidates =
          chapters_to_search(chapter, loaded_chapters)

        case Repo.transaction(fn ->
               find_and_link_shape(
                 user_id,
                 source,
                 slug,
                 candidates,
                 resource_uuid,
                 etcher_shape_uuid,
                 comment_uuid
               )
             end) do
          {:ok, {:linked, shape_uuid}} when is_binary(shape_uuid) ->
            tooltip_metadata =
              fold_comment_into_metadata(%{}, comment_uuid, %{
                content: comment.content,
                username: comment.username,
                first_name: comment.first_name,
                inserted_at: comment.inserted_at
              })
              |> Map.put("resource_uuid", resource_uuid)

            {:ok,
             %{
               shape_uuid: shape_uuid,
               comment_uuid: comment_uuid,
               resource_uuid: resource_uuid,
               tooltip_metadata: tooltip_metadata
             }}

          _ ->
            {:ok, :no_change}
        end
    end
  end

  # URL chapter always searched first (paged-mode happy path: the shape
  # IS in that row and the prior preallocate stamped resource_uuid on
  # it). Then any loaded chapter — covers strip mode where the shape's
  # image_idx routed the save into a different row.
  defp chapters_to_search(chapter, loaded_chapters) when is_list(loaded_chapters) do
    loaded_names =
      loaded_chapters
      |> Enum.map(& &1["chapter"])
      |> Enum.reject(&is_nil/1)

    [chapter | loaded_names]
    |> Enum.uniq()
  end

  defp chapters_to_search(chapter, _), do: [chapter]

  defp find_and_link_shape(user_id, source, slug, chapters, resource_uuid, etcher_shape_uuid, comment_uuid) do
    Enum.reduce_while(chapters, {:no_match, nil}, fn ch, acc ->
      case get_user_row(user_id, source, slug, ch) do
        nil ->
          {:cont, acc}

        %{items: items} ->
          match =
            Enum.find(items, fn it ->
              it["type"] == "etcher_shape" and
                (it["resource_uuid"] == resource_uuid or
                   (is_binary(etcher_shape_uuid) and
                      get_in(it, ["etcher", "uuid"]) == etcher_shape_uuid))
            end)

          case match do
            nil ->
              {:cont, acc}

            %{"comment_uuid" => existing} = m when is_binary(existing) and existing != "" ->
              {:halt, {:already_linked, get_in(m, ["etcher", "uuid"])}}

            m ->
              {:ok, _} =
                upsert_items(user_id, source, slug, ch, fn current ->
                  Enum.map(current, fn it ->
                    if it["type"] == "etcher_shape" and
                         get_in(it, ["etcher", "uuid"]) == get_in(m, ["etcher", "uuid"]) do
                      it
                      |> Map.put("resource_uuid", resource_uuid)
                      |> Map.put("comment_uuid", comment_uuid)
                      |> Map.put("updated_at", now_iso())
                    else
                      it
                    end
                  end)
                end)

              {:halt, {:linked, get_in(m, ["etcher", "uuid"])}}
          end
      end
    end)
  end

  @doc """
  Delete an annotation by item_id — removes the item AND the underlying
  phoenix_kit_comment. Both happen in a single transaction.
  """
  def delete_annotation(user, source, slug, chapter, item_id) do
    Repo.transaction(fn ->
      with %MangaMark{items: items} <- get_user_row(user.uuid, source, slug, chapter),
           %{"type" => "annotation", "comment_uuid" => comment_uuid} <-
             Enum.find(items, &(&1["id"] == item_id)) do
        {:ok, _} = delete_item(user.uuid, source, slug, chapter, item_id)

        case PhoenixKitComments.get_comment(comment_uuid) do
          nil -> :ok
          comment -> PhoenixKitComments.delete_comment(comment)
        end

        :ok
      else
        _ -> Repo.rollback(:not_found)
      end
    end)
  end

  # ── Internals ────────────────────────────────────────────────────

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      {if(is_atom(k), do: Atom.to_string(k), else: k), stringify_keys(v)}
    end)
  end

  defp stringify_keys(v), do: v

  defp maybe_put_giphy(meta, nil), do: meta
  defp maybe_put_giphy(meta, giphy), do: Map.put(meta, "giphy", giphy)

  defp put_author_name(ann, name) when is_binary(name) and name != "" do
    metadata = Map.get(ann, "metadata") || %{}
    Map.put(ann, "metadata", Map.put_new(metadata, "author_name", name))
  end

  defp put_author_name(ann, _), do: ann

  defp put_owner_uuid(ann, owner_uuid) when is_binary(owner_uuid) do
    owner = case Ecto.UUID.cast(owner_uuid) do
      {:ok, s} -> s
      _ -> owner_uuid
    end

    metadata = Map.get(ann, "metadata") || %{}
    Map.put(ann, "metadata", Map.put(metadata, "owner_uuid", owner))
  end

  defp put_owner_uuid(ann, _), do: ann

  # Set of etcher shape uuids that belong to OTHER users' rows for
  # this (source, slug, chapter). Drives the authorization filter in
  # `replace_etcher_shapes/6` — only the row owner can persist
  # changes to their shapes.
  defp other_user_shape_uuids(user_id, source, slug, chapter) do
    list_chapter_rows(source, slug, chapter)
    |> Enum.reject(&(&1.user_id == user_id))
    |> Enum.flat_map(fn %{items: items} -> items end)
    |> Enum.filter(&(&1["type"] == "etcher_shape"))
    |> Enum.map(&get_in(&1, ["etcher", "uuid"]))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Look up an etcher shape's natural page (1-based) by parsing its
  # `image_id` (the canvas places each page as "page-N"). Returns nil
  # when the shape isn't in the row or has no image_id — caller's
  # responsibility to handle gracefully.
  def lookup_shape_page(user_id, source, slug, chapter, shape_uuid) do
    case get_user_row(user_id, source, slug, chapter) do
      nil ->
        nil

      %{items: items} ->
        item =
          Enum.find(items, fn it ->
            it["type"] == "etcher_shape" and
              (it["etcher"]["uuid"] == shape_uuid or it["etcher"]["id"] == shape_uuid)
          end)

        case item && get_in(item, ["etcher", "image_id"]) do
          "page-" <> n -> case Integer.parse(n) do {p, ""} -> p; _ -> nil end
          _ -> nil
        end
    end
  end
end
