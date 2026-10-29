# Brief for laev: watching should keep stints

For whoever works on `laev` (github.com/alexdont/laev, currently `0.1.45`). Two changes, one
feature and one bug. Both were found from roki's side, where the consequences show up on the
stats page; both belong in laev, where the two files involved are already open.

Written 2026-10-29 from roki-ee. Roki's side of the feature is already built and waiting
(`Roki.Stints`, commits `43eefd2` and later), so the contract below is what roki expects —
please keep the file format exactly as written, or tell us what you changed.

---

## 1. The feature: a tick log, and sessions folded from it

### Why

laev records two things about a play and neither can say *when*:

| file | holds | cannot say |
|---|---|---|
| `played/<key>` | `watched skipped [reported]` — seconds measured for that title, cumulatively | when any of it happened |
| `watched/<device>.log` | `<date> <seconds>` per day | what filled the day |

So "what was I watching on Tuesday evening" is unanswerable, and a stats window over watching
has to carry a title's whole history in on the strength of one play. Reading has had this for
a while on roki's side (the `stint` hex package, tick-based: sessions assemble themselves and
nobody has to remember to call stop), and watching should match.

`stint` itself is Ecto/Postgres-backed, so laev cannot use the package — laev is file-backed
and has no repo, and it should stay that way. What laev writes instead is the **raw tick log**,
which is the honest primitive: the server assembles it into `stint` rows for the account,
the CLI can assemble the same sessions from the same lines, and there is exactly one record.

### The file format — this is the contract roki reads

```
ticks/<device-id>.log          append-only, one file per device, never rewritten
```

One line per sample:

```
1793000120 movie-27324 5
<unix seconds> <position key> <seconds measured by that sample>
```

- the key is the one `positions/` and `played/` already use (`movie-603`, `tv-110316-s1e5`,
  `mal-1425-e12`);
- per device for the same reason `watched/<device>.log` is: nothing but that machine writes to
  that file, so a file per device merges exactly while a shared one could only be merged by
  letting one device overwrite another;
- a half-written line (something killed mid-append) is skipped by the parser, never a parse
  error — the log is only ever appended to and never repaired.

### The code

Add `lib/laev/stints.ex`. The draft below compiles against `0.1.45` but has **not** been run
(the box this was written on has no Elixir outside a container) — please review it as a draft,
not as tested code.

```elixir
defmodule Laev.Stints do
  @moduledoc """
  A tick log of what was watched, when, and for how long — and the sessions it folds into.

  The day log beside this one (`watched/<device>.log`) says how many seconds a day held and
  nothing about what filled them; `played/<key>` says how long a title has had and nothing
  about when. Neither can answer "what was I watching on Tuesday evening", and a window over
  either has to carry a title's whole history in on the strength of one play.

  So every sample laev records writes one line here as well:

      1793000120 movie-27324 5

  Unix seconds, the key the position files already use, and the seconds that sample measured.
  Append-only, one file per device — the same arrangement the day log settled on, and for the
  same reason: nothing but this machine writes to this file, so a file per device merges
  exactly while a shared one could only be merged by letting one device overwrite another.

  `sessions/1` folds the ticks into bounded periods of activity: ticks closer together than
  the gap belong to one session, a longer silence starts the next. Session *ends* cannot be
  observed — players are killed, laptops close, phones lock — so they are inferred from the
  silence instead of reported, and nothing has to remember to call a stop.

  The fold is deliberately pure and the log is deliberately dumb. A server collecting an
  account's ticks from several devices can assemble exactly the same sessions from the same
  lines, which is the point: one record, assembled wherever it is needed.
  """

  # Ticks this close together are one session. The same default the reader's own stints use.
  @gap 120

  @doc "Where this machine's tick log lives."
  def log_file do
    dir = Path.join(data_dir(), "ticks")
    File.mkdir_p(dir)
    Path.join(dir, "#{Laev.Position.device_id()}.log")
  end

  @doc """
  Record `seconds` of watching on `key` (`movie-603`, `tv-110316-s1e5`, `mal-1425-e12`).

  Called from `Laev.Position.record/2`, which every player goes through, so the mpv script,
  the VLC poller and a browser all land here. Nothing under a second is worth a line.
  """
  def tick(key, seconds, at \\ nil)

  def tick(key, seconds, at) when is_binary(key) and is_integer(seconds) and seconds >= 1 do
    at = at || System.os_time(:second)
    File.write(log_file(), "#{at} #{key} #{seconds}\n", [:append])
    :ok
  rescue
    _ -> :ok
  end

  def tick(_key, _seconds, _at), do: :ok

  @doc """
  Every tick this account has, oldest first: `[{unix, key, seconds}]`.

  All devices' logs together, because a session is a fact about the account and the account is
  watched from more than one machine.
  """
  def ticks do
    dir = Path.join(data_dir(), "ticks")

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.flat_map(&read_log(Path.join(dir, &1)))
        |> Enum.sort_by(fn {at, _key, _seconds} -> at end)

      _ ->
        []
    end
  end

  defp read_log(path) do
    case File.read(path) do
      {:ok, body} -> body |> String.split("\n", trim: true) |> Enum.flat_map(&parse/1)
      _ -> []
    end
  end

  # A line laev did not write, or wrote half of when something was killed, is skipped rather
  # than allowed to end the parse: this log is only ever appended to and never repaired.
  defp parse(line) do
    with [at, key, seconds] <- String.split(line, " ", parts: 3),
         {at, ""} <- Integer.parse(at),
         {seconds, ""} <- Integer.parse(String.trim(seconds)),
         true <- key != "" do
      [{at, key, seconds}]
    else
      _ -> []
    end
  end

  @doc """
  The ticks folded into sessions, oldest first:
  `[%{item:, started_at:, ended_at:, seconds:, keys:}]`.

  `item` is the title a session was of — a run of episodes in one evening is one session, as
  an evening is — and `keys` is every position key it touched, in order, so the episodes are
  still there to be listed.

  `gap` is the silence that separates two sessions, in seconds.
  """
  def sessions(gap \\ @gap) do
    ticks()
    |> Enum.group_by(fn {_at, key, _seconds} -> item(key) end)
    |> Enum.flat_map(fn {item, ticks} -> fold(item, ticks, gap) end)
    |> Enum.sort_by(& &1.started_at)
  end

  defp fold(item, ticks, gap) do
    ticks
    |> Enum.reduce([], fn {at, key, seconds}, acc ->
      case acc do
        [%{ended_at: ended} = open | rest] when at - ended <= gap ->
          [
            %{
              open
              | ended_at: max(at, ended),
                seconds: open.seconds + seconds,
                keys: if(key in open.keys, do: open.keys, else: open.keys ++ [key])
            }
            | rest
          ]

        _ ->
          # The first tick of a session is backdated by its own length, so a session is never
          # shorter than the watching it holds.
          [%{item: item, started_at: at - seconds, ended_at: at, seconds: seconds, keys: [key]} | acc]
      end
    end)
    |> Enum.reverse()
  end

  @doc """
  The title a position key belongs to: `tv-110316-s1e5` and `tv-110316-s2e1` are both
  `tv-110316`, because an evening of a show is one session however many episodes it ran to.
  """
  def item(key) do
    case Regex.run(~r/^(movie|tv|mal)-(\d+)/, key) do
      [matched, _type, _id] -> matched
      _ -> key
    end
  end

  defp data_dir, do: Laev.Scope.dir()
end
```

### The hook — one line, in the one place every player funnels through

`Laev.Position.record/2` is where the mpv Lua script, the VLC poller and a browser all end up,
and `sample[:log_seconds]` is already "what the caller has watched since it last said so" —
exactly a tick. `key` is in scope there; it is not inside `log_seconds/1`, which is why the
call goes next to it rather than in it:

```diff
   def record(ctx, %{position: position, watched: watched, skipped: skipped} = sample) do
     with key when is_binary(key) <- key(ctx) do
       File.write(played_file(key), played_line(watched, skipped, sample[:reported]))
       log_seconds(sample[:log_seconds])
+      Laev.Stints.tick(key, sample[:log_seconds] || 0)
```

`tick/3` guards on `seconds >= 1`, so a sample that earned nothing writes no line.

### Sync — one collection, the `:watched` pattern exactly

`ticks/` is a directory of per-device append-only logs, which is what `watched/` already is, so
it rides along the same way. Three edits in `lib/laev/sync.ex`:

```diff
-  @collections [:watchlist, :resume, :positions, :tracks, :played, :watched, :holds, :anime, :seasons]
+  @collections [:watchlist, :resume, :positions, :tracks, :played, :watched, :ticks, :holds, :anime, :seasons]
```

```diff
       watched: read_dir(Path.join(data_dir(), "watched")),
+      ticks: read_dir(Path.join(data_dir(), "ticks")),
```

```diff
     apply_dir(Path.join(data_dir(), "watched"), merged[:watched] || %{})
+    apply_dir(Path.join(data_dir(), "ticks"), merged[:ticks] || %{})
```

Worth a look while you are in there: the tick log grows forever, one line per five seconds of
watching (~700 lines per film). That is a few hundred KB a year as text, which is fine on disk
but it all travels in the sync bundle. If that matters, the cheap fix is for `tick/3` to fold
consecutive ticks on the same key within the gap into the last line instead of appending —
same information, one line per session — or a `laev doctor` sweep that does it after the fact.
**Do not** compact in a way that changes the format roki parses; folding lines is invisible to
it, dropping the key or the timestamp is not.

### Tests worth having

- a tick appends a line, and a zero or nil tick appends nothing;
- `ticks/0` reads two devices' logs and returns them in time order;
- a half-line and a junk line are skipped, and the good lines around them survive;
- `sessions/1`: ticks inside the gap are one session, a longer silence starts another, and the
  first tick of a session is backdated by its own length so a session is never shorter than
  the watching it holds;
- `sessions/1` on a run of episodes of one show is **one** session whose `keys` lists each
  episode in order (`item/1` folds `tv-110316-s1e5` to `tv-110316`);
- the session's `seconds` is the sum of its ticks, not the wall time between its ends (a
  paused film ends its session later than it watched).

---

## 2. The bug: a measurement beats a finished mark, however small it is

`Laev.Stats.fold_entry/5` prefers the `played/` measurement over the position file whenever a
measurement exists:

```elixir
case {Map.get(played, name), seconds_for(progress, runtime)} do
  {%{watched: watched, skipped: past}, _} ->
    {bump(acc, key, names, watched, 0, progress), unknown, skipped + past, measured + 1}
```

That is right for a play the mpv script followed end to end. It is wrong whenever the position
file says `done`/`seen` and the measurement is a sliver — which is the ordinary browser case,
and was also happening in the CLI. Real rows from one account:

```
movie-27324   Pulse                pos=done   measured 293s   runtime 1h59m
movie-1377237 Runner               pos=seen   measured 151s   runtime 1h37m
movie-1288445 Mutiny               pos=seen   measured  47s   runtime 1h36m
movie-1058424 Hope                 pos=seen   measured  22s   runtime 2h37m
movie-299534  Avengers: Endgame    pos=seen   measured 254s   runtime 3h01m
```

19 titles on that account were short by **38h 24m** between them, and the films above read as
four minutes each in "the last 30 days" — which is what made this visible at all.

Suggested rule, which is what roki now does as a workaround: where the position says finished
and the measurement is under **half** the runtime, count the runtime and treat the difference
as *assumed* time — the bucket a hand mark already lands in, because that is what it is.
Nothing invented: an entry with no known runtime is left alone, and a play that really was
measured keeps its own figure.

Roki's workaround is `Roki.Stats.shortfalls/0` + `lift/2` + `lift_totals/2` (commit `e7713a1`)
— about 60 lines re-reading `positions/`, `played/` and `runtimes.json` from outside, which is
silly when the fold already has all three open. **If you fix it in laev, say so in the
changelog and we will delete ours.**

Note the two changes interact in the right direction: once ticks exist, a browser play that is
actually watched to the end will *also* have a real measurement, so the lift will stop firing
for new plays by itself. It is still needed for everything already recorded.

---

## 3. Release, and the pull on roki

1. Publish as **0.1.46** (both changes are additive; nothing existing changes shape).
2. Changelog entries worth writing explicitly, since roki keys off them:
   - `ticks/<device>.log` added, synced, `Laev.Stints.ticks/0` + `sessions/1`;
   - whether `fold_entry/5` was fixed, and under what rule.
3. On roki: bump `{:laev, "~> 0.1.45"}` to `"~> 0.1.46"` in `mix.exs`, `mix deps.get`,
   then **delete `Roki.Stats.shortfalls/0`, `lift/2`, `lift_totals/2` and
   `test/roki/stats_shortfall_test.exs`** if item 2 landed, and wire the tick import:
   roki will read `ticks/*.log` out of the account's laev scope and replay new lines into
   `Stint.track(uuid, "watch:<type>/<id>", seconds, at: ...)`, keeping a per-device watermark in
   `roki-ticks.json` beside the scope's existing `roki-web.json`. That import is roki's job, not
   laev's — the brief mentions it only so nobody builds it twice.

What roki already does with the ticks once they arrive: watching gets days of its own, so the
heatmap places it where it happened and a stats window over a title with sessions holds exactly
what those sessions put in it rather than the title's whole history. CLI watching is the half
that is still a lump, which is the whole reason for this brief.
