if Code.ensure_loaded?(Etcher) do
  defmodule Manhwa.EtcherHost do
    @moduledoc """
    Minimal default LiveView hosting the Etcher annotation layer for
    the reader pages (which are controller-rendered — this embedded
    LiveView supplies the channel Etcher's hook pushes events through).

    Persists shape saves through the configured `Manhwa.Annotations`
    adapter. It deliberately renders no comment UI — hosts that want
    comment threads on shapes (composer modals, replies, likes) should
    ship their own LiveView and point `config :manhwa, :etcher_host`
    at it; the reader embeds whatever module is configured with the
    session keys documented in `Manhwa.Config.etcher_session/2`.

    Only compiled when the optional `etcher` dependency is present.
    """

    use Phoenix.LiveView

    @impl true
    def mount(_params, session, socket) do
      {:ok,
       assign(socket,
         fresco_id: session["fresco_id"],
         series: session["series"],
         chapter: session["chapter"],
         user_id: session["user_id"]
       )}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <div id={"etcher-host-#{@fresco_id}"}>
        <Etcher.layer fresco_id={@fresco_id} />
      </div>
      """
    end

    @impl true
    def handle_event("etcher:annotations-changed", %{"annotations" => annotations}, socket) do
      %{user_id: user_id, series: series, chapter: chapter} = socket.assigns

      with ann when not is_nil(ann) <- Manhwa.Config.annotations(),
           false <- is_nil(user_id),
           true <- Code.ensure_loaded?(ann) and function_exported?(ann, :replace_shapes, 5) do
        ann.replace_shapes(user_id, series, chapter, annotations, [])
      end

      {:noreply, socket}
    end

    def handle_event(_event, _payload, socket), do: {:noreply, socket}
  end
end
