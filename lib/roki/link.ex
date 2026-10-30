defmodule Roki.Link do
  @moduledoc """
  Linked progress: friends who watch a show together keep one record of how far they are.

  A link is made on a show by one person, who invites friends (any number). While it is active,
  every episode any member marks watched is marked for the others as well — whichever account the
  watching happened on. Only marks are carried: taking a mark off stays on the account it was taken
  off, so a slip cannot wipe anyone else's progress.

  **Joining.** What a member has already watched is compared with the group's when they accept:

    * nobody has anything: it just links;
    * only one side has progress: that side is the source of truth and the empty accounts are
      filled up to it, without a question;
    * both sides have progress and they differ: the joiner is asked which is right. Choosing the
      shorter one takes the extra marks off the others' accounts, and what was taken off is kept
      so `undo/2` can put it back.

  A link begun with `start_over/2` is `fresh`: nobody's earlier marks are compared or carried, only
  what is marked from then on.

  **Pausing.** A paused member neither sends marks nor takes them. Marking from the title page can
  also be "just me" for one episode (`solo: true`), the default being together.

  **Rounds.** When a linked group finishes a season (or the series), a round opens: each member
  gives a score or skips, and the scores are shown together once everyone has answered (or
  someone asks to see them). Scores are kept here; `rate/4` can also put one on the person's own
  TMDB rating of the show, only when they ask.

  Everything that marks an episode goes through `Roki.Watch`, which calls `mirror/4` afterwards;
  the writes made here pass `mirrored: true` so they are never mirrored again.
  """

  alias Roki.Repo

  # What marks, reads and titles go through. Tests put a stand-in here: the real one reads TMDB.
  defp watch, do: Application.get_env(:roki, :link_watch, Roki.Watch)

  # ── reading ────────────────────────────────────────────────────────

  @doc """
  The active link this person is in on a show: `%{id, fresh, members: [%{uuid, name, status,
  paused}]}`, or nil.
  """
  def active(uuid, tmdb_id) when is_binary(uuid) and is_integer(tmdb_id) do
    case rows(
           """
           select l.id, l.fresh from roki_links l
             join roki_link_members m on m.link_id = l.id
            where l.type = 'tv' and l.tmdb_id = $1 and l.status = 'active'
              and m.user_uuid = $2 and m.status = 'active'
            limit 1
           """,
           [tmdb_id, dump(uuid)]
         ) do
      [[id, fresh]] -> %{id: load(id), fresh: fresh, tmdb_id: tmdb_id, members: members(id)}
      _ -> nil
    end
  end

  def active(_uuid, _tmdb_id), do: nil

  @doc "An invitation waiting for this person on a show: `%{link_id, from, fresh}`, or nil."
  def invitation(uuid, tmdb_id) when is_binary(uuid) and is_integer(tmdb_id) do
    case rows(
           """
           select l.id, l.fresh, u.username from roki_links l
             join roki_link_members m on m.link_id = l.id
             left join phoenix_kit_users u on u.uuid = m.invited_by
            where l.type = 'tv' and l.tmdb_id = $1 and l.status = 'active'
              and m.user_uuid = $2 and m.status = 'invited'
            order by m.updated_at desc limit 1
           """,
           [tmdb_id, dump(uuid)]
         ) do
      [[id, fresh, from]] -> %{link_id: load(id), fresh: fresh, from: from}
      _ -> nil
    end
  end

  def invitation(_uuid, _tmdb_id), do: nil

  @doc "Every show this person is linked on: `[%{tmdb_id, with: [names]}]`."
  def linked_shows(uuid) when is_binary(uuid) do
    for [tmdb_id, id] <-
          rows(
            """
            select l.tmdb_id, l.id from roki_links l
              join roki_link_members m on m.link_id = l.id
             where l.status = 'active' and m.user_uuid = $1 and m.status = 'active'
            """,
            [dump(uuid)]
          ) do
      names = for m <- members(id), m.status == "active", m.uuid != uuid, do: m.name
      %{tmdb_id: tmdb_id, with: names}
    end
  end

  defp members(link_id) do
    for [user, status, paused, name] <-
          rows(
            """
            select m.user_uuid, m.status, m.paused, u.username from roki_link_members m
              left join phoenix_kit_users u on u.uuid = m.user_uuid
             where m.link_id = $1 and m.status in ('active', 'invited')
             order by m.inserted_at
            """,
            [to_bin(link_id)]
          ),
        do: %{uuid: load(user), status: status, paused: paused, name: name}
  end

  # ── making and answering a link ────────────────────────────────────

  @doc """
  Invite friends to link progress on a show. Joins the link the inviter already has on it, or
  makes one. Only friends can be invited. `{:ok, link_id}`.
  """
  def invite(inviter, tmdb_id, friends) when is_binary(inviter) and is_integer(tmdb_id) do
    friends = friends |> List.wrap() |> Enum.uniq() |> Enum.reject(&(&1 == inviter))

    cond do
      friends == [] ->
        {:error, :nobody}

      not Enum.all?(friends, &friends?(inviter, &1)) ->
        {:error, :not_friends}

      true ->
        link_id = (active(inviter, tmdb_id) || create(inviter, tmdb_id, false)).id
        Enum.each(friends, &invite_one(link_id, inviter, tmdb_id, &1))
        {:ok, link_id}
    end
  end

  defp friends?(a, b), do: PhoenixKitUserConnections.connected?(a, b)

  defp create(creator, tmdb_id, fresh?) do
    [[id]] =
      rows(
        "insert into roki_links (type, tmdb_id, created_by, fresh, status, inserted_at, updated_at) values ('tv', $1, $2, $3, 'active', now(), now()) returning id",
        [tmdb_id, dump(creator), fresh?]
      )

    rows(
      "insert into roki_link_members (link_id, user_uuid, status, invited_by, joined_at, inserted_at, updated_at) values ($1, $2, 'active', $2, now(), now(), now())",
      [id, dump(creator)]
    )

    %{id: load(id)}
  end

  defp invite_one(link_id, inviter, tmdb_id, friend) do
    rows(
      """
      insert into roki_link_members (link_id, user_uuid, status, invited_by, inserted_at, updated_at)
      values ($1, $2, 'invited', $3, now(), now())
      on conflict (link_id, user_uuid) do update
        set status = case when roki_link_members.status = 'active' then 'active' else 'invited' end,
            invited_by = excluded.invited_by, updated_at = now()
      """,
      [to_bin(link_id), dump(friend), dump(inviter)]
    )

    title = title_name(tmdb_id, inviter)

    Roki.Social.notify(
      "link_invite",
      inviter,
      friend,
      "#{username(inviter)} wants to link progress on #{title} with you",
      "hero-link",
      "/title/tv/#{tmdb_id}/episodes"
    )
  end

  @doc """
  What accepting would do for this person, as a plan to show them first:

    * `:link` — nothing to bring across either way;
    * `{:fill_me, count}` — the group is ahead and this person has nothing: they are filled in;
    * `{:fill_others, count}` — this person is ahead and the group has nothing;
    * `{:choose, %{mine: n, others: [%{uuid, name, count}]}}` — both have progress and it differs.
  """
  def plan(uuid, link_id) do
    with %{} = link <- link(link_id), {:ok, title} <- watch().title("tv", link.tmdb_id, uuid) do
      if link.fresh do
        :link
      else
        mine = watch().watched_pairs(uuid, title)

        others =
          for m <- members(link_id), m.status == "active", m.uuid != uuid do
            %{uuid: m.uuid, name: m.name, set: watch().watched_pairs(m.uuid, title)}
          end

        most = Enum.max_by(others, &MapSet.size(&1.set), fn -> nil end)
        plan_for(mine, others, most)
      end
    else
      _ -> {:error, :unavailable}
    end
  end

  defp plan_for(mine, others, most) do
    empty_mine? = MapSet.size(mine) == 0
    others_empty? = Enum.all?(others, &(MapSet.size(&1.set) == 0))
    same? = Enum.all?(others, &(&1.set == mine))

    cond do
      same? ->
        :link

      empty_mine? and others_empty? ->
        :link

      empty_mine? ->
        {:fill_me, MapSet.size(most.set)}

      others_empty? ->
        {:fill_others, MapSet.size(mine)}

      true ->
        {:choose,
         %{
           mine: MapSet.size(mine),
           others: Enum.map(others, &%{uuid: &1.uuid, name: &1.name, count: MapSet.size(&1.set)})
         }}
    end
  end

  @doc """
  Accept an invitation. `choice` is only needed when the plan is `{:choose, _}`: the uuid of the
  member whose progress is right, this person's own included. Returns `{:ok, plan}` when joined,
  `{:needs_choice, plan}` when a choice is still wanted.
  """
  def accept(uuid, link_id, choice \\ nil) do
    with %{} = link <- link(link_id),
         true <- invited?(uuid, link_id),
         plan = plan(uuid, link_id) do
      case {plan, choice} do
        {{:error, _} = error, _} ->
          error

        {{:choose, _}, nil} ->
          {:needs_choice, plan}

        {{:choose, _}, source} ->
          if valid_source?(link_id, uuid, source) do
            join(uuid, link, source)
            {:ok, plan}
          else
            {:needs_choice, plan}
          end

        {{:fill_me, _}, _} ->
          join(uuid, link, best_source(link_id, uuid))
          {:ok, plan}

        {{:fill_others, _}, _} ->
          join(uuid, link, uuid)
          {:ok, plan}

        {:link, _} ->
          join(uuid, link, nil)
          {:ok, plan}
      end
    else
      _ -> {:error, :no_invitation}
    end
  end

  # A choice comes from the browser: it has to name the joiner or a member who is in the link.
  defp valid_source?(link_id, joiner, source) do
    source == joiner or
      Enum.any?(members(link_id), &(&1.status == "active" and &1.uuid == source))
  end

  defp best_source(link_id, joiner) do
    {:ok, title} = watch().title("tv", link(link_id).tmdb_id, joiner)

    members(link_id)
    |> Enum.filter(&(&1.status == "active" and &1.uuid != joiner))
    |> Enum.max_by(&MapSet.size(watch().watched_pairs(&1.uuid, title)))
    |> Map.fetch!(:uuid)
  end

  # Make the member active, then bring everyone to `source`'s marks (nil: leave things as they are).
  defp join(uuid, link, source) do
    rows(
      "update roki_link_members set status = 'active', joined_at = now(), updated_at = now() where link_id = $1 and user_uuid = $2",
      [to_bin(link.id), dump(uuid)]
    )

    if source, do: bring_to(link, source)

    Roki.Social.notify(
      "link_joined",
      uuid,
      link.created_by,
      "#{username(uuid)} joined linked progress on #{title_name(link.tmdb_id, uuid)}",
      "hero-link",
      "/title/tv/#{link.tmdb_id}/episodes"
    )

    :ok
  end

  # Give every other active member the source's marks. A member with marks the source does not
  # have loses them — kept in a snapshot first.
  defp bring_to(link, source) do
    {:ok, title} = watch().title("tv", link.tmdb_id, source)
    truth = watch().watched_pairs(source, title)

    for m <- members(link.id), m.status == "active", m.uuid != source do
      theirs = watch().watched_pairs(m.uuid, title)
      add = MapSet.difference(truth, theirs) |> MapSet.to_list()
      remove = MapSet.difference(theirs, truth) |> MapSet.to_list()

      if remove != [], do: snapshot(link.id, m.uuid, remove)
      if remove != [], do: watch().set_many_watched(m.uuid, title, remove, false, mirrored: true)
      if add != [], do: watch().set_many_watched(m.uuid, title, add, true, mirrored: true)
      announce(m.uuid, link.tmdb_id)
    end

    :ok
  end

  def decline(uuid, link_id) do
    set_status(uuid, link_id, "declined")
    end_if_alone(link_id)
    :ok
  end

  @doc "Leave a link. It ends when fewer than two members are left."
  def leave(uuid, link_id) do
    set_status(uuid, link_id, "left")
    end_if_alone(link_id)
    :ok
  end

  @doc "Pause (`true`) or resume (`false`) this person's side of a link."
  def pause(uuid, link_id, paused?) when is_boolean(paused?) do
    rows(
      "update roki_link_members set paused = $3, updated_at = now() where link_id = $1 and user_uuid = $2",
      [to_bin(link_id), dump(uuid), paused?]
    )

    :ok
  end

  @doc """
  Begin again: the link ends and a fresh one starts with the same people, who each have to accept
  again. Nobody's marks are touched; the new link only carries what is marked from now on.
  Returns `{:ok, new_link_id}`.
  """
  def start_over(uuid, link_id) do
    with %{} = link <- link(link_id),
         %{status: "active"} <- Enum.find(members(link_id), &(&1.uuid == uuid)) do
      others = for m <- members(link_id), m.uuid != uuid, do: m.uuid

      rows("update roki_links set status = 'ended', updated_at = now() where id = $1", [
        to_bin(link_id)
      ])

      new = create(uuid, link.tmdb_id, true)
      Enum.each(others, &invite_one(new.id, uuid, link.tmdb_id, &1))
      {:ok, new.id}
    else
      _ -> {:error, :not_a_member}
    end
  end

  @doc """
  Put back the marks taken off this person the last time a choice removed some. `{:ok, count}`,
  or `:nothing`.
  """
  def undo(uuid, link_id) do
    case rows(
           "select id, removed from roki_link_snapshots where link_id = $1 and user_uuid = $2 and not restored order by inserted_at desc limit 1",
           [to_bin(link_id), dump(uuid)]
         ) do
      [[id, %{"pairs" => pairs}]] ->
        {:ok, title} = watch().title("tv", link(link_id).tmdb_id, uuid)
        pairs = for [s, e] <- pairs, do: {s, e}
        watch().set_many_watched(uuid, title, pairs, true, mirrored: true)

        rows("update roki_link_snapshots set restored = true, updated_at = now() where id = $1", [
          id
        ])

        {:ok, length(pairs)}

      _ ->
        :nothing
    end
  end

  @doc "Is there something taken off this person by a choice that `undo/2` could put back?"
  def undoable?(uuid, link_id) do
    rows(
      "select 1 from roki_link_snapshots where link_id = $1 and user_uuid = $2 and not restored limit 1",
      [to_bin(link_id), dump(uuid)]
    ) != []
  end

  # ── carrying marks ─────────────────────────────────────────────────

  @doc """
  Episodes (`[{season, episode}]`, TMDB's numbers) were just marked watched on this account:
  mark them for the other active, unpaused members of its link on the show. Never raises — what
  was marked here stands whatever happens to the copies. Options: `solo: true` (just this
  account), `mirrored: true` (these marks were themselves carried; stop).
  """
  def mirror(uuid, tmdb_id, pairs, opts \\ [])
  def mirror(_uuid, _tmdb_id, [], _opts), do: :ok

  def mirror(uuid, tmdb_id, pairs, opts) do
    if opts[:solo] || opts[:mirrored] do
      :ok
    else
      with %{members: members} = link <- active(uuid, tmdb_id),
           %{paused: false} <- Enum.find(members, &(&1.uuid == uuid)),
           {:ok, title} <- watch().title("tv", tmdb_id, uuid) do
        targets =
          for m <- members, m.status == "active" and m.uuid != uuid and not m.paused, do: m.uuid

        for t <- targets, do: carry(t, title, pairs, tmdb_id)

        if targets != [] do
          record_together(link, uuid, targets, title, pairs)
          for t <- targets, do: tell_marked(link, uuid, t, title, pairs)
        end

        open_rounds(uuid, tmdb_id, title, pairs)
      end

      :ok
    end
  rescue
    _ -> :ok
  end

  # ── watching together: the record, the bell, the button ────────────

  # What was watched together, with how long it ran, for the "time together" stat.
  defp record_together(link, sender, targets, title, pairs) do
    participants = Enum.map([sender | targets], &dump/1)

    for {s, e, minutes} <- watch().episode_minutes(sender, title, pairs) do
      rows(
        """
        insert into roki_link_events (link_id, tmdb_id, season, episode, minutes, participants, inserted_at)
        values ($1, $2, $3, $4, $5, $6, now()) on conflict (link_id, season, episode) do nothing
        """,
        [to_bin(link.id), link.tmdb_id, s, e, minutes, participants]
      )
    end

    :ok
  end

  @note_every_s 600

  # A bell for the people the marks were carried to: at most one every ten minutes per show, so a
  # whole evening's episodes are one note, not five. Their own switch in Settings ("link").
  defp tell_marked(link, sender, target, title, pairs) do
    key = {:link_note, link.id, target}

    if Roki.Notify.wants?(target, "link") and not Roki.TTLCache.cached?(key) do
      Roki.TTLCache.put(key, @note_every_s, {:ok, true})

      Roki.Social.notify(
        "link_marked",
        sender,
        target,
        "#{username(sender)} marked #{describe(pairs)} of #{title.title} for you",
        "hero-link",
        "/title/tv/#{link.tmdb_id}/episodes"
      )
    end

    :ok
  end

  defp describe([{s, e}]), do: "S#{s}E#{e}"

  defp describe(pairs) do
    case pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq() do
      [s] ->
        {lo, hi} = pairs |> Enum.map(&elem(&1, 1)) |> Enum.min_max()
        "#{length(pairs)} episodes (S#{s}E#{lo}–E#{hi})"

      _ ->
        "#{length(pairs)} episodes"
    end
  end

  @doc """
  The episode that comes after the last one this person has watched, for a "we watched it"
  button: `%{season, episode, name}`, or nil when there is nothing further.
  """
  def next_up(uuid, tmdb_id) do
    with {:ok, title} <- watch().title("tv", tmdb_id, uuid),
         do: watch().next_unwatched(uuid, title)
  end

  @doc """
  "We watched it": mark the next episode for everyone in the link, whatever the page's "just me"
  says. `{:ok, %{season, episode}}`, or `{:error, :not_linked | :paused | :nothing_next}`.
  """
  def watched_together(uuid, tmdb_id) do
    with %{members: members} <- active(uuid, tmdb_id) || {:error, :not_linked},
         %{paused: false} <- Enum.find(members, &(&1.uuid == uuid)) || {:error, :not_linked},
         {:ok, title} <- watch().title("tv", tmdb_id, uuid),
         %{season: s, episode: e} <-
           watch().next_unwatched(uuid, title) || {:error, :nothing_next} do
      watch().set_watched(uuid, title, s, e, true)
      {:ok, %{season: s, episode: e}}
    else
      %{paused: true} -> {:error, :paused}
      {:error, _} = error -> error
      _ -> {:error, :not_linked}
    end
  end

  @doc """
  Time spent watching together, from this person's side:
  `%{minutes, episodes, shows, partners: [%{name, minutes}], titles: [%{tmdb_id, name, minutes}]}`.
  Only what was marked for two or more people through a link counts, from the day links existed.
  """
  def together(uuid) when is_binary(uuid) do
    me = dump(uuid)

    [[minutes, episodes, shows]] =
      rows(
        """
        select coalesce(sum(minutes), 0)::int, count(*)::int, count(distinct tmdb_id)::int
          from roki_link_events where $1 = any(participants)
        """,
        [me]
      )

    partners =
      for [user, name, mins] <-
            rows(
              """
              select p, u.username, sum(e.minutes)::int
                from roki_link_events e
                cross join lateral unnest(e.participants) p
                left join phoenix_kit_users u on u.uuid = p
               where $1 = any(e.participants) and p <> $1
               group by p, u.username order by 3 desc limit 8
              """,
              [me]
            ),
          do: %{uuid: load(user), name: name || "someone", minutes: mins}

    titles =
      for [tmdb_id, name, mins] <-
            rows(
              """
              select e.tmdb_id, t.name, sum(e.minutes)::int
                from roki_link_events e
                left join roki_titles t on t.type = 'tv' and t.id = e.tmdb_id
               where $1 = any(e.participants)
               group by e.tmdb_id, t.name order by 3 desc limit 5
              """,
              [me]
            ),
          do: %{tmdb_id: tmdb_id, name: name || "a show", minutes: mins}

    %{minutes: minutes, episodes: episodes, shows: shows, partners: partners, titles: titles}
  end

  # ── rounds: rating a finished season together ────────────────────

  # The marks just carried may have finished a season: its last aired episode is among them.
  # Open a round for it (once), and one for the series if that season was the last of a show
  # that has ended. Everyone in the link is told.
  defp open_rounds(uuid, tmdb_id, title, pairs) do
    link = active(uuid, tmdb_id)

    for season <- pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq(), link != nil do
      case watch().finale_facts(uuid, title, season) do
        %{last: last} = facts when is_integer(last) ->
          if {season, last} in pairs do
            open_round(link, season, title)
            if facts.series_end?, do: open_round(link, nil, title)
          end

        _ ->
          :ok
      end
    end

    :ok
  end

  defp open_round(link, season, title) do
    case rows(
           """
           insert into roki_link_rounds (link_id, season, inserted_at, updated_at)
           values ($1, $2, now(), now()) on conflict do nothing returning id
           """,
           [to_bin(link.id), season]
         ) do
      [[_id]] ->
        what = if season, do: "season #{season}", else: "the whole series"

        for m <- link.members, m.status == "active" do
          Roki.Social.notify_system(
            m.uuid,
            "link_round",
            "You finished #{what} of #{title.title} together. How was it?",
            "hero-star",
            "/title/tv/#{link.tmdb_id}/episodes"
          )
        end

      _ ->
        :ok
    end
  end

  @doc """
  The rounds of this person's link on a show, newest first:
  `[%{id, season, revealed, mine, answered, total, scores}]`. `mine` is `{:score, n}`, `:skipped`
  or nil (not answered); `scores` (everyone's, with names) only once revealed.
  """
  def rounds(uuid, tmdb_id) do
    case active(uuid, tmdb_id) do
      nil ->
        []

      link ->
        active_members = Enum.filter(link.members, &(&1.status == "active"))

        for [id, season, revealed] <-
              rows(
                "select id, season, revealed from roki_link_rounds where link_id = $1 order by inserted_at desc limit 5",
                [to_bin(link.id)]
              ) do
          scores =
            for [user, score, skipped] <-
                  rows(
                    "select user_uuid, score, skipped from roki_link_scores where round_id = $1",
                    [id]
                  ),
                do: %{uuid: load(user), score: score, skipped: skipped}

          mine = Enum.find(scores, &(&1.uuid == uuid))

          %{
            id: load(id),
            season: season,
            revealed: revealed,
            mine:
              cond do
                mine == nil -> nil
                mine.skipped -> :skipped
                true -> {:score, mine.score}
              end,
            answered: length(scores),
            total: length(active_members),
            scores:
              if(revealed,
                do:
                  for(
                    s <- scores,
                    m = Enum.find(active_members, &(&1.uuid == s.uuid)),
                    do: %{name: m.name, score: s.score, skipped: s.skipped}
                  ),
                else: []
              )
          }
        end
    end
  end

  @doc """
  Give a score (0.5 to 10, in halves) for a round, or `:skip`. Shows everyone's once all active
  members have answered. `save_to_tmdb?: true` also puts the score on the person's own TMDB rating
  of the show (series rounds only). `:ok` or `{:error, why}`.
  """
  def rate(uuid, round_id, score, opts \\ []) do
    with %{} = round <- round_of(round_id),
         true <- member_of_round?(uuid, round),
         {:ok, value} <- score_value(score) do
      rows(
        """
        insert into roki_link_scores (round_id, user_uuid, score, skipped, inserted_at, updated_at)
        values ($1, $2, $3, $4, now(), now())
        on conflict (round_id, user_uuid) do update
          set score = excluded.score, skipped = excluded.skipped, updated_at = now()
        """,
        [to_bin(round_id), dump(uuid), if(value == :skip, do: nil, else: value), value == :skip]
      )

      maybe_reveal(round)

      if opts[:save_to_tmdb?] == true and round.season == nil and is_float(value),
        do: save_rating(uuid, round.tmdb_id, value)

      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :not_in_round}
    end
  end

  @doc "Show everyone's scores now, without waiting for the rest."
  def reveal(uuid, round_id) do
    with %{} = round <- round_of(round_id), true <- member_of_round?(uuid, round) do
      rows("update roki_link_rounds set revealed = true, updated_at = now() where id = $1", [
        to_bin(round_id)
      ])

      :ok
    else
      _ -> {:error, :not_in_round}
    end
  end

  defp score_value(:skip), do: {:ok, :skip}

  defp score_value(score) do
    value =
      case score do
        n when is_number(n) -> n * 1.0
        s when is_binary(s) -> with {n, _} <- Float.parse(s), do: n
        _ -> nil
      end

    if is_float(value) and value >= 0.5 and value <= 10,
      do: {:ok, Float.round(value * 2) / 2},
      else: {:error, :bad_score}
  end

  defp round_of(round_id) do
    case rows(
           """
           select r.link_id, r.season, l.tmdb_id from roki_link_rounds r
             join roki_links l on l.id = r.link_id where r.id = $1
           """,
           [to_bin(round_id)]
         ) do
      [[link_id, season, tmdb_id]] ->
        %{id: round_id, link_id: link_id, season: season, tmdb_id: tmdb_id}

      _ ->
        nil
    end
  end

  defp member_of_round?(uuid, round),
    do:
      rows(
        "select 1 from roki_link_members where link_id = $1 and user_uuid = $2 and status = 'active'",
        [round.link_id, dump(uuid)]
      ) != []

  defp maybe_reveal(round) do
    [[total]] =
      rows("select count(*) from roki_link_members where link_id = $1 and status = 'active'", [
        round.link_id
      ])

    [[answered]] =
      rows(
        """
        select count(*) from roki_link_scores s join roki_link_members m
          on m.user_uuid = s.user_uuid and m.link_id = $2 and m.status = 'active'
         where s.round_id = $1
        """,
        [to_bin(round.id), round.link_id]
      )

    if answered >= total,
      do:
        rows("update roki_link_rounds set revealed = true, updated_at = now() where id = $1", [
          to_bin(round.id)
        ])
  end

  defp save_rating(uuid, tmdb_id, value) do
    with {:ok, title} <- watch().title("tv", tmdb_id, uuid),
         do: watch().rate(uuid, title, value, nil)
  rescue
    _ -> :error
  end

  defp carry(uuid, title, pairs, tmdb_id) do
    watch().set_many_watched(uuid, title, pairs, true, mirrored: true)
    announce(uuid, tmdb_id)
  end

  # An open page of that account hears that its marks changed under it.
  defp announce(uuid, tmdb_id),
    do: Phoenix.PubSub.broadcast(Roki.PubSub, "link:#{uuid}", {:link_marked, tmdb_id})

  # ── small pieces ───────────────────────────────────────────────────

  defp link(id) do
    case rows(
           "select id, tmdb_id, fresh, created_by from roki_links where id = $1 and status = 'active'",
           [to_bin(id)]
         ) do
      [[lid, tmdb_id, fresh, created_by]] ->
        %{id: load(lid), tmdb_id: tmdb_id, fresh: fresh, created_by: load(created_by)}

      _ ->
        nil
    end
  end

  defp invited?(uuid, link_id),
    do:
      rows(
        "select 1 from roki_link_members where link_id = $1 and user_uuid = $2 and status = 'invited'",
        [to_bin(link_id), dump(uuid)]
      ) != []

  defp set_status(uuid, link_id, status),
    do:
      rows(
        "update roki_link_members set status = $3, updated_at = now() where link_id = $1 and user_uuid = $2",
        [to_bin(link_id), dump(uuid), status]
      )

  defp end_if_alone(link_id) do
    [[n]] =
      rows("select count(*) from roki_link_members where link_id = $1 and status = 'active'", [
        to_bin(link_id)
      ])

    if n < 2,
      do:
        rows("update roki_links set status = 'ended', updated_at = now() where id = $1", [
          to_bin(link_id)
        ])
  end

  defp snapshot(link_id, uuid, pairs) do
    rows(
      "insert into roki_link_snapshots (link_id, user_uuid, removed, inserted_at, updated_at) values ($1, $2, $3, now(), now())",
      [to_bin(link_id), dump(uuid), %{"pairs" => for({s, e} <- pairs, do: [s, e])}]
    )
  end

  defp username(uuid) do
    case rows("select username from phoenix_kit_users where uuid = $1", [dump(uuid)]) do
      [[name]] -> name
      _ -> "Someone"
    end
  end

  defp title_name(tmdb_id, uuid) do
    case watch().title("tv", tmdb_id, uuid) do
      {:ok, %{title: name}} when is_binary(name) -> name
      _ -> "a show"
    end
  end

  defp rows(sql, params), do: Repo.query!(sql, params).rows
  defp dump(uuid), do: Ecto.UUID.dump!(uuid)
  defp to_bin(id) when is_binary(id) and byte_size(id) == 16, do: id
  defp to_bin(id), do: Ecto.UUID.dump!(id)

  defp load(bin) when byte_size(bin) == 16, do: Ecto.UUID.load!(bin)
  defp load(str), do: str
end
