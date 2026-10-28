defmodule RokiWeb.Live.EtcherHostLive do
  @moduledoc """
  Tiny embedded LiveView that hosts:

    * `<Etcher.layer>` — the annotation overlay attached to the
      named Fresco canvas, with persistence and shape-drawn events
      flowing back to manga_marks.

    * `CommentBridge` — relays the `open-comment-modal` /
      `annotation-updated` / `close-comment-modal` window events
      (dispatched by `app.js`'s `window.openCommentModal`) into
      LiveView events.

    * The comment-thread modal — renders
      `PhoenixKitComments.Web.CommentsComponent` when an
      annotation is clicked. Matches the production
      `MangaReaderLive` modal layout so the comment UX is
      identical.

  The reader pages themselves (`show_fresco`, `show_fresco_strip`)
  are controller-rendered; this LiveView is embedded into them
  via `live_render/3` so all the LiveView-only plumbing
  (pushEventTo, comment-modal LiveComponent, etc.) actually
  works on those pages.
  """

  use RokiWeb, :live_view

  alias Roki.Manga.Library.Marks

  @impl true
  def mount(_params, session, socket) do
    # Can't use PhoenixKit's on_mount helpers here — they attach a
    # `:handle_params` hook for URL/locale tracking, which requires a
    # LiveView mounted via the `live/3` router macro. We're mounted
    # via `live_render/3` from a controller, so we load the current
    # user manually from the forwarded session token instead.
    current_user = load_current_user_from_session(session)

    {:ok,
     assign(socket,
       fresco_id: session["fresco_id"],
       source: session["source"],
       slug: session["slug"],
       chapter: session["chapter"],
       user_id: session["user_id"],
       current_user: current_user,
       # Seed the etcher toolbar's editable color palette from the
       # user's saved swatches (see `handle_event("etcher:colors-changed",
       # ...)` for the writeback). `nil` for signed-out / fresh users
       # → etcher falls back to its default preset palette.
       user_colors: read_user_colors(current_user),
       # Same idea for the global stroke defaults (width / opacity /
       # dash) that new strokes pick up — persisted via
       # `etcher:line-params-changed`. `nil` → etcher's built-in
       # defaults (width 2, opacity 1, dash solid).
       user_line_params: read_user_line_params(current_user),
       # Multi-chapter strip readers push their loaded chapter ranges
       # here via the CommentBridge `etcher-loaded-chapters` event so
       # `etcher:annotations-changed` can fan out one save per chapter
       # (each with image_idx rebased to chapter-local). Paged readers
       # leave this nil and save all annotations under the URL chapter.
       loaded_chapters: nil,
       comment_modal_open: false,
       comment_resource_uuid: nil,
       comment_chapter: nil,
       comment_page: nil,
       # Hidden-input payload merged into comment.metadata via the
       # CommentsComponent's `form_extras` slot — gives every comment
       # (initial + replies) the etcher manga/chapter/shape context the
       # /manga/comments listing needs.
       composer_metadata: nil,
       # Slim mode used right after a fresh shape is drawn — strips the
       # modal title bar + thread list and shrinks the box, so the user
       # gets just a composer. We close on first post and leave the full
       # thread modal for subsequent shape clicks.
       composer_only_mode?: false
     )}
  end

  defp load_current_user_from_session(%{"user_token" => token}) when is_binary(token) do
    user = PhoenixKit.Users.Auth.get_user_by_session_token(token)
    PhoenixKit.Users.Auth.ensure_active_user(user)
  rescue
    _ -> nil
  end

  defp load_current_user_from_session(_), do: nil

  # Read the persisted etcher color palette off the user's custom
  # fields, returning `nil` when there's nothing saved (or no user) so
  # `<Etcher.layer :colors={nil}>` falls back to the preset palette.
  defp read_user_colors(%{custom_fields: cf}) when is_map(cf) do
    case Map.get(cf, "etcher_colors") do
      list when is_list(list) and list != [] -> list
      _ -> nil
    end
  end

  defp read_user_colors(_), do: nil

  # Read the persisted global stroke defaults off the user's custom
  # fields. Etcher 0.6.5+ accepts a map with any subset of "width" /
  # "opacity" / "dash" — missing keys fall back to built-in defaults
  # on the etcher side, so an empty map is the same as nil.
  defp read_user_line_params(%{custom_fields: cf}) when is_map(cf) do
    case Map.get(cf, "etcher_line_params") do
      %{} = lp when map_size(lp) > 0 -> lp
      _ -> nil
    end
  end

  defp read_user_line_params(_), do: nil

  # Pick a display label for the etcher tooltip's header slot. Mirrors
  # the order Marks.fold_comment_into_metadata/3's `display_name` uses
  # (username > first_name > "Anonymous") so non-comment shapes match
  # commented ones.
  defp author_name(%{username: u}) when is_binary(u) and u != "", do: u
  defp author_name(%{first_name: f}) when is_binary(f) and f != "", do: f
  defp author_name(_), do: "Anonymous"

  @impl true
  def render(assigns) do
    ~H"""
    <div id={"etcher-host-#{@fresco_id}"}>
      <Etcher.layer fresco_id={@fresco_id} colors={@user_colors} line_params={@user_line_params} />

      <%!-- CommentBridge relays window CustomEvents (dispatched by
           app.js's window.openCommentModal helper, and by our
           composer/click handlers) into LiveView events here. --%>
      <div id={"comment-bridge-#{@fresco_id}"} phx-hook="CommentBridge"></div>

      <%= if @comment_modal_open and @current_user do %>
        <div
          id={"comment-modal-root-#{@fresco_id}"}
          phx-hook="CommentModalScrollLock"
          class={[
            "fixed inset-0 z-[10000] flex justify-center",
            if(@composer_only_mode?,
              do: "items-start pt-6 sm:pt-12",
              else: "items-end sm:items-center"
            )
          ]}
        >
          <div
            id="comment-modal-backdrop"
            class="fixed inset-0 bg-black/50"
            phx-click="close_comment_modal"
          >
          </div>
          <div
            id={"comment-modal-scroll-#{@fresco_id}"}
            phx-hook="CommentModalScroll"
            class={[
              "relative z-10 w-full bg-base-100 shadow-2xl",
              if(@composer_only_mode?,
                do: "sm:max-w-md rounded-2xl etcher-composer-only overflow-visible",
                else: "sm:max-w-lg max-h-[85vh] rounded-t-2xl sm:rounded-2xl overflow-y-auto"
              )
            ]}
            style="overscroll-behavior: contain; touch-action: auto;"
          >
            <%= unless @composer_only_mode? do %>
              <div class="sticky top-0 z-10 flex items-center justify-between px-4 py-3 bg-base-100 border-b border-base-300 rounded-t-2xl">
                <h3 class="font-bold text-lg">Comments</h3>
                <button phx-click="close_comment_modal" class="btn btn-ghost btn-sm btn-circle">✕</button>
              </div>
            <% end %>
            <%!-- Minimal float-x close button when chrome is stripped —
                 sits over the top-right corner of the slim composer. --%>
            <button
              :if={@composer_only_mode?}
              phx-click="close_comment_modal"
              class="absolute top-1 right-1 z-20 btn btn-ghost btn-sm btn-circle"
            >✕</button>
            <%!-- In composer-only mode the CommentsComponent still
                 renders its "No comments yet" empty state. Hide it so
                 we land on just the composer (Leaf editor + paperclip +
                 GIF + audio). show_title=false already drops the
                 component's own h2.

                 The dep also wraps its card body in `overflow-hidden`,
                 which clips the absolutely-positioned attach menu and
                 GIF picker. Force `overflow: visible` on the card chain
                 so the dropdowns can extend downward into the empty
                 viewport below our slim composer modal. --%>
            <style :if={@composer_only_mode?}>
              .etcher-composer-only .text-center.py-8 { display: none !important; }
              .etcher-composer-only .card,
              .etcher-composer-only .card-body { overflow: visible !important; }
            </style>
            <%!-- iOS Safari auto-zooms into any input < 16px on focus
                 and won't zoom back, leaving the page at a broken
                 scale. Force 16px on the Leaf contenteditable + the
                 textarea fallback (unconditional — 16px is fine on
                 desktop too). Belt-and-braces with text-size-adjust so
                 mobile WebKit doesn't second-guess the value. --%>
            <style>
              [data-editor-visual],
              .content-editor-visual,
              .content-editor-visual [data-leaf-source],
              textarea[name="comment"] {
                font-size: 16px !important;
                -webkit-text-size-adjust: 100% !important;
                text-size-adjust: 100% !important;
              }
            </style>
            <div class={if @composer_only_mode?, do: "p-3", else: "p-4"}>
              <.live_component
                module={PhoenixKitComments.Web.CommentsComponent}
                id={"comments-#{@comment_resource_uuid}"}
                resource_type="manga_mark"
                resource_uuid={@comment_resource_uuid}
                current_user={@current_user}
                title="Annotation Comments"
                show_title={false}
                composer_position={:bottom}
                composer_open_at={if @composer_only_mode?, do: :bottom, else: nil}
              >
                <:form_extras :if={@composer_metadata}>
                  <input
                    :if={@composer_metadata["source"]}
                    type="hidden"
                    name="metadata[source]"
                    value={@composer_metadata["source"]}
                  />
                  <input
                    :if={@composer_metadata["slug"]}
                    type="hidden"
                    name="metadata[slug]"
                    value={@composer_metadata["slug"]}
                  />
                  <input
                    :if={@composer_metadata["chapter"]}
                    type="hidden"
                    name="metadata[chapter]"
                    value={@composer_metadata["chapter"]}
                  />
                  <input
                    :if={@composer_metadata["etcher_shape_uuid"]}
                    type="hidden"
                    name="metadata[etcher_shape_uuid]"
                    value={@composer_metadata["etcher_shape_uuid"]}
                  />
                  <input
                    :if={@composer_metadata["page"]}
                    type="hidden"
                    name="metadata[page]"
                    value={@composer_metadata["page"]}
                  />
                  <input
                    :if={@composer_metadata["title"]}
                    type="hidden"
                    name="metadata[title]"
                    value={@composer_metadata["title"]}
                  />
                </:form_extras>
              </.live_component>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  @impl true
  def handle_event("set_loaded_chapters", %{"chapters" => chapters}, socket)
      when is_list(chapters) do
    {:noreply, assign(socket, :loaded_chapters, chapters)}
  end

  # The paged reader fires this when it does an in-place chapter
  # swap (Fresco 0.7's `handle.setSources` keeps the page session
  # alive, so we never get a fresh `mount/3`). We need to keep our
  # `chapter` assign in sync so `etcher:annotations-changed` writes
  # the right row, and so the composer modal stamps the right
  # source/slug/chapter on new comments.
  @impl true
  def handle_event("set_chapter", %{"chapter" => chapter} = params, socket) do
    {:noreply,
     assign(socket,
       chapter: chapter,
       source: params["source"] || socket.assigns.source,
       slug: params["slug"] || socket.assigns.slug
     )}
  end

  @impl true
  def handle_event("etcher:annotations-changed", %{"annotations" => annotations}, socket) do
    %{user_id: user_id, source: source, slug: slug, chapter: url_chapter} = socket.assigns
    loaded = socket.assigns[:loaded_chapters]
    # Author name travels with each save so marker-tool shapes (which
    # don't open the comment composer) still get a one-line tooltip
    # ("Sasha") via the custom Etcher header slot. Map.put_new in
    # `replace_etcher_shapes` preserves the comment author when a
    # commented shape later gets re-saved.
    save_opts = [author_name: author_name(socket.assigns[:current_user])]

    cond do
      is_nil(user_id) ->
        :noop

      is_list(loaded) and loaded != [] and all_known_idx?(annotations, loaded) ->
        # Strip mode + every annotation falls in a known chapter range:
        # split the emit per chapter and rebase image_idx to chapter-
        # local. Falls through to the legacy single-chapter save below
        # if any annotation lies outside every known range — covers
        # the case where the JS chapter snapshot is stale.
        grouped = group_annotations_by_chapter(annotations, loaded)

        Enum.each(loaded, fn ch ->
          chapter_anns = Map.get(grouped, ch["chapter"], [])

          Marks.replace_etcher_shapes(
            user_id,
            source,
            slug,
            ch["chapter"],
            chapter_anns,
            save_opts
          )
        end)

      true ->
        # Paged mode, or stale/missing chapter map: save everything
        # under the URL chapter, same behavior as before multi-chapter
        # routing was introduced.
        Marks.replace_etcher_shapes(user_id, source, slug, url_chapter, annotations, save_opts)
    end

    {:noreply, socket}
  end

  # Persist edits to the toolbar's color slots onto the signed-in
  # user's `custom_fields["etcher_colors"]` so the palette follows
  # them across pages / devices. Etcher dispatches this both on the
  # LiveView socket (here) and as a bubbling DOM CustomEvent — we
  # only need the socket path for storage; the layer keeps its own
  # local state in sync.
  @impl true
  def handle_event("etcher:colors-changed", %{"colors" => colors}, socket) when is_list(colors) do
    case socket.assigns[:current_user] do
      %PhoenixKit.Users.Auth.User{} = user ->
        existing = user.custom_fields || %{}
        merged = Map.put(existing, "etcher_colors", colors)

        case PhoenixKit.Users.Auth.update_user_custom_fields(user, merged) do
          {:ok, updated_user} ->
            {:noreply, assign(socket, current_user: updated_user, user_colors: colors)}

          {:error, _} ->
            {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("etcher:colors-changed", _payload, socket), do: {:noreply, socket}

  # Mirror of the colors handler for the global stroke defaults.
  # Fires only when the user edits the Parameters popup with no
  # shape selected (per-shape style edits flow through
  # `etcher:annotations-changed` unchanged).
  @impl true
  def handle_event("etcher:line-params-changed", %{"line_params" => lp}, socket)
      when is_map(lp) do
    case socket.assigns[:current_user] do
      %PhoenixKit.Users.Auth.User{} = user ->
        existing = user.custom_fields || %{}
        merged = Map.put(existing, "etcher_line_params", lp)

        case PhoenixKit.Users.Auth.update_user_custom_fields(user, merged) do
          {:ok, updated_user} ->
            {:noreply, assign(socket, current_user: updated_user, user_line_params: lp)}

          {:error, _} ->
            {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("etcher:line-params-changed", _payload, socket), do: {:noreply, socket}

  # Marker strokes are freeform ink — the user is drawing, not
  # captioning, so suppress the comment composer entirely. Push a
  # `etcher:patch-shape` so the freshly-drawn marker's tooltip shows
  # the author name immediately (the server-side stamp in
  # `etcher:annotations-changed` only takes effect after a refresh
  # without this — local etcher state doesn't auto-rehydrate).
  @impl true
  def handle_event("etcher:shape-drawn", %{"kind" => "marker", "uuid" => shape_uuid}, socket) do
    patch = %{
      shape_uuid: shape_uuid,
      tooltip_metadata: %{
        "author_name" => author_name(socket.assigns[:current_user]),
        "owner_uuid" => socket.assigns[:user_id],
        "subtitle" => Calendar.strftime(Date.utc_today(), "%b %-d, %Y")
      }
    }

    {:noreply, push_event(socket, "etcher:patch-shape", patch)}
  end

  def handle_event("etcher:shape-drawn", %{"kind" => "marker"}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("etcher:shape-drawn", %{"uuid" => shape_uuid}, socket) do
    %{user_id: user_id, source: source, slug: slug, chapter: chapter} = socket.assigns

    if user_id do
      new_resource_uuid = Ecto.UUID.generate()

      # Stamp the freshly-drawn shape with a resource_uuid right away so
      # the CommentsComponent below has a thread key. Idempotent — if a
      # resource_uuid already exists on the item (race / replay), we
      # reuse it.
      resource_uuid =
        case Marks.preallocate_shape_thread(
               user_id,
               source,
               slug,
               chapter,
               shape_uuid,
               new_resource_uuid
             ) do
          {:ok, ruuid} -> ruuid
          _ -> new_resource_uuid
        end

      page = Marks.lookup_shape_page(user_id, source, slug, chapter, shape_uuid)

      {:noreply,
       assign(socket,
         comment_modal_open: true,
         comment_resource_uuid: resource_uuid,
         comment_chapter: chapter,
         comment_page: page,
         composer_metadata: %{
           "source" => source,
           "slug" => slug,
           "chapter" => chapter,
           "page" => page,
           "etcher_shape_uuid" => shape_uuid
         },
         composer_only_mode?: true
       )}
    else
      {:noreply, socket}
    end
  end

  # CommentBridge -> us. The detail map from `window.openCommentModal`
  # is forwarded as-is. We use comment_uuid as the resource_uuid
  # (CommentsComponent looks up all comments by resource_uuid).
  @impl true
  def handle_event("open_comment_modal", params, socket) do
    %{source: source, slug: slug, chapter: chapter} = socket.assigns
    resource_uuid = params["comment_uuid"] || params["resource_uuid"]

    # Replies need the same etcher manga/chapter/shape context on their
    # metadata as the first comment so the /manga/comments listing can
    # find them — fall back to the page/etcher_shape_uuid from JS if
    # passed, otherwise null fields stay empty (form_extras skips them).
    composer_metadata = %{
      "source" => source,
      "slug" => slug,
      "chapter" => params["chapter"] || chapter,
      "page" => params["page"],
      "etcher_shape_uuid" => params["etcher_shape_uuid"] || params["shape_uuid"]
    }

    {:noreply,
     assign(socket,
       comment_modal_open: true,
       comment_resource_uuid: resource_uuid,
       comment_chapter: params["chapter"] || chapter,
       comment_page: params["page"],
       composer_metadata: composer_metadata,
       composer_only_mode?: false
     )}
  end

  @impl true
  def handle_event("close_comment_modal", _params, socket) do
    # Push a refit hint to the parent page so it re-runs fitToPage —
    # the keyboard from the comment modal may have changed the visual
    # viewport while open; the resize handler in show_fresco.html.heex
    # suppresses refits while a modal is open, so we explicitly
    # refit here on close.
    {:noreply,
     socket
     |> assign(comment_modal_open: false, composer_metadata: nil, composer_only_mode?: false)
     |> push_event("fresco:refit", %{})}
  end

  @impl true
  def handle_event("annotation_updated", _payload, socket) do
    # No-op for now — production uses this to refresh per-annotation
    # color / visibility chips in the modal header. Etcher owns shape
    # color via its own toolbar so we don't need the chip; visibility
    # toggling would be a follow-up.
    {:noreply, socket}
  end

  def handle_event(_event, _payload, socket), do: {:noreply, socket}

  # CommentsComponent broadcasts `{:comments_updated, %{action: :created,
  # resource_uuid: ...}}` to its host LiveView after a successful post.
  # For a newly-drawn shape's *first* comment, we link the comment_uuid
  # back onto the etcher item so the tooltip + visibility resolution
  # find the right comment. No-op for replies (item.comment_uuid is
  # already set) and for unrelated resources.
  @impl true
  def handle_info({:comments_updated, %{action: :created, resource_uuid: resource_uuid}}, socket) do
    %{user_id: user_id, source: source, slug: slug, chapter: chapter} = socket.assigns

    # Strip mode: the shape can live in an auto-appended chapter's mark
    # row rather than the URL chapter, since `replace_etcher_shapes`
    # routes saves by image_idx. Pass the etcher_shape_uuid from the
    # composer metadata + the loaded_chapters snapshot so the linker
    # can find the shape wherever it landed and stamp BOTH the
    # resource_uuid (the URL-chapter preallocate missed) and
    # comment_uuid on it.
    link_opts = [
      etcher_shape_uuid: get_in(socket.assigns[:composer_metadata] || %{}, ["etcher_shape_uuid"]),
      loaded_chapters: socket.assigns[:loaded_chapters]
    ]

    link_result =
      if user_id do
        Marks.link_first_comment_to_shape(
          user_id,
          source,
          slug,
          chapter,
          resource_uuid,
          link_opts
        )
      else
        {:ok, :no_change}
      end

    # When a fresh shape's first comment links, push a layer.patchShape
    # event with the rebuilt tooltip metadata so the hover bubble + pin
    # click work without a page refresh. Replies on already-linked
    # shapes don't change the tooltip (first comment is the label).
    socket =
      case link_result do
        {:ok, %{shape_uuid: _, tooltip_metadata: _} = patch} ->
          push_event(socket, "etcher:patch-shape", patch)

        _ ->
          socket
      end

    # Composer-only mode is a "draw + post" flow: once the first comment
    # is in, close the modal so the user lands back on the page. Full-
    # thread mode (existing-shape clicks) stays open — replies keep
    # coming, and the user is reading the thread.
    if socket.assigns[:composer_only_mode?] do
      {:noreply,
       socket
       |> assign(comment_modal_open: false, composer_metadata: nil, composer_only_mode?: false)
       |> push_event("fresco:refit", %{})}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:comments_updated, _payload}, socket), do: {:noreply, socket}

  # The Leaf editor (inside CommentsComponent) sends `:leaf_changed`
  # messages to the host LiveView on every keystroke. Forward each
  # payload back into the LiveComponent via `send_update` so its
  # `:new_comment` / `:editing_content` assign stays current — the
  # component's `add_comment` handler reads from socket assigns (not
  # form params) because Leaf's contenteditable doesn't bubble through
  # form submits, so a missed update means the comment ships empty.
  def handle_info({:leaf_changed, %{editor_id: editor_id, markdown: markdown}}, socket) do
    case String.split(editor_id, ":") do
      ["pk-comments", component_id, "draft", _position] ->
        forward_leaf_change(component_id, :draft, markdown)

      ["pk-comments", component_id, "reply", _position] ->
        forward_leaf_change(component_id, :reply, markdown)

      ["pk-comments", component_id, "edit", _comment_id] ->
        forward_leaf_change(component_id, :edit, markdown)

      _ ->
        :ok
    end

    {:noreply, socket}
  end

  def handle_info({:leaf_changed, _payload}, socket), do: {:noreply, socket}
  def handle_info({:leaf, _, _}, socket), do: {:noreply, socket}

  defp forward_leaf_change(component_id, kind, content) do
    Phoenix.LiveView.send_update(
      PhoenixKitComments.Web.CommentsComponent,
      id: component_id,
      leaf_content_changed: %{kind: kind, content: content}
    )
  end

  # Every annotation either has no integer image_idx (canvas mode in
  # strip context — shouldn't happen but treat conservatively) or its
  # image_idx falls within one of the loaded chapter ranges.
  defp all_known_idx?(annotations, loaded) do
    Enum.all?(annotations, fn ann ->
      idx = ann["image_idx"]
      is_integer(idx) and not is_nil(find_chapter_for_idx(idx, loaded))
    end)
  end

  defp group_annotations_by_chapter(annotations, loaded) do
    Enum.reduce(annotations, %{}, fn ann, acc ->
      idx = ann["image_idx"]

      case find_chapter_for_idx(idx, loaded) do
        nil ->
          acc

        ch ->
          rebased = Map.put(ann, "image_idx", idx - ch["start_idx"])
          Map.update(acc, ch["chapter"], [rebased], &(&1 ++ [rebased]))
      end
    end)
  end

  defp find_chapter_for_idx(idx, _loaded) when not is_integer(idx), do: nil

  defp find_chapter_for_idx(idx, loaded) do
    Enum.find(loaded, fn ch ->
      idx >= ch["start_idx"] and idx <= ch["end_idx"]
    end)
  end
end
