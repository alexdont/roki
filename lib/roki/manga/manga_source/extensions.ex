defmodule Roki.Manga.MangaSource.Extensions do
  @moduledoc """
  Per-user selection of enabled manga-source extensions (kotatsu
  sources), stored in the phoenix_kit user's `custom_fields` under
  `"kotatsu_sources"` as a list of source names. Only enabled
  extensions are searched/browsed — with 1,256 sources in the
  catalog, opt-in is the only sane default.
  """

  @key "kotatsu_sources"
  @native_key "native_sources"

  @spec enabled(struct) :: [String.t()]
  def enabled(user) do
    case (user.custom_fields || %{})[@key] do
      names when is_list(names) -> Enum.filter(names, &is_binary/1)
      _ -> []
    end
  end

  @doc """
  The user's enabled BUILT-IN scrapers (the hand-written source
  modules). Absent key = all enabled, so existing users keep today's
  behavior until they touch the setting; an explicit empty list means
  "none".
  """
  @spec enabled_native(struct) :: [String.t()]
  def enabled_native(user) do
    case (user.custom_fields || %{})[@native_key] do
      names when is_list(names) -> Enum.filter(names, &is_binary/1)
      _ -> Enum.map(Roki.Manga.Sources.all(), &elem(&1, 0))
    end
  end

  @spec set_enabled(struct, [String.t()]) :: {:ok, struct} | {:error, term}
  def set_enabled(user, names) when is_list(names) do
    current = user.custom_fields || %{}

    PhoenixKit.Users.Auth.update_user_custom_fields(
      user,
      Map.put(current, @key, Enum.uniq(names))
    )
  end

  @doc "Persist both selections (extensions + built-in scrapers) in one write."
  @spec set_all(struct, [String.t()], [String.t()]) :: {:ok, struct} | {:error, term}
  def set_all(user, kotatsu_names, native_names)
      when is_list(kotatsu_names) and is_list(native_names) do
    current = user.custom_fields || %{}

    PhoenixKit.Users.Auth.update_user_custom_fields(
      user,
      current
      |> Map.put(@key, Enum.uniq(kotatsu_names))
      |> Map.put(@native_key, Enum.uniq(native_names))
    )
  end
end
