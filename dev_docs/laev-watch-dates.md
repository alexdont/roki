# Brief 2 for laev: a resume stamp is not a watch date

Follow-on to [the first brief](laev-stint-tracking.md), written 2026-10-29 after `0.1.46`
landed. One bug, one small question, one optional feature.

## First: 0.1.46 is good, and roki has pulled it

Both halves work. The tick log is written and synced (`:ticks` in `@collections`, `read_dir` /
`apply_dir`, per-device files), and the in-place tail folding is the right call — it saved roki
from an importer that would have double-counted every time the tail line grew. Roki now reads
the sessions at query time instead (`Roki.Stints`), stopped writing its own watching into the
`stint` table, and deleted its `fold_entry` workaround. The new fold gives this account the
same answer the workaround did, title for title:

```
Pulse  1h 59m    Runner  1h 37m    Mutiny  1h 36m    Hope  2h 37m
```

(All-time came out 9h 28m lower than roki's version — 6963h 50m against 6973h 18m, 0.1%.
Probably anime-episode runtime keys; yours is authoritative and nobody chased it.)

**One small question:** `0.1.46` declares `elixir: "~> 1.20"`. Roki's container runs 1.19.6, so
every `mix deps.compile` prints `the dependency :laev requires Elixir "~> 1.20"`. It compiles
and runs fine. If 1.20 is not actually needed, `~> 1.19` would drop a standing warning; if it
is needed, say so in the changelog and roki will plan the toolchain bump instead.

## The bug: opening a title stamps it as watched

A resume entry's `updated_at` is written **when a source is resolved**, before anything plays:

```elixir
# lib/laev/cli.ex:6268 — right after handing the stream to mpv
Laev.Resume.put(entry["type"], entry["tmdb_id"],
  Map.put(entry, "updated_at", System.os_time(:second)))
```

`Shelf.last_watched_at/2` then reads that as *when you last watched this*:

```elixir
defp last_watched_at(type, id) do
  case Laev.Resume.get(type, id) do
    %{"updated_at" => at} when is_integer(at) -> at
    _ -> 0
  end
end
```

and three places in `shelf.ex` build a row's `watched_at` from it (lines ~269, ~428, ~561).
So pressing play and closing the player five seconds later tells every screen you watched that
title today — the shelf's ordering, `laev stats`' windows, and anything downstream.

### What it did on the account this was found on

Witch Hat Atelier (`mal-51553`), watched years ago on MyAnimeList, before laev existed:

```
8 episodes  pos=seen        ← MAL marks, imported
e1          played=6 0 6    ← six measured seconds: a test of a browser player
resume tv/196950  updated_at = 2026-10-22 18:14:57
  "source" => "[Shroud] Witch Hat Atelier (Season 1) (Vol 1) [1080p BD REMUX AVC FLAC]"
```

`watched_at` became `max(MAL's 2026-09-24, that stamp)` = 22 October, and **3h 09m of marked
episodes — eight marks at MAL's 1420s each, none of it measured — landed in the last seven
days.** The runtime was right; the date was invented by a six-second test.

### Suggested fix, in one function

A resume stamp is a fact about the player being opened. It should only be read as a date when
something was actually watched under it — which the tick log can now say. Layered, so nothing
recorded before `0.1.46` is thrown away:

```elixir
# Seconds of measurement under which a play is an open-and-close rather than a viewing.
@played_floor_s 120

defp last_watched_at(type, id) do
  stamp =
    case Laev.Resume.get(type, id) do
      %{"updated_at" => at} when is_integer(at) -> at
      _ -> 0
    end

  cond do
    # 1. A session in the tick log: the one thing that was measured.
    at = last_session_at(type, id) -> at
    # 2. Before the tick log existed, a real measurement proves itself.
    measured_seconds(type, id) >= @played_floor_s -> stamp
    # 3. Otherwise the stamp says only that the player was opened, which is not a date.
    #    (`rows/0` already prefers MAL's own `updated` where there is one — keep that, and it
    #    becomes the answer for anime, which is what it should always have been.)
    true -> 0
  end
end
```

`last_session_at/2` is `Laev.Stints.sessions/1` filtered to that title's item (`item/1` already
folds `tv-110316-s1e5` to `tv-110316`); `measured_seconds/2` is the first number of
`played/<key>` summed over the title's episodes. Both are small file reads, and both are
already in the tree.

Two notes on shape. The third branch returning `0` is "undated", which is better than a wrong
date but is a visible change for titles that have neither a session, a measurement, nor a MAL
entry — mostly things opened once and abandoned, which arguably *should* be undated. If that is
too blunt, keeping `stamp` there is safe too: the fix that matters is branch 1 and 2 taking
precedence. And if you would rather not change what `updated_at` means, the alternative is a
second field — `updated_at` for "last touched", which is what orders *continue watching* and
must keep being stamped at resolution, and a new `watched_at` set only from a real sample. That
is the cleaner separation, and it is why the one field cannot serve both.

Roki does this layering now in `Roki.Laev.watched_at/4` (commit `384313d`). Across this
account's 78 unfinished titles exactly two dates moved, both earlier, none lost: Witch Hat
Atelier 6d → 35d ago, and one more anime 55d → 161d. **If this lands in laev, roki deletes its
copy** — same as the `fold_entry` workaround.

Roki's own half of the same mistake is `lib/roki/watch.ex:1851`, which stamps `updated_at` when
it remembers the source. It will stop doing that in whatever way matches what you decide here,
so the two ends agree.

## Optional, and bigger: per-episode dates from MyAnimeList

Asked for directly: "pull from my MAL list activity and check when the last episodes were
marked off".

API v2 cannot do it. `my_list_status` carries `num_watched_episodes` and one `updated_at` for
the whole entry — which is what `Laev.MAL` already reads and what the fix above leans on. There
is no per-episode history endpoint.

The website has it, at `myanimelist.net/history/<user>` and `/history/<user>/<anime_id>`, with a
timestamp per episode. That is a scrape, not an API: retention and markup would both need
checking before anything depended on it, and it belongs beside the rest of the MAL integration
rather than in a consumer. If it is worth doing, the shape would be: fetch during `mal import`,
store per-episode timestamps next to the marks, and let `Stats` date a marked episode by its own
day instead of the entry's. That would make backdating unnecessary for everything ever marked on
MyAnimeList — currently the only fix is to set the date by hand on the site.

## Release

`0.1.47`, and in the changelog say whether `last_watched_at/2` changed and under what rule, so
roki knows to drop its copy.
