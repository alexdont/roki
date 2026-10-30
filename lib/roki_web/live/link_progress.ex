defmodule RokiWeb.LinkProgress do
  @moduledoc """
  The "Link progress" panel on a show's episodes page (`Roki.Link`): offer a link to friends,
  answer an invitation (with a look at what accepting would change first), and, once linked,
  pause it, mark "just me", add people, start over or leave.

  Tells the page two things by message: `{:link_solo, boolean}` (the page marks without carrying
  it to the others while this is on) and `:link_reload` (marks changed under it).
  """
  use RokiWeb, :live_component

  alias Roki.{Link, Social}

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       solo?: false,
       picking?: false,
       reviewing?: false,
       plan: nil,
       notice: nil,
       friends: [],
       next_up: nil,
       next_rev: nil
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = socket |> assign(assigns) |> refresh()
    {:ok, next_up(socket, Map.get(assigns, :rev))}
  end

  # The episode "We watched it" would mark: worked out again when the page's marks change (`rev`).
  defp next_up(%{assigns: %{link: nil}} = socket, _rev), do: socket

  defp next_up(%{assigns: %{next_rev: rev, next_up: known}} = socket, rev) when known != nil,
    do: socket

  defp next_up(socket, rev) do
    %{uuid: uuid, title: %{id: id}} = socket.assigns
    socket |> assign(next_rev: rev) |> start_async(:next_up, fn -> Link.next_up(uuid, id) end)
  end

  defp refresh(%{assigns: %{uuid: uuid, title: %{id: id}}} = socket) do
    link = Link.active(uuid, id)
    invitation = if(link, do: nil, else: Link.invitation(uuid, id))

    state =
      cond do
        link -> {:linked, names(link, uuid)}
        invitation -> :invited
        true -> :none
      end

    # The page shows it on its own buttons: "Link progress", "Link request", "Linked with Max".
    if state != socket.assigns[:reported] do
      send(self(), {:link_state, state})
    end

    assign(socket,
      reported: state,
      link: link,
      invitation: invitation,
      undoable?: link != nil and Link.undoable?(uuid, link.id),
      rounds: if(link, do: Link.rounds(uuid, id), else: [])
    )
  end

  # ── events ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("pick", _params, socket) do
    friends =
      socket.assigns.uuid
      |> Social.friends()
      |> Enum.reject(fn f -> member?(socket.assigns.link, f.uuid) end)

    {:noreply,
     assign(socket, picking?: not socket.assigns.picking?, friends: friends, notice: nil)}
  end

  def handle_event("invite", params, socket) do
    %{uuid: uuid, title: title} = socket.assigns

    case Link.invite(uuid, title.id, List.wrap(params["friends"])) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(picking?: false, notice: "Invitation sent. Marks are shared once they accept.")
         |> refresh()}

      {:error, :nobody} ->
        {:noreply, assign(socket, notice: "Choose at least one friend.")}

      {:error, _} ->
        {:noreply, assign(socket, notice: "Only friends can be linked.")}
    end
  end

  def handle_event("we_watched", _params, socket) do
    %{uuid: uuid, title: %{id: id}} = socket.assigns

    case Link.watched_together(uuid, id) do
      {:ok, %{season: s, episode: e}} ->
        send(self(), :link_reload)

        {:noreply,
         socket
         |> assign(notice: "Marked S#{s}E#{e} for everyone in the link.", next_up: nil)
         |> refresh()
         |> next_up(nil)}

      {:error, :paused} ->
        {:noreply, assign(socket, notice: "The link is paused. Resume it first.")}

      {:error, :nothing_next} ->
        {:noreply, assign(socket, notice: "Nothing further to mark.")}

      _ ->
        {:noreply, refresh(socket)}
    end
  end

  def handle_event("review", _params, socket) do
    %{uuid: uuid, invitation: %{link_id: id}} = socket.assigns

    {:noreply,
     socket
     |> assign(reviewing?: true, plan: :loading)
     |> start_async(:plan, fn -> Link.plan(uuid, id) end)}
  end

  def handle_event("accept", params, socket) do
    %{uuid: uuid, invitation: %{link_id: id}} = socket.assigns

    case Link.accept(uuid, id, params["choice"]) do
      {:ok, _} ->
        send(self(), :link_reload)
        {:noreply, socket |> assign(reviewing?: false, plan: nil, notice: nil) |> refresh()}

      {:needs_choice, _} ->
        {:noreply, assign(socket, notice: "Choose whose progress is right first.")}

      _ ->
        {:noreply, assign(socket, notice: "That invitation is no longer there.") |> refresh()}
    end
  end

  def handle_event("decline", _params, socket) do
    Link.decline(socket.assigns.uuid, socket.assigns.invitation.link_id)
    {:noreply, socket |> assign(reviewing?: false, plan: nil) |> refresh()}
  end

  def handle_event("pause", _params, socket), do: pause(socket, true)
  def handle_event("resume", _params, socket), do: pause(socket, false)

  def handle_event("solo", _params, socket) do
    solo? = not socket.assigns.solo?
    send(self(), {:link_solo, solo?})
    {:noreply, assign(socket, :solo?, solo?)}
  end

  def handle_event("leave", _params, socket) do
    Link.leave(socket.assigns.uuid, socket.assigns.link.id)
    send(self(), {:link_solo, false})

    {:noreply,
     socket |> assign(solo?: false, notice: "Unlinked. Nothing was unmarked.") |> refresh()}
  end

  def handle_event("start_over", _params, socket) do
    case Link.start_over(socket.assigns.uuid, socket.assigns.link.id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(
           notice: "Starting over: the others have to accept again. No one's marks were changed."
         )
         |> refresh()}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("undo", _params, socket) do
    case Link.undo(socket.assigns.uuid, socket.assigns.link.id) do
      {:ok, n} ->
        send(self(), :link_reload)
        {:noreply, socket |> assign(notice: "Put back #{n} episodes.") |> refresh()}

      _ ->
        {:noreply, refresh(socket)}
    end
  end

  def handle_event("rate_round", %{"round" => round, "score" => score} = params, socket) do
    Link.rate(socket.assigns.uuid, round, score, save_to_tmdb?: params["save"] == "on")
    {:noreply, refresh(socket)}
  end

  def handle_event("skip_round", %{"round" => round}, socket) do
    Link.rate(socket.assigns.uuid, round, :skip)
    {:noreply, refresh(socket)}
  end

  def handle_event("reveal_round", %{"round" => round}, socket) do
    Link.reveal(socket.assigns.uuid, round)
    {:noreply, refresh(socket)}
  end

  defp pause(socket, paused?) do
    Link.pause(socket.assigns.uuid, socket.assigns.link.id, paused?)
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_async(:next_up, {:ok, next}, socket),
    do: {:noreply, assign(socket, :next_up, next || :done)}

  def handle_async(:next_up, _other, socket), do: {:noreply, assign(socket, :next_up, :done)}

  def handle_async(:plan, {:ok, plan}, socket), do: {:noreply, assign(socket, :plan, plan)}

  def handle_async(:plan, _other, socket),
    do: {:noreply, assign(socket, plan: {:error, :unavailable})}

  defp member?(nil, _uuid), do: false
  defp member?(link, uuid), do: Enum.any?(link.members, &(&1.uuid == uuid))

  defp names(link, me) do
    for m <- link.members, m.status == "active", m.uuid != me, do: m.name
  end

  defp waiting(link) do
    for m <- link.members, m.status == "invited", do: m.name
  end

  defp me(link, uuid), do: Enum.find(link.members, &(&1.uuid == uuid))

  # ── view ───────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="rounded-2xl border border-base-300 bg-base-100 p-3 text-sm sm:p-4">
      <%= cond do %>
        <% @link -> %>
          <.active
            link={@link}
            uuid={@uuid}
            solo?={@solo?}
            undoable?={@undoable?}
            next_up={@next_up}
            target={@myself}
          />
          <.finale :for={r <- @rounds} round={r} target={@myself} />
        <% @invitation -> %>
          <.invitation
            invitation={@invitation}
            uuid={@uuid}
            reviewing?={@reviewing?}
            plan={@plan}
            target={@myself}
          />
        <% true -> %>
          <div class="flex flex-wrap items-center gap-2">
            <.icon name="hero-link" class="h-4 w-4 text-base-content/60" />
            <span class="text-base-content/70">Watching this with someone?</span>
            <button
              type="button"
              phx-click="pick"
              phx-target={@myself}
              class="btn btn-sm btn-primary rounded-full"
            >
              Link progress
            </button>
          </div>
      <% end %>

      <.picker :if={@picking?} friends={@friends} target={@myself} />
      <p :if={@notice} class="mt-2 text-base-content/70">{@notice}</p>
    </div>
    """
  end

  attr :link, :map, required: true
  attr :uuid, :string, required: true
  attr :solo?, :boolean, required: true
  attr :undoable?, :boolean, required: true
  attr :next_up, :any, default: nil
  attr :target, :any, required: true

  defp active(assigns) do
    assigns =
      assign(assigns,
        names: names(assigns.link, assigns.uuid),
        waiting: waiting(assigns.link),
        paused?: me(assigns.link, assigns.uuid).paused
      )

    ~H"""
    <div class="space-y-3">
      <div class="flex flex-wrap items-center gap-2">
        <.icon name="hero-link-solid" class="h-4 w-4 text-primary" />
        <span class="font-medium">
          Progress linked with {Enum.join(@names, ", ")}
        </span>
        <span :if={@paused?} class="badge badge-warning badge-sm">Paused</span>
      </div>
      <p :if={@waiting != []} class="text-xs text-base-content/60">
        Waiting for {Enum.join(@waiting, ", ")} to accept.
      </p>
      <p :if={@paused?} class="text-xs text-base-content/60">
        Paused: what you mark is not shared, and you don't get theirs.
      </p>
      <p :if={@link.fresh} class="text-xs text-base-content/60">
        Started over: only episodes marked from then on are shared.
      </p>

      <%!-- One tap for the lunchtime case: the next episode, marked for everyone in the link. --%>
      <button
        type="button"
        phx-click="we_watched"
        phx-target={@target}
        disabled={@paused? or not is_map(@next_up)}
        class="btn btn-primary btn-sm h-auto min-h-9 w-full justify-start gap-2 rounded-xl px-3 py-2 text-left sm:w-auto"
      >
        <.icon name="hero-check-circle" class="h-5 w-5 shrink-0" />
        <span :if={is_map(@next_up)} class="min-w-0">
          <span class="block font-semibold">We watched S{@next_up.season}E{@next_up.episode}</span>
          <span :if={@next_up[:name]} class="block truncate text-xs font-normal opacity-80">
            {@next_up.name}
          </span>
        </span>
        <span :if={@next_up == nil} class="font-semibold">Finding the next episode…</span>
        <span :if={@next_up == :done} class="font-semibold">You're all caught up</span>
      </button>

      <div class="flex flex-wrap items-center gap-2">
        <label class="flex cursor-pointer items-center gap-2 rounded-full bg-base-200 px-3 py-1.5">
          <input
            type="checkbox"
            class="toggle toggle-primary toggle-sm"
            checked={@solo?}
            phx-click="solo"
            phx-target={@target}
          />
          <span class="font-medium">Just me</span>
        </label>
        <button
          type="button"
          phx-click={if @paused?, do: "resume", else: "pause"}
          phx-target={@target}
          class="btn btn-sm rounded-full border-0 bg-base-200"
        >
          {if @paused?, do: "Resume link", else: "Pause link"}
        </button>
        <button
          type="button"
          phx-click="pick"
          phx-target={@target}
          class="btn btn-sm rounded-full border-0 bg-base-200"
        >
          Add someone
        </button>
        <button
          :if={@undoable?}
          type="button"
          phx-click="undo"
          phx-target={@target}
          class="btn btn-sm rounded-full border-0 bg-base-200"
        >
          Undo what was taken off
        </button>
        <button
          type="button"
          phx-click="start_over"
          phx-target={@target}
          data-confirm="Start over? A new link begins with nothing carried over, and the others have to accept again. No one's marks change."
          class="btn btn-sm btn-ghost rounded-full"
        >
          Start over
        </button>
        <button
          type="button"
          phx-click="leave"
          phx-target={@target}
          data-confirm="Unlink your progress on this show? Episodes already marked stay marked."
          class="btn btn-sm btn-ghost rounded-full text-error"
        >
          Unlink
        </button>
      </div>
      <p :if={@solo?} class="text-xs text-base-content/60">
        Just me is on: what you mark on this page stays on your account.
      </p>
    </div>
    """
  end

  attr :round, :map, required: true
  attr :target, :any, required: true

  # The rating moment after a finished season or series: answer, wait, then see everyone's.
  defp finale(assigns) do
    scored = for s <- assigns.round.scores, not s.skipped, do: s

    average =
      if scored == [],
        do: nil,
        else: Float.round(Enum.sum(Enum.map(scored, & &1.score)) / length(scored), 1)

    assigns = assign(assigns, scored: scored, average: average)

    ~H"""
    <div class="mt-3 space-y-2 rounded-xl bg-base-200 p-3">
      <p class="font-medium">
        {if @round.season, do: "Season #{@round.season}", else: "The whole series"} is done. How was it?
      </p>

      <div :if={@round.revealed} class="space-y-1">
        <p :for={s <- @round.scores} class="flex items-center justify-between gap-3">
          <span>{s.name}</span>
          <span class="font-semibold tabular-nums">{if s.skipped, do: "skipped", else: fmt(s.score)}</span>
        </p>
        <p
          :if={@average && length(@scored) > 1}
          class="border-t border-base-300 pt-1 text-xs text-base-content/60"
        >
          Average {fmt(@average)}
        </p>
      </div>

      <form
        :if={!@round.revealed and @round.mine == nil}
        phx-submit="rate_round"
        phx-target={@target}
        class="space-y-2"
      >
        <input type="hidden" name="round" value={@round.id} />
        <div class="flex items-center gap-3">
          <input
            type="range"
            name="score"
            min="1"
            max="10"
            step="0.5"
            value="7"
            class="range range-primary range-sm flex-1"
            oninput="this.nextElementSibling.value = this.value"
          />
          <output class="w-8 text-right font-semibold tabular-nums">7</output>
        </div>
        <label :if={@round.season == nil} class="flex items-center gap-2 text-xs text-base-content/70">
          <input type="checkbox" name="save" class="checkbox checkbox-xs" />
          Also save as my rating of the show
        </label>
        <div class="flex flex-wrap items-center gap-2">
          <button type="submit" class="btn btn-sm btn-primary rounded-full">Rate</button>
          <button
            type="button"
            phx-click="skip_round"
            phx-value-round={@round.id}
            phx-target={@target}
            class="btn btn-sm btn-ghost rounded-full"
          >
            Skip
          </button>
          <span class="text-xs text-base-content/60">Scores show once everyone has answered.</span>
        </div>
      </form>

      <div :if={!@round.revealed and @round.mine != nil} class="flex flex-wrap items-center gap-2">
        <span class="text-base-content/70">
          Your answer is in. {@round.answered} of {@round.total} have answered.
        </span>
        <button
          type="button"
          phx-click="reveal_round"
          phx-value-round={@round.id}
          phx-target={@target}
          class="btn btn-xs rounded-full border-0 bg-base-300"
        >
          Show now
        </button>
      </div>
    </div>
    """
  end

  defp fmt(n) when is_number(n),
    do: :erlang.float_to_binary(n * 1.0, decimals: 1) |> String.replace_suffix(".0", "")

  defp fmt(_), do: ""

  attr :invitation, :map, required: true
  attr :uuid, :string, required: true
  attr :reviewing?, :boolean, required: true
  attr :plan, :any, default: nil
  attr :target, :any, required: true

  defp invitation(assigns) do
    ~H"""
    <div class="space-y-3">
      <div class="flex flex-wrap items-center gap-2">
        <.icon name="hero-link" class="h-4 w-4 text-primary" />
        <span class="font-medium">
          {@invitation.from || "Someone"} wants to link progress on this show with you
        </span>
      </div>
      <p class="text-xs text-base-content/60">
        Episodes either of you marks watched are marked for both. Taking a mark off stays on your own account.
      </p>

      <div :if={!@reviewing?} class="flex flex-wrap gap-2">
        <button
          type="button"
          phx-click="review"
          phx-target={@target}
          class="btn btn-sm btn-primary rounded-full"
        >
          Review
        </button>
        <button
          type="button"
          phx-click="decline"
          phx-target={@target}
          class="btn btn-sm btn-ghost rounded-full"
        >
          Decline
        </button>
      </div>

      <div :if={@reviewing?} class="space-y-3">
        <p :if={@plan == :loading} class="flex items-center gap-2 text-base-content/60">
          <span class="loading loading-spinner loading-xs"></span> Comparing what you have watched…
        </p>
        <p :if={match?({:error, _}, @plan)} class="text-error">
          Could not read the progress just now. Try again in a moment.
        </p>
        <form
          :if={@plan not in [:loading, nil] and not match?({:error, _}, @plan)}
          phx-submit="accept"
          phx-target={@target}
          class="space-y-3"
        >
          <p :if={@plan == :link}>
            You are at the same point{if @invitation.fresh,
              do: ", and this link starts over",
              else: ""}.
            Nothing changes now; marks are shared from here on.
          </p>
          <p :if={match?({:fill_me, _}, @plan)}>
            They have {elem(@plan, 1)} episodes watched and you have none, so yours will be marked to match.
          </p>
          <p :if={match?({:fill_others, _}, @plan)}>
            You have {elem(@plan, 1)} episodes watched and they have none, so theirs will be marked to match.
          </p>
          <div :if={match?({:choose, _}, @plan)} class="space-y-2">
            <p class="font-medium">You have different progress. Which one is right?</p>
            <label class="flex items-center gap-2">
              <input
                type="radio"
                name="choice"
                value={@uuid}
                class="radio radio-sm radio-primary"
                required
              />
              <span>Mine, {elem(@plan, 1).mine} episodes</span>
            </label>
            <label :for={o <- elem(@plan, 1).others} class="flex items-center gap-2">
              <input type="radio" name="choice" value={o.uuid} class="radio radio-sm radio-primary" />
              <span>{o.name}'s, {o.count} episodes</span>
            </label>
            <p class="text-xs text-base-content/60">
              Choosing a shorter progress takes the extra episodes off the other accounts. You can undo that afterwards.
            </p>
          </div>
          <div class="flex flex-wrap gap-2">
            <button type="submit" class="btn btn-sm btn-primary rounded-full">Link progress</button>
            <button
              type="button"
              phx-click="decline"
              phx-target={@target}
              class="btn btn-sm btn-ghost rounded-full"
            >
              Decline
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  attr :friends, :list, required: true
  attr :target, :any, required: true

  defp picker(assigns) do
    ~H"""
    <form
      phx-submit="invite"
      phx-target={@target}
      class="mt-3 space-y-2 border-t border-base-300 pt-3"
    >
      <p :if={@friends == []} class="text-base-content/60">
        No friends to add yet. Add a friend first, then link progress with them.
      </p>
      <label :for={f <- @friends} class="flex items-center gap-2">
        <input
          type="checkbox"
          name="friends[]"
          value={f.uuid}
          class="checkbox checkbox-sm checkbox-primary"
        />
        <span>{f.username}</span>
      </label>
      <p :if={@friends != []} class="text-xs text-base-content/60">
        They get a request. Nothing is shared until they accept.
      </p>
      <div :if={@friends != []} class="flex gap-2">
        <button type="submit" class="btn btn-sm btn-primary rounded-full">Send</button>
        <button
          type="button"
          phx-click="pick"
          phx-target={@target}
          class="btn btn-sm btn-ghost rounded-full"
        >
          Cancel
        </button>
      </div>
    </form>
    """
  end
end
