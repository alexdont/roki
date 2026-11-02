defmodule Roki.Manga.Trial do
  @moduledoc """
  The reader's settings for a series that is not saved: so a title can be tried — scroll mode for a
  manhwa, a reading direction — before it is put on the account.

  Saved series keep their settings on their library row; a series with no row has nowhere to put
  one, so a choice made in the reader was thrown away and the page reopened in its default mode.
  The reader picks paged or scroll on the *server* when the page is drawn, so the choice has to be
  somewhere the server can see: here, in memory, for a day, per person and series. Nothing is
  written to the account, and nothing survives a restart or a day without a visit — close the tab
  without saving and that is that. Saving the series (`Roki.Manga.Library.save_manga/2`) takes
  these settings onto its new row, so what was tried is what is kept.
  """

  alias Roki.TTLCache

  @ttl_s 24 * 3600
  @modes ["scroll", "paged", "double_page"]
  @directions ["rtl", "ltr"]
  @rotations [0, 90, 180, 270]
  @tap_zones ["default", "left_right", "right_left"]

  defp key(uuid, source, slug), do: {:manga_trial, uuid, source, slug}

  @doc "The settings tried for this series so far, as a map of the library row's own fields, or nil."
  def get(uuid, source, slug) do
    case TTLCache.peek(key(uuid, source, slug)) do
      {:ok, %{} = settings} when map_size(settings) > 0 -> settings
      _ -> nil
    end
  end

  @doc "What was tried, taken: returned and forgotten (the series has just been saved)."
  def take(uuid, source, slug) do
    settings = get(uuid, source, slug)
    TTLCache.delete(key(uuid, source, slug))
    settings
  end

  @doc """
  Remember one setting, as `Roki.Manga.MangaReader.Store.put_setting/5` is told it: the same names
  and the same device slots the library row has. `:ok`, or `{:error, reason}` for a value the
  reader does not take.
  """
  def put(uuid, source, slug, setting, value, device) do
    case fields(setting, value, device) do
      {:ok, changes} ->
        now = get(uuid, source, slug) || %{}
        TTLCache.put(key(uuid, source, slug), @ttl_s, {:ok, Map.merge(now, changes)})
        :ok

      error ->
        error
    end
  end

  defp fields(:reading_mode, mode, device) when mode in @modes,
    do:
      {:ok,
       case device do
         "desktop" -> %{reading_mode_desktop: mode}
         "mobile" -> %{reading_mode_mobile: mode}
         "all" -> %{reading_mode: mode, reading_mode_desktop: mode, reading_mode_mobile: mode}
         _ -> %{reading_mode: mode}
       end}

  defp fields(:tap_zone_preset, preset, device) when preset in @tap_zones,
    do:
      {:ok,
       case device do
         "desktop" -> %{tap_zone_preset_desktop: preset}
         "mobile" -> %{tap_zone_preset_mobile: preset}
         _ -> %{tap_zone_preset: preset}
       end}

  defp fields(:reading_direction, d, _device) when d in @directions,
    do: {:ok, %{reading_direction: d}}

  defp fields(:reading_rotation, r, _device) when r in @rotations,
    do: {:ok, %{reading_rotation: r}}

  defp fields(:smart_crop, v, _device) when is_boolean(v), do: {:ok, %{smart_crop: v}}
  defp fields(:comments_visible, v, _device) when is_boolean(v), do: {:ok, %{comments_visible: v}}
  defp fields(_setting, _value, _device), do: {:error, :invalid}
end
