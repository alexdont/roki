# PhoenixKit integration: the work to do

Written 2026-11-05 from a read of every place roki touches `phoenix_kit` (2.65.0, schema V225) and
its two companion packages. The verdict: the integration is clean and shallow in the good sense —
auth, media, notifications, comments and friends go through the kit's API, raw SQL against its
tables happens in one place (`Roki.Manga.CommentNotifier`), and the 2.54 → 2.65 jump cost one
commit. What follows is the work that remains, in two lists: ours, and the kit's.

The kit-side list is also published as a page for the phoenix_kit agent, with source pointers
into 2.65.0: https://claude.ai/artifact/TMcvNF59wh3AjpQVCpedhv (private until shared).

## Ours, in order

- [ ] **1. Custom fields: one writer, the atomic one.** About twenty call sites do
  `Map.put(user.custom_fields || %{}, key, value)` then
  `PhoenixKit.Users.Auth.update_user_custom_fields/2`, which rebuilds the whole column from a
  struct that may be stale. The manga reader (`RokiWeb.MangaController`, `Manga.Source.Extensions`,
  `EtcherHostLive`), `Roki.Nuvio.Settings`, `Roki.Pengu` and the kit's own
  `notification_preferences` all live in that one column, so two writes can lose each other.
  The kit moved its own writes to `merge_user_custom_fields/3` (a `jsonb ||` in SQL) and
  documents it as the way to set a key; roki uses it once (`MangaShelfLive`). Sweep every call
  site to `merge_user_custom_fields(user, %{key => value}, ensure_definitions: false)` and
  `delete_user_custom_field/3` for removals (Pengu's `clear`). No test exercises the race; add
  one that writes two keys from two stale structs and expects both.

- [ ] **2. Register roki as a kit module** (`Roki.Kit`, `@behaviour PhoenixKit.Module`, listed in
  `config :phoenix_kit, modules: [Roki.Kit]` — the kit's beam scan only walks dependencies, so a
  host app must name itself). Callbacks worth implementing, each replacing something hand-rolled:
  - [ ] `before_user_delete/1` — today deleting an account in the kit's admin leaves rows in 17
    roki tables and the manga tables (`user_uuid`, no foreign key), the laev directory
    (`Roki.Laev.dir/1`), `roki-sources/`, the shelf/totals files. Delete them all here.
  - [ ] `notification_types/0` — declare the kinds `Roki.Notify` keeps in `roki_notify_prefs`
    (releases, health, admin, weekly summary…) so the kit's own preferences page and
    `Prefs.user_wants?/2` filter them; then retire `roki_notify_prefs` and the Settings section
    that edits it. `Roki.Social.notify/6` keeps logging `roki.<action>` activity; the type's
    `actions` list names those.
  - [ ] `oban_crons/0` — `Roki.Releases` (every few hours), `Roki.Health` (6 h),
    `Roki.AdminWatch` (1 h) are GenServer timers that restart from zero with the node and run
    unseen. As crons they show in the kit's Jobs page with history and can be run by hand.
  - [ ] `admin_tabs/0` — move the "API access" tab from `config :phoenix_kit,
    :admin_dashboard_tabs` into the module so everything the kit knows about roki is in one
    place.
  - [ ] `expected_schema/0` and `file_references/0` — the doctor then checks roki's tables for
    drift, and the media library's repair sees `roki_pictures` and `roki_profiles.banner` as
    files in use rather than unreferenced.
  - [ ] `profile_settings_tabs/0` — a "Playback & services" tab on the kit's profile settings
    strip pointing at `/u/:username/settings`, replacing `AccountController.services` (the
    redirect the account menu uses today).

- [ ] **3. One sign-in helper for tests.** 42 test files repeat
  `register_user` + `generate_user_session_token` + `init_test_session`. The kit ships
  `PhoenixKit.Test.Fixtures` (`user_fixture/1`, `log_in_user/2`,
  `register_and_log_in_user/1`). Put a `log_in/2` (and a `connected/1` for LiveView) in
  `RokiWeb.ConnCase` over those and use it; the per-file copies go.

- [ ] **4. Stale words.** `Roki.Manga.CommentNotifier`'s moduledoc calls `on_comment_liked/3` a
  "local patch to phoenix_kit_comments"; it is upstream since 0.4.x and nothing in `deps/` is
  patched — a reader would fear `mix deps.get`. `CLAUDE.md`: the kit is 2.65.0 at V225 and the
  doctor says 27/32 with five warnings (two new: image sizes from an older pipeline, and the
  integration key); the "rotated on 2026-10-06" line is wrong — `/root/.config/phoenix_kit/` does
  not exist and nothing is stored under integrations, so the derived key is in use (harmless
  until the first integration credential is saved; run the rotate then).

- [ ] **5. Doctor's "older pipeline" sizes.** 551 image renditions predate the PNG-for-transparent
  and no-upscale rules. `PhoenixKit.Modules.Storage.VariantSets.remake_all/0` from a remote console
  at a quiet hour, once; not urgent, they serve fine.

- [ ] **6. The stand itself.** Still `MIX_ENV=dev` on the apex with `check_origin: false` and
  `/dev/dashboard` open to anyone. It was fine as an empty scaffold; there are now six accounts,
  comments and friend requests. Decide the prod-image move (host `adrs/0008`).

## The kit's, for upstream (BeamLabEU/phoenix_kit)

Each of these cost roki a workaround and will cost the next host the same. Pointers are to
2.65.0 sources.

1. **Logout lands on the kit's own mount point.** `Utils.Routes.safe_destination/2` tries
   `path("/")` first, which under `url_prefix: "/phoenix_kit"` is `/phoenix_kit`, probed through
   the host router — and a host with a catch-all (`/:username`) says yes. Roki had to add a
   `/phoenix_kit` route that goes home (commit 9e5d4a7). Fix: never offer core's own mount as a
   home candidate, and treat a parametric route match as "not a page".
2. **The remember-me rebuild hides in one plug.** `ensure_user_token/1` (the only place the
   session is rebuilt from the cookie) runs inside `fetch_phoenix_kit_current_scope/2`, and the
   installer (`Install.BrowserPipelineIntegration`) adds only `Plugs.Integration` to `:browser`.
   A host that fetches the scope only on guarded routes looks signed out after the phone drops the
   session cookie, until a kit page is opened (commit 11c7e0f). Fix: rebuild in
   `Plugs.Integration`, or have the installer add the fetch plug; and document that the host's
   session cookie should carry a `max_age` matching `remember_me_max_age/0`.
3. **Two theme bootstraps.** phx.new 1.8's root layout already stamps `data-theme`; the kit's
   installer adds a second script unless the magic comment
   `<%!-- phoenix_kit: theme managed by host --%>` is present (`Install.JsIntegration`). Detect
   phx.new's script, or take a config flag.
4. **Per-user preferences share a column with a full-replace writer.**
   `update_user_custom_fields/3` still rebuilds the whole JSONB from the caller's struct; the
   kit's own prefs moved to `merge_user_custom_fields/3` for that reason (`Notifications.Prefs`,
   `preferred_locale`, `start_page`). Make the merge the documented default, warn on the
   replace, or add a namespaced `Users.Prefs` API.
5. **Host-as-module is the hidden door.** `:admin_dashboard_tabs` has a config path; the delete
   hook, notification types, crons, expected schema and file references are module-only, and
   `ModuleDiscovery` scans only deps, so a host must list itself in `:modules`. Say so in the
   install guide, or give those hooks a config path too.
6. **Doctor false positives.** `check_daisyui/0` wants `assets/vendor/daisyui.js`; phx.new 1.8
   pins daisyUI as a git dep under `deps/daisyui` and loads it from there, so every new app
   warns. `check_integration_key/1` warns even when a key store is configured and no
   credential has ever been stored.
7. **PgBouncer and Oban.** The doctor spots the pooler; the installer could write
   `notifier: Oban.Notifiers.PG` when it does, since the default notifier fails silently
   (queue signals dropped, jobs still run).
8. **Small API edges.** `Storage.store_file_in_buckets/7` is seven positional arguments (every
   host wraps it); `Storage.list_dimensions_for_type/2` hits the database on every call (roki
   caches it an hour in `persistent_term`, inside a `rescue`).
9. **Generated tests don't use the kit's fixtures.** `PhoenixKit.Test.Fixtures` exists; the
   installer's guidance and the user-facing docs never mention it, so hosts hand-roll sign-in.
