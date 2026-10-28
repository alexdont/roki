defmodule RokiWeb.MangaSettings do
  @moduledoc """
  The reader's own preferences — auto-resume, tap zones, reading direction, panel
  snap, page padding — as one component, so this site has a single settings page
  (`/:username/settings`) rather than a second one behind the reader.

  The markup and the hook are the reader's, unchanged: every control still saves
  itself with a `PUT /manga/settings/<key>` through `RokiWeb.MangaController`, which
  writes to the user's `custom_fields`. That is where the whole reader reads these
  from, so nothing here moves into laev's settings or this site's own `web` section.
  """
  use RokiWeb, :html

  attr :user, :map, required: true, doc: "the signed-in user, for `custom_fields`"
  attr :page_padding, :map, required: true, doc: "`Roki.Manga.Library.page_padding_defaults/1`"
  attr :mal_token, :any, default: nil, doc: "the reader's own MyAnimeList token, if connected"
  attr :mal_available, :boolean, default: false

  def preferences(assigns) do
    ~H"""
    <div id="reader-settings" phx-hook=".ReaderSettings" class="space-y-4">
      <a
        href={~p"/manga/extensions"}
        class="flex items-center justify-between bg-base-200 rounded-xl p-4 hover:bg-base-300 transition-colors"
      >
        <div>
          <p class="font-medium">Source extensions</p>
          <p class="text-sm text-base-content/60">
            Pick which external manga sources appear in Search and Explore (1,000+ community-maintained sites).
          </p>
        </div>
        <svg
          xmlns="http://www.w3.org/2000/svg"
          class="h-5 w-5 text-base-content/40"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
        >
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7" />
        </svg>
      </a>

      <div class="bg-base-200 rounded-xl p-4">
        <div class="flex items-center justify-between">
          <div class="min-w-0 pr-3">
            <div class="flex items-center gap-2 mb-1">
              <p class="font-medium">MyAnimeList — reading list</p>
              <span :if={@mal_token} class="badge badge-success badge-sm">
                Connected{if @mal_token.remote_username, do: " · #{@mal_token.remote_username}"}
              </span>
            </div>
            <p class="text-sm text-base-content/60">
              <%= if @mal_token do %>
                Your reading progress syncs to your MyAnimeList list. Only you can update your list.
              <% else %>
                Connect your account to sync reading progress and pull synopsis, genres, ratings and covers from MyAnimeList.
              <% end %>
            </p>
          </div>
          <%= if @mal_token do %>
            <form method="post" action={~p"/manga/trackers/mal/disconnect"} class="flex-shrink-0">
              <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
              <button type="submit" class="btn btn-sm btn-ghost">Disconnect</button>
            </form>
          <% else %>
            <%= if @mal_available do %>
              <a href={~p"/manga/trackers/mal/connect"} class="btn btn-sm btn-primary flex-shrink-0">
                Connect
              </a>
            <% else %>
              <span class="text-xs text-base-content/40 flex-shrink-0">Not available</span>
            <% end %>
          <% end %>
        </div>
      </div>
      <div class="flex items-center justify-between bg-base-200 rounded-xl p-4">
        <div>
          <p class="font-medium">Auto-resume</p>
          <p class="text-sm text-base-content/60">
            When you open the Reader home page, automatically redirect to your last-read manga after a countdown.
          </p>
        </div>
        <input
          type="checkbox"
          class="toggle toggle-primary"
          id="auto-resume-toggle"
          checked={(@user.custom_fields || %{})["auto_resume"] == true}
        />
      </div>
      <div class="flex items-center justify-between bg-base-200 rounded-xl p-4">
        <div>
          <p class="font-medium">Auto-resume timer</p>
          <p class="text-sm text-base-content/60">
            How long to wait before auto-resuming your last read.
          </p>
        </div>
        <select id="auto-resume-timer-select" class="select select-bordered select-sm w-24">
          <% timer_val = (@user.custom_fields || %{})["auto_resume_timer"] || 5 %>
          <%= for s <- 2..10 do %>
            <option value={s} selected={timer_val == s}>{s}s</option>
          <% end %>
        </select>
      </div>
      <div class="bg-base-200 rounded-xl p-4">
        <div class="flex items-center justify-between mb-2">
          <div>
            <p class="font-medium">Auto-resume backdrop</p>
            <p class="text-sm text-base-content/60">
              Custom image shown behind the auto-resume popup.
            </p>
          </div>
        </div>
        <% art_uuid = (@user.custom_fields || %{})["auto_resume_art"] %>
        <div id="auto-resume-art-section">
          <%= if art_uuid do %>
            <div class="flex items-center gap-3 mb-2">
              <img
                id="auto-resume-art-preview"
                src={PhoenixKit.Modules.Storage.URLSigner.signed_url(art_uuid, "original")}
                class="w-24 h-16 object-cover rounded-lg border border-base-content/10"
              />
              <button
                type="button"
                id="auto-resume-art-remove"
                class="btn btn-sm btn-error btn-outline"
              >Remove</button>
            </div>
          <% else %>
            <div id="auto-resume-art-preview-wrap" class="hidden flex items-center gap-3 mb-2">
              <img
                id="auto-resume-art-preview"
                src=""
                class="w-24 h-16 object-cover rounded-lg border border-base-content/10"
              />
              <button
                type="button"
                id="auto-resume-art-remove"
                class="btn btn-sm btn-error btn-outline"
              >Remove</button>
            </div>
          <% end %>
          <input type="file" id="auto-resume-art-input" accept="image/*" class="hidden" />
          <button type="button" id="auto-resume-art-upload" class="btn btn-sm btn-outline">
            {if art_uuid, do: "Change Image", else: "Upload Image"}
          </button>
        </div>
      </div>
      <div class="bg-base-200 rounded-xl p-4">
        <p class="font-medium mb-1">Default tap zone layout</p>
        <p class="text-sm text-base-content/60 mb-3">Global default for all manga.</p>
        <% default_tap = (@user.custom_fields || %{})["default_tap_zone"] || "default" %>
        <div class="flex flex-row gap-3" id="default-tap-zone-presets">
          <label
            class={"cursor-pointer flex flex-col items-center gap-1.5 p-2 rounded-lg border-2 flex-1 #{if default_tap == "default", do: "border-primary bg-primary/5", else: "border-base-content/20 bg-transparent"} default-tap-zone-card"}
            data-preset="default"
          >
            <input
              type="radio"
              name="default_tap_zone"
              value="default"
              class="hidden"
              checked={default_tap == "default"}
            />
            <div class="relative w-20 aspect-[3/4] rounded border border-base-content/20 overflow-hidden bg-base-300">
              <div class="absolute top-0 left-0 bottom-0 w-1/3 bg-green-500/30 flex items-center justify-center text-green-900 font-bold text-[7px] border-r border-green-500/40">
                N
              </div>
              <div class="absolute top-0 right-0 bottom-0 w-1/3 bg-green-500/30 flex items-center justify-center text-green-900 font-bold text-[7px] border-l border-green-500/40">
                N
              </div>
              <div class="absolute top-0 left-1/3 right-1/3 h-1/2 bg-blue-500/30 flex items-center justify-center text-blue-900 font-bold text-[7px] border-b border-blue-500/40">
                M
              </div>
              <div class="absolute bottom-0 left-1/3 right-1/3 h-1/2 bg-red-500/30 flex items-center justify-center text-red-900 font-bold text-[7px] border-t border-red-500/40">
                P
              </div>
            </div>
            <span class="text-xs font-medium">Default</span>
          </label>
          <label
            class={"cursor-pointer flex flex-col items-center gap-1.5 p-2 rounded-lg border-2 flex-1 #{if default_tap == "left_right", do: "border-primary bg-primary/5", else: "border-base-content/20 bg-transparent"} default-tap-zone-card"}
            data-preset="left_right"
          >
            <input
              type="radio"
              name="default_tap_zone"
              value="left_right"
              class="hidden"
              checked={default_tap == "left_right"}
            />
            <div class="relative w-20 aspect-[3/4] rounded border border-base-content/20 overflow-hidden bg-base-300">
              <div class="absolute top-0 left-0 bottom-0 w-1/3 bg-red-500/30 flex items-center justify-center text-red-900 font-bold text-[7px] border-r border-red-500/40">
                P
              </div>
              <div class="absolute top-0 right-0 bottom-0 w-1/3 bg-green-500/30 flex items-center justify-center text-green-900 font-bold text-[7px] border-l border-green-500/40">
                N
              </div>
              <div class="absolute inset-0 left-1/3 right-1/3 bg-blue-500/30 flex items-center justify-center text-blue-900 font-bold text-[7px]">
                M
              </div>
            </div>
            <span class="text-xs font-medium">Left / Right</span>
          </label>
          <label
            class={"cursor-pointer flex flex-col items-center gap-1.5 p-2 rounded-lg border-2 flex-1 #{if default_tap == "right_left", do: "border-primary bg-primary/5", else: "border-base-content/20 bg-transparent"} default-tap-zone-card"}
            data-preset="right_left"
          >
            <input
              type="radio"
              name="default_tap_zone"
              value="right_left"
              class="hidden"
              checked={default_tap == "right_left"}
            />
            <div class="relative w-20 aspect-[3/4] rounded border border-base-content/20 overflow-hidden bg-base-300">
              <div class="absolute top-0 left-0 bottom-0 w-1/3 bg-green-500/30 flex items-center justify-center text-green-900 font-bold text-[7px] border-r border-green-500/40">
                N
              </div>
              <div class="absolute top-0 right-0 bottom-0 w-1/3 bg-red-500/30 flex items-center justify-center text-red-900 font-bold text-[7px] border-l border-red-500/40">
                P
              </div>
              <div class="absolute inset-0 left-1/3 right-1/3 bg-blue-500/30 flex items-center justify-center text-blue-900 font-bold text-[7px]">
                M
              </div>
            </div>
            <span class="text-xs font-medium">Right / Left</span>
          </label>
        </div>
      </div>
      <div class="bg-base-200 rounded-xl p-4">
        <p class="font-medium mb-1">Default reading direction</p>
        <p class="text-sm text-base-content/60 mb-3">
          Global default for new manga without a saved direction.
        </p>
        <% default_dir = (@user.custom_fields || %{})["default_reading_direction"] || "rtl" %>
        <div class="flex flex-row gap-3" id="default-reading-direction-buttons">
          <button
            type="button"
            data-direction="rtl"
            class={"btn btn-sm flex-1 #{if default_dir == "rtl", do: "btn-primary", else: "btn-ghost border-base-content/20"} default-dir-btn"}
          >RTL ←</button>
          <button
            type="button"
            data-direction="ltr"
            class={"btn btn-sm flex-1 #{if default_dir == "ltr", do: "btn-primary", else: "btn-ghost border-base-content/20"} default-dir-btn"}
          >LTR →</button>
        </div>
      </div>
      <div class="flex items-center justify-between bg-base-200 rounded-xl p-4">
        <div>
          <p class="font-medium">Default panel snap</p>
          <p class="text-sm text-base-content/60">
            Enable panel snap (smart scroll) by default for new manga. Can be toggled per-manga in the reader.
          </p>
        </div>
        <input
          type="checkbox"
          class="toggle toggle-primary"
          id="default-smart-scroll-toggle"
          checked={(@user.custom_fields || %{})["default_smart_scroll"] == true}
        />
      </div>
      <div class="flex items-center justify-between bg-base-200 rounded-xl p-4">
        <div>
          <p class="font-medium">
            Smart panels <span class="badge badge-sm badge-warning align-middle">test</span>
          </p>
          <p class="text-sm text-base-content/60">
            Paged reader: Next zooms to each panel in reading order, centered and fully visible, and turns the page after the last one. Art and balloons spilling out of a panel stay in view.
          </p>
        </div>
        <input
          type="checkbox"
          class="toggle toggle-primary"
          id="smart-panels-toggle"
          checked={(@user.custom_fields || %{})["smart_panels"] == true}
        />
      </div>
      <%!-- Default page padding — the scroll reader's slider value, applied
             to new manga before the user touches the per-manga slider. Split
             desktop/mobile because a 70% shrink that frames a strip nicely on
             a monitor leaves a phone with almost nothing. --%>
      <div class="bg-base-200 rounded-xl p-4 space-y-4" id="default-page-padding-section">
        <div>
          <p class="font-medium">Default page padding</p>
          <p class="text-sm text-base-content/60">
            Global default for the scroll (manhwa) reader. Shrinks the strip by this much, split evenly left and right. Can be overridden per-manga in the reader.
          </p>
        </div>
        <div :for={{form_factor, label} <- [{:desktop, "Desktop"}, {:mobile, "Mobile"}]}>
          <div class="flex items-center justify-between mb-1">
            <p class="text-sm">{label}</p>
            <span id={"default-page-padding-#{form_factor}-label"} class="text-xs font-mono">
              {@page_padding[form_factor]}%
            </span>
          </div>
          <input
            type="range"
            id={"default-page-padding-#{form_factor}"}
            data-form-factor={form_factor}
            class="range range-xs range-primary w-full default-page-padding-slider"
            min="0"
            max="90"
            step="1"
            value={@page_padding[form_factor]}
          />
        </div>
      </div>
      <% ssc = (@user.custom_fields || %{})["smart_scroll_config"] || %{} %>
      <div class="bg-base-200 rounded-xl p-4 space-y-4" id="smart-scroll-config-section">
        <div>
          <p class="font-medium">Panel snap settings</p>
          <p class="text-sm text-base-content/60">
            Global defaults for panel snap behavior. Can be overridden per-manga in the reader settings.
          </p>
        </div>
        <div class="flex items-center justify-between">
          <p class="text-sm">Jump style</p>
          <% jump_val = ssc["jump_style"] || "smooth" %>
          <div class="flex flex-row gap-3" id="ssc-jump-style-buttons">
            <button
              type="button"
              data-value="smooth"
              class={"btn btn-sm flex-1 #{if jump_val == "smooth", do: "btn-primary", else: "btn-ghost border-base-content/20"} ssc-jump-btn"}
            >Smooth</button>
            <button
              type="button"
              data-value="instant"
              class={"btn btn-sm flex-1 #{if jump_val == "instant", do: "btn-primary", else: "btn-ghost border-base-content/20"} ssc-jump-btn"}
            >Instant</button>
          </div>
        </div>
        <div class="flex items-center justify-between">
          <p class="text-sm">Scan distance</p>
          <% scan_val = ssc["scan_distance"] || 3 %>
          <select id="ssc-scan-distance" class="select select-bordered select-sm w-24">
            <%= for n <- 1..5 do %>
              <option value={n} selected={scan_val == n}>{n}x</option>
            <% end %>
          </select>
        </div>
        <div class="flex items-center justify-between">
          <div>
            <p class="text-sm">Long panel steps</p>
            <p class="text-xs text-base-content/50">Break tall panels into half-viewport jumps</p>
          </div>
          <input
            type="checkbox"
            class="toggle toggle-primary"
            id="ssc-long-panel-steps"
            checked={Map.get(ssc, "long_panel_steps", true) == true}
          />
        </div>
        <div class="flex items-center justify-between">
          <div>
            <p class="text-sm">Gutter tolerance</p>
            <p id="ssc-gutter-hint" class="text-xs text-base-content/50">Solid + light texture</p>
          </div>
          <% tolerance_val = ssc["gutter_tolerance"] || 300 %>
          <select id="ssc-gutter-tolerance" class="select select-bordered select-sm w-32">
            <option value="50" selected={tolerance_val == 50}>Strict</option>
            <option value="300" selected={tolerance_val == 300}>Normal</option>
            <option value="800" selected={tolerance_val == 800}>Relaxed</option>
            <option value="1500" selected={tolerance_val == 1500}>Aggressive</option>
          </select>
        </div>
        <div class="flex items-center justify-between">
          <div>
            <p class="text-sm">Min gutter width</p>
            <p id="ssc-gutter-width-hint" class="text-xs text-base-content/50">
              Standard gutter width
            </p>
          </div>
          <% gutter_width_val = ssc["min_gutter_width"] || 50 %>
          <select id="ssc-min-gutter-width" class="select select-bordered select-sm w-32">
            <option value="20" selected={gutter_width_val == 20}>Narrow</option>
            <option value="50" selected={gutter_width_val == 50}>Normal</option>
            <option value="100" selected={gutter_width_val == 100}>Wide</option>
          </select>
        </div>
        <button type="button" id="ssc-reset" class="btn btn-sm btn-ghost text-error w-full">Reset to defaults</button>
      </div>
      <%!-- Was "Switch to old reader" in the reader's own menu. It is a preference, so it
           lives with the preferences now that the menu is gone. --%>
      <div class="flex items-center justify-between bg-base-200 rounded-xl p-4">
        <div>
          <p class="font-medium">Old reader pages</p>
          <p class="text-sm text-base-content/60">
            Serve the earlier home page and series page instead of the current ones. The reader
            itself is the same either way.
          </p>
        </div>
        <input
          type="checkbox"
          class="toggle toggle-primary"
          id="old-reader-toggle"
          checked={(@user.custom_fields || %{})["reader_ui_v2"] == false}
        />
      </div>
    </div>

    <%!-- Colocated hook: this JS is extracted into the bundle at compile
         time, so it never ships inside the rendered markup. Previously it
         was a plain <script> in this template, which meant the connected
         mount re-ran the whole file after the dead render and stacked a
         second set of listeners on every control — one toggle, two PUTs. --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ReaderSettings">
      export default {
        mounted() {
          // Delegated from the root rather than bound per control: LiveView
          // patches this subtree (the account-settings panel toggles, the
          // backdrop preview swaps branches when art is set/cleared), and a
          // node morphdom replaces takes its listeners with it. Two
          // listeners on a node that never moves can't go stale.
          this._paddingTimers = {};
          this._onChange = (e) => this.handleChange(e);
          this._onClick = (e) => this.handleClick(e);
          this._onInput = (e) => this.handleInput(e);
          this.el.addEventListener("change", this._onChange);
          this.el.addEventListener("click", this._onClick);
          this.el.addEventListener("input", this._onInput);
          this.syncHints();
        },

        updated() {
          this.syncHints();
        },

        destroyed() {
          this.el.removeEventListener("change", this._onChange);
          this.el.removeEventListener("click", this._onClick);
          this.el.removeEventListener("input", this._onInput);
          // A drag left mid-flight would otherwise fire after teardown.
          Object.values(this._paddingTimers).forEach(clearTimeout);
        },

        // ── helpers ──────────────────────────────────────────────────────

        $(sel) {
          return this.el.querySelector(sel);
        },

        $$(sel) {
          return Array.from(this.el.querySelectorAll(sel));
        },

        put(path, body) {
          const csrfToken = document
            .querySelector('meta[name="csrf-token"]')
            .getAttribute("content");
          return fetch(path, {
            method: "PUT",
            headers: { "Content-Type": "application/json", "x-csrf-token": csrfToken },
            body: JSON.stringify(body)
          });
        },

        // Swap the active/inactive daisyUI classes across a button group.
        pick(sel, attr, value) {
          this.$$(sel).forEach((b) => {
            if (b.dataset[attr] === value) {
              b.classList.remove("btn-ghost", "border-base-content/20");
              b.classList.add("btn-primary");
            } else {
              b.classList.remove("btn-primary");
              b.classList.add("btn-ghost", "border-base-content/20");
            }
          });
        },

        // ── change ───────────────────────────────────────────────────────

        handleChange(e) {
          const t = e.target;

          if (t.id === "auto-resume-toggle") {
            return this.put("/manga/settings/auto_resume", { enabled: t.checked });
          }

          if (t.id === "auto-resume-timer-select") {
            return this.put("/manga/settings/auto_resume_timer", {
              seconds: parseInt(t.value, 10)
            });
          }

          if (t.name === "default_tap_zone" && t.closest("#default-tap-zone-presets")) {
            const preset = t.value;
            this.put("/manga/settings/default_tap_zone", { preset: preset });
            this.$$(".default-tap-zone-card").forEach((card) => {
              if (card.dataset.preset === preset) {
                card.classList.remove("border-base-content/20", "bg-transparent");
                card.classList.add("border-primary", "bg-primary/5");
              } else {
                card.classList.remove("border-primary", "bg-primary/5");
                card.classList.add("border-base-content/20", "bg-transparent");
              }
            });
            return;
          }

          if (t.id === "default-smart-scroll-toggle") {
            return this.put("/manga/settings/default_smart_scroll", { enabled: t.checked });
          }

          if (t.id === "old-reader-toggle") {
            // The stored flag means "use the current pages", so this toggle is its opposite.
            return this.put("/manga/settings/reader_ui_v2", { enabled: !t.checked });
          }

          if (t.id === "smart-panels-toggle") {
            return this.put("/manga/settings/smart_panels", { enabled: t.checked });
          }

          if (t.id === "ssc-scan-distance") {
            return this.saveScrollConfig({ scan_distance: parseInt(t.value) });
          }

          if (t.id === "ssc-long-panel-steps") {
            return this.saveScrollConfig({ long_panel_steps: t.checked });
          }

          if (t.id === "ssc-gutter-tolerance") {
            this.saveScrollConfig({ gutter_tolerance: parseInt(t.value) });
            return this.syncHints();
          }

          if (t.id === "ssc-min-gutter-width") {
            this.saveScrollConfig({ min_gutter_width: parseInt(t.value) });
            return this.syncHints();
          }

          if (t.id === "auto-resume-art-input") {
            return this.uploadArt(t);
          }
        },

        // `input` rather than `change`: the label tracks the thumb as it
        // drags. Saving is debounced off the back of that so a single drag
        // is one PUT, not one per pixel.
        handleInput(e) {
          const slider = e.target.closest(".default-page-padding-slider");
          if (!slider) return;

          const formFactor = slider.dataset.formFactor;
          const pct = parseInt(slider.value, 10);

          const label = this.$(`#default-page-padding-${formFactor}-label`);
          if (label) label.textContent = pct + "%";

          clearTimeout(this._paddingTimers[formFactor]);
          this._paddingTimers[formFactor] = setTimeout(() => {
            this.put("/manga/settings/default_page_padding", { [formFactor]: pct });
          }, 300);
        },

        // ── click ────────────────────────────────────────────────────────

        handleClick(e) {
          const jump = e.target.closest(".ssc-jump-btn");
          if (jump && this.el.contains(jump)) {
            this.pick(".ssc-jump-btn", "value", jump.dataset.value);
            return this.saveScrollConfig({ jump_style: jump.dataset.value });
          }

          if (e.target.closest("#ssc-reset")) {
            return this.resetScrollConfig();
          }

          const dir = e.target.closest(".default-dir-btn");
          if (dir && this.el.contains(dir)) {
            this.put("/manga/settings/default_reading_direction", {
              direction: dir.dataset.direction
            });
            return this.pick(".default-dir-btn", "direction", dir.dataset.direction);
          }

          if (e.target.closest("#auto-resume-art-upload")) {
            const input = this.$("#auto-resume-art-input");
            if (input) input.click();
            return;
          }

          if (e.target.closest("#auto-resume-art-remove")) {
            return this.removeArt();
          }
        },

        // ── panel snap (smart scroll) ────────────────────────────────────

        // The endpoint takes a whole config, not a patch, so read the rest
        // of the settings off the current UI and overlay what just changed.
        saveScrollConfig(patch) {
          const jumpBtn = this.$(".ssc-jump-btn.btn-primary");
          const config = {
            jump_style: patch.jump_style || (jumpBtn ? jumpBtn.dataset.value : "smooth"),
            scan_distance: patch.scan_distance || parseInt(this.$("#ssc-scan-distance").value),
            long_panel_steps:
              patch.long_panel_steps !== undefined
                ? patch.long_panel_steps
                : this.$("#ssc-long-panel-steps").checked,
            gutter_tolerance:
              patch.gutter_tolerance || parseInt(this.$("#ssc-gutter-tolerance").value),
            min_gutter_width:
              patch.min_gutter_width || parseInt(this.$("#ssc-min-gutter-width").value)
          };
          Object.assign(config, patch);
          this.put("/manga/settings/smart_scroll_config", { config: config });
        },

        resetScrollConfig() {
          const defaults = {
            jump_style: "smooth",
            scan_distance: 3,
            long_panel_steps: true,
            gutter_tolerance: 300,
            min_gutter_width: 50
          };
          this.pick(".ssc-jump-btn", "value", defaults.jump_style);
          this.$("#ssc-scan-distance").value = defaults.scan_distance;
          this.$("#ssc-long-panel-steps").checked = defaults.long_panel_steps;
          this.$("#ssc-gutter-tolerance").value = defaults.gutter_tolerance;
          this.$("#ssc-min-gutter-width").value = defaults.min_gutter_width;
          this.syncHints();
          this.saveScrollConfig(defaults);
        },

        // The hints are server-rendered with the stored value's wording, so
        // this only has to catch up after a change — but it runs on mount
        // too, in case the two ever disagree.
        syncHints() {
          const tolerance = {
            "50": "Solid color only",
            "300": "Solid + light texture",
            "800": "Heavy texture / dark noise",
            "1500": "Nearly anything non-artwork"
          };
          const width = {
            "20": "Thin gutters / tightly packed",
            "50": "Standard gutter width",
            "100": "Only snap on wide gaps"
          };

          const toleranceHint = this.$("#ssc-gutter-hint");
          const toleranceSel = this.$("#ssc-gutter-tolerance");
          if (toleranceHint && toleranceSel) {
            toleranceHint.textContent = tolerance[toleranceSel.value] || "";
          }

          const widthHint = this.$("#ssc-gutter-width-hint");
          const widthSel = this.$("#ssc-min-gutter-width");
          if (widthHint && widthSel) {
            widthHint.textContent = width[widthSel.value] || "";
          }
        },

        // ── auto-resume backdrop art ─────────────────────────────────────

        async uploadArt(fileInput) {
          const file = fileInput.files[0];
          if (!file) return;

          const csrfToken = document
            .querySelector('meta[name="csrf-token"]')
            .getAttribute("content");
          const uploadBtn = this.$("#auto-resume-art-upload");
          const preview = this.$("#auto-resume-art-preview");
          const previewWrap = this.$("#auto-resume-art-preview-wrap");

          try {
            const form = new FormData();
            form.append("file", file);
            // phoenix_kit routes are mounted at the ROOT prefix
            // (config :phoenix_kit, url_prefix: "/") — keep in sync.
            const uploadRes = await fetch("/api/upload", {
              method: "POST",
              headers: { "x-csrf-token": csrfToken },
              body: form
            });
            if (!uploadRes.ok) throw new Error("Upload failed");
            const uploadData = await uploadRes.json();

            const saveRes = await this.put("/manga/settings/auto_resume_art", {
              file_uuid: uploadData.file_uuid
            });
            if (!saveRes.ok) throw new Error("Save failed");
            const saveData = await saveRes.json();

            if (preview) preview.src = saveData.art_url;
            if (previewWrap) previewWrap.classList.remove("hidden");
            if (uploadBtn) uploadBtn.textContent = "Change Image";
          } catch (e) {
            alert("Failed to upload: " + e.message);
          }
          fileInput.value = "";
        },

        async removeArt() {
          const uploadBtn = this.$("#auto-resume-art-upload");
          const preview = this.$("#auto-resume-art-preview");
          const previewWrap = this.$("#auto-resume-art-preview-wrap");

          await this.put("/manga/settings/auto_resume_art", { clear: true });

          if (preview) {
            preview.src = "";
            const parentDiv = preview.closest(".flex");
            if (parentDiv && !previewWrap) parentDiv.classList.add("hidden");
          }
          if (previewWrap) previewWrap.classList.add("hidden");
          if (uploadBtn) uploadBtn.textContent = "Upload Image";
        }
      }
    </script>
    """
  end
end
