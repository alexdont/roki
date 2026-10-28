# Staging the old reader's data

`Roki.Manga.Import` copies manga reading out of the reader on `sasha.don.ee` (the
`:habit_tracker` app, database `dev_habit_tracker_db`). It does not connect to that database: the
reader's tables are copied into **this** database first, as the schema `reader_import`, and the
import reads only from there.

That keeps the promise the plan makes — the reader keeps serving and keeps its data. The steps
below only read from it, and `pg_dump` takes no lock that a reader would notice.

## Load it

From the host (the shared Postgres is `platform`'s; `psql.sh` connects as superuser):

```bash
R=/docker/platform/stacks/postgres
T="saved_manga reading_activity chapter_reads library_events manga_marks manga_annotations \
   chapter_page_overrides manga_categories manga_category_memberships manga_grid_slots \
   manga_tierlist manga_mal_links manga_metadata manga_story_data"
ARGS=""; for t in $T; do ARGS="$ARGS -t $t"; done

# The tables' shape, renamed into the staging schema.
docker exec postgres pg_dump -U postgres --schema-only $ARGS dev_habit_tracker_db \
  | grep -v "OWNER TO\|^--\|^$\|^SET \|^SELECT pg_catalog" \
  | sed 's/\bpublic\./reader_import./g' > /tmp/stage-schema.sql

# Their rows, as INSERTs so the schema rename is a single anchored substitution.
docker exec postgres pg_dump -U postgres --data-only --column-inserts $ARGS dev_habit_tracker_db \
  | sed 's/^INSERT INTO public\./INSERT INTO reader_import./' \
  | grep -v "^--\|^$\|^SET \|^SELECT pg_catalog" > /tmp/stage-data.sql

$R/psql.sh roki_ee -q -c "drop schema if exists reader_import cascade; create schema reader_import;"
docker cp /tmp/stage-schema.sql postgres:/tmp/ && docker cp /tmp/stage-data.sql postgres:/tmp/
docker exec postgres psql -U postgres -d roki_ee -q -v ON_ERROR_STOP=1 -f /tmp/stage-schema.sql
docker exec postgres psql -U postgres -d roki_ee -q -v ON_ERROR_STOP=1 -f /tmp/stage-data.sql
```

Then the reader's people, so the import can resolve a username on each side. Only the four
columns it needs — no password hashes, no tokens:

```bash
$R/psql.sh roki_ee -q -c \
  "create table reader_import.reader_users (uuid uuid primary key, username text, email text, confirmed boolean)"

docker exec postgres psql -U postgres -d dev_habit_tracker_db -Atc \
  "select uuid||'|'||coalesce(username::text,'')||'|'||email::text||'|'||(confirmed_at is not null) \
   from phoenix_kit_users" > /tmp/users.psv

awk -F'|' '{printf "insert into reader_import.reader_users values ('\''%s'\'','\''%s'\'','\''%s'\'',%s);\n", $1,$2,$3,$4}' \
  /tmp/users.psv > /tmp/users.sql
docker cp /tmp/users.sql postgres:/tmp/ && docker exec postgres psql -U postgres -d roki_ee -q -f /tmp/users.sql
```

The schema is created by the superuser, so the app's own role has to be let in — without this the
import sees nothing and `staged?` answers false:

```bash
$R/psql.sh roki_ee -q -c \
  "grant usage on schema reader_import to roki_ee; grant select on all tables in schema reader_import to roki_ee;"
```

## Use it

```bash
docker exec roki-ee bash -lc 'cd /www/app && PHX_SERVER=false mix roki.manga.import --rehearse'
```

## Afterwards

Once the cutover is done and the import has no further business running:

```bash
$R/psql.sh roki_ee -q -c "drop schema reader_import cascade;"
```
