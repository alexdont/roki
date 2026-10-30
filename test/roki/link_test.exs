defmodule Roki.LinkTest do
  use Roki.DataCase, async: false

  alias Roki.Link

  @show 4242

  setup do
    Roki.LinkFakeWatch.start()
    Application.put_env(:roki, :link_watch, Roki.LinkFakeWatch)

    on_exit(fn ->
      Application.delete_env(:roki, :link_watch)
      Roki.LinkFakeWatch.stop()
    end)

    make = fn name ->
      {:ok, u} =
        PhoenixKit.Users.Auth.register_user(%{
          "email" => "#{name}@example.com",
          "password" => "a-long-enough-password-123",
          "username" => name
        })

      u.uuid
    end

    [alex, max, sam] = Enum.map(~w(linkalex linkmax linksam), make)

    for other <- [max, sam] do
      Roki.Social.request(alex, other)
      Roki.Social.accept(other, alex)
    end

    {:ok, alex: alex, max: max, sam: sam}
  end

  defp eps(season, range), do: for(e <- range, do: {season, e})

  defp join!(inviter, invitee, choice \\ nil) do
    {:ok, id} = Link.invite(inviter, @show, [invitee])
    Link.accept(invitee, id, choice)
  end

  test "only friends can be invited", %{alex: alex} do
    {:ok, stranger} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "linkstranger@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "linkstranger"
      })

    assert {:error, :not_friends} = Link.invite(alex, @show, [stranger.uuid])
    assert {:error, :nobody} = Link.invite(alex, @show, [])
  end

  test "an invitation waits until it is accepted, and nothing is carried before", %{
    alex: alex,
    max: max
  } do
    {:ok, id} = Link.invite(alex, @show, [max])
    assert %{link_id: ^id, from: "linkalex"} = Link.invitation(max, @show)
    assert Link.active(max, @show) == nil

    Roki.LinkFakeWatch.put(alex, eps(1, 1..3))
    Link.mirror(alex, @show, eps(1, 4..4))
    assert Roki.LinkFakeWatch.get(max) == MapSet.new()
  end

  test "nobody has watched anything: it just links, then marks go both ways", %{
    alex: alex,
    max: max
  } do
    assert {:ok, :link} = join!(alex, max)
    assert %{members: members} = Link.active(alex, @show)
    assert Enum.sort(Enum.map(members, & &1.name)) == ["linkalex", "linkmax"]

    Link.mirror(alex, @show, eps(1, 1..2))
    assert Roki.LinkFakeWatch.get(max) == MapSet.new(eps(1, 1..2))

    Link.mirror(max, @show, eps(1, 3..3))
    assert Roki.LinkFakeWatch.get(alex) == MapSet.new(eps(1, 3..3))
  end

  test "the side with progress is the truth: an empty account is filled without a question", %{
    alex: alex,
    max: max
  } do
    Roki.LinkFakeWatch.put(alex, eps(1, 1..6))
    assert {:ok, {:fill_me, 6}} = join!(alex, max)
    assert Roki.LinkFakeWatch.get(max) == MapSet.new(eps(1, 1..6))
  end

  test "an invited account with progress fills the one who invited", %{alex: alex, max: max} do
    Roki.LinkFakeWatch.put(max, eps(1, 1..4))
    assert {:ok, {:fill_others, 4}} = join!(alex, max)
    assert Roki.LinkFakeWatch.get(alex) == MapSet.new(eps(1, 1..4))
  end

  test "when both have progress and it differs, the joiner is asked which is right", %{
    alex: alex,
    max: max
  } do
    Roki.LinkFakeWatch.put(alex, eps(1, 1..8))
    Roki.LinkFakeWatch.put(max, eps(1, 1..2))

    {:ok, id} = Link.invite(alex, @show, [max])
    assert {:choose, %{mine: 2, others: [%{uuid: ^alex, count: 8}]}} = Link.plan(max, id)
    assert {:needs_choice, {:choose, _}} = Link.accept(max, id)
    assert Link.active(max, @show) == nil

    # Alex's is right: Max gains six, nothing is taken off anyone.
    assert {:ok, {:choose, _}} = Link.accept(max, id, alex)
    assert Roki.LinkFakeWatch.get(max) == MapSet.new(eps(1, 1..8))
    refute Link.undoable?(max, id)
  end

  test "choosing the shorter progress takes the extra off, and undo puts it back", %{
    alex: alex,
    max: max
  } do
    Roki.LinkFakeWatch.put(alex, eps(1, 1..8))
    Roki.LinkFakeWatch.put(max, eps(1, 1..2))

    {:ok, id} = Link.invite(alex, @show, [max])
    assert {:ok, _} = Link.accept(max, id, max)

    assert Roki.LinkFakeWatch.get(alex) == MapSet.new(eps(1, 1..2))
    assert Link.undoable?(alex, id)

    assert {:ok, 6} = Link.undo(alex, id)
    assert Roki.LinkFakeWatch.get(alex) == MapSet.new(eps(1, 1..8))
    assert Link.undo(alex, id) == :nothing
  end

  test "just me, and a pause on either side, keep a mark from travelling", %{alex: alex, max: max} do
    join!(alex, max)

    Link.mirror(alex, @show, eps(1, 1..1), solo: true)
    assert Roki.LinkFakeWatch.get(max) == MapSet.new()

    Link.pause(alex, Link.active(alex, @show).id, true)
    Link.mirror(alex, @show, eps(1, 1..1))
    assert Roki.LinkFakeWatch.get(max) == MapSet.new()

    # Alex is paused, so Max's marks do not reach Alex either.
    Link.mirror(max, @show, eps(1, 2..2))
    assert Roki.LinkFakeWatch.get(alex) == MapSet.new()

    Link.pause(alex, Link.active(alex, @show).id, false)
    Link.mirror(max, @show, eps(1, 3..3))
    assert Roki.LinkFakeWatch.get(alex) == MapSet.new(eps(1, 3..3))

    # Marks that were themselves carried are not carried on: Max never hears of episode 9.
    Link.mirror(alex, @show, eps(1, 9..9), mirrored: true)
    assert Roki.LinkFakeWatch.get(max) == MapSet.new()
  end

  test "a group can be any size: a mark from anyone reaches everyone", %{
    alex: alex,
    max: max,
    sam: sam
  } do
    {:ok, id} = Link.invite(alex, @show, [max, sam])
    Link.accept(max, id)
    Link.accept(sam, id)

    Link.mirror(sam, @show, eps(2, 1..2))
    assert Roki.LinkFakeWatch.get(alex) == MapSet.new(eps(2, 1..2))
    assert Roki.LinkFakeWatch.get(max) == MapSet.new(eps(2, 1..2))

    # A third person is brought to the group's point when they join.
    assert [%{tmdb_id: @show, with: with_}] = Link.linked_shows(alex)
    assert Enum.sort(with_) == ["linkmax", "linksam"]
  end

  test "leaving: the link ends when fewer than two are left", %{alex: alex, max: max} do
    join!(alex, max)
    id = Link.active(alex, @show).id
    Link.leave(max, id)

    assert Link.active(alex, @show) == nil
    Link.mirror(alex, @show, eps(1, 1..1))
    assert Roki.LinkFakeWatch.get(max) == MapSet.new()
  end

  test "start over: a fresh link, earlier marks neither compared nor touched", %{
    alex: alex,
    max: max
  } do
    Roki.LinkFakeWatch.put(alex, eps(1, 1..8))
    Roki.LinkFakeWatch.put(max, eps(1, 1..2))
    {:ok, id} = Link.invite(alex, @show, [max])
    Link.accept(max, id, alex)

    {:ok, fresh} = Link.start_over(alex, id)
    assert Link.active(alex, @show).id == fresh
    assert %{link_id: ^fresh, fresh: true} = Link.invitation(max, @show)

    Roki.LinkFakeWatch.put(max, eps(1, 1..3))
    assert {:ok, :link} = Link.accept(max, fresh)
    assert Roki.LinkFakeWatch.get(max) == MapSet.new(eps(1, 1..3))
    assert Roki.LinkFakeWatch.get(alex) == MapSet.new(eps(1, 1..8))

    # From now on it carries what is marked.
    Link.mirror(alex, @show, eps(1, 9..9))
    assert MapSet.member?(Roki.LinkFakeWatch.get(max), {1, 9})
  end

  test "declining ends an invitation for good", %{alex: alex, max: max} do
    {:ok, id} = Link.invite(alex, @show, [max])
    Link.decline(max, id)
    assert Link.invitation(max, @show) == nil
    assert Link.accept(max, id) == {:error, :no_invitation}
  end

  describe "rounds" do
    test "finishing a season together opens a round once; the series round comes with the last season",
         %{alex: alex, max: max} do
      join!(alex, max)

      Link.mirror(alex, @show, eps(1, 1..10))
      assert [%{season: 1, revealed: false, mine: nil, total: 2}] = Link.rounds(alex, @show)

      # Again, or an earlier episode, opens nothing new.
      Link.mirror(alex, @show, eps(1, 10..10))
      assert length(Link.rounds(alex, @show)) == 1

      Link.mirror(max, @show, eps(2, 10..10))
      assert Enum.map(Link.rounds(alex, @show), & &1.season) |> Enum.sort() == [1, 2, nil]
    end

    test "scores show together once everyone answered, not before", %{alex: alex, max: max} do
      join!(alex, max)
      Link.mirror(alex, @show, eps(1, 10..10))
      [%{id: id}] = Link.rounds(alex, @show)

      assert :ok = Link.rate(alex, id, "8")
      [r] = Link.rounds(max, @show)
      refute r.revealed
      assert r.answered == 1 and r.mine == nil and r.scores == []

      assert :ok = Link.rate(max, id, 9.5)
      [r] = Link.rounds(alex, @show)
      assert r.revealed
      assert r.mine == {:score, 8.0}

      assert Enum.sort_by(r.scores, & &1.name) |> Enum.map(&{&1.name, &1.score}) ==
               [{"linkalex", 8.0}, {"linkmax", 9.5}]
    end

    test "a skip counts as an answer, 'show now' does not wait, and bad scores are refused", %{
      alex: alex,
      max: max,
      sam: sam
    } do
      join!(alex, max)
      Link.mirror(alex, @show, eps(1, 10..10))
      [%{id: id}] = Link.rounds(alex, @show)

      assert {:error, :bad_score} = Link.rate(alex, id, "11")
      assert {:error, :bad_score} = Link.rate(alex, id, "abc")
      assert {:error, :not_in_round} = Link.rate(sam, id, "5")
      assert {:error, :not_in_round} = Link.reveal(sam, id)

      assert :ok = Link.rate(alex, id, :skip)
      assert :ok = Link.rate(max, id, "6.3")
      [r] = Link.rounds(alex, @show)
      assert r.revealed
      assert r.mine == :skipped
      assert Enum.any?(r.scores, &(&1.name == "linkmax" and &1.score == 6.5))

      # Show now, with only one answer in.
      Link.mirror(alex, @show, eps(2, 10..10))
      [first | _] = Link.rounds(alex, @show)
      Link.rate(alex, first.id, "7")
      assert :ok = Link.reveal(alex, first.id)
      assert Enum.find(Link.rounds(alex, @show), &(&1.id == first.id)).revealed
    end

    test "only a series round can also save the score as the person's TMDB rating", %{
      alex: alex,
      max: max
    } do
      join!(alex, max)
      Link.mirror(alex, @show, eps(2, 10..10))
      rounds = Link.rounds(alex, @show)
      season = Enum.find(rounds, &(&1.season == 2))
      series = Enum.find(rounds, &(&1.season == nil))

      Link.rate(alex, season.id, "9", save_to_tmdb?: true)
      assert Roki.LinkFakeWatch.rated(alex) == nil

      Link.rate(alex, series.id, "9", save_to_tmdb?: true)
      assert Roki.LinkFakeWatch.rated(alex) == 9.0
      Link.rate(max, series.id, "5")
      assert Roki.LinkFakeWatch.rated(max) == nil
    end
  end

  describe "watching together" do
    defp bell_count(uuid) do
      {:ok, bin} = Ecto.UUID.dump(uuid)

      Roki.Repo.query!(
        "select count(*) from phoenix_kit_activities where action = 'roki.link_marked' and target_uuid = $1",
        [bin]
      ).rows
      |> hd()
      |> hd()
    end

    test "episodes carried are added up as time together, once each, for everyone in on them", %{
      alex: alex,
      max: max,
      sam: sam
    } do
      {:ok, id} = Link.invite(alex, @show, [max, sam])
      Link.accept(max, id)
      Link.accept(sam, id)
      Link.pause(sam, id, true)

      Link.mirror(alex, @show, eps(1, 1..3))
      # The same episodes again add nothing.
      Link.mirror(max, @show, eps(1, 2..4))

      assert %{minutes: 96, episodes: 4, shows: 1, partners: [%{name: "linkmax", minutes: 96}]} =
               Link.together(alex)

      # Sam was paused: not in on any of it.
      assert %{minutes: 0, episodes: 0, partners: []} = Link.together(sam)
      # Max's own 2..4 added only episode 4, but he was in on all four.
      assert %{minutes: 96, episodes: 4} = Link.together(max)
    end

    test "just me and an alone mark are not time together", %{alex: alex, max: max} do
      join!(alex, max)
      Link.mirror(alex, @show, eps(1, 1..2), solo: true)
      Link.pause(max, Link.active(alex, @show).id, true)
      Link.mirror(alex, @show, eps(1, 3..3))
      assert %{episodes: 0, minutes: 0} = Link.together(alex)
    end

    test "the bell rings once per show per ten minutes, and not for someone who switched it off",
         %{alex: alex, max: max, sam: sam} do
      {:ok, id} = Link.invite(alex, @show, [max, sam])
      Link.accept(max, id)
      Link.accept(sam, id)
      Roki.Notify.set(sam, "link", false)

      Link.mirror(alex, @show, eps(1, 1..1))
      Link.mirror(alex, @show, eps(1, 2..2))
      Link.mirror(alex, @show, eps(1, 3..4))

      assert bell_count(max) == 1
      assert bell_count(sam) == 0
      assert bell_count(alex) == 0
    end

    test "'we watched it' marks the next episode for everyone, unless paused", %{
      alex: alex,
      max: max
    } do
      Roki.LinkFakeWatch.put(alex, eps(1, 1..3))
      Roki.LinkFakeWatch.put(max, eps(1, 1..3))
      join!(alex, max)

      assert %{season: 1, episode: 4} = Link.next_up(alex, @show)
      assert {:ok, %{season: 1, episode: 4}} = Link.watched_together(alex, @show)
      assert MapSet.member?(Roki.LinkFakeWatch.get(max), {1, 4})
      assert %{season: 1, episode: 5} = Link.next_up(max, @show)

      # It does not matter whose account the tap is on.
      assert {:ok, %{episode: 5}} = Link.watched_together(max, @show)
      assert MapSet.member?(Roki.LinkFakeWatch.get(alex), {1, 5})

      Link.pause(alex, Link.active(alex, @show).id, true)
      assert {:error, :paused} = Link.watched_together(alex, @show)
      assert {:error, :not_linked} = Link.watched_together(Ecto.UUID.generate(), @show)
    end
  end
end
