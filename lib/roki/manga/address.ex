defmodule Roki.Manga.Address do
  @moduledoc """
  Clean addresses for manga pages: `/manga/nozoki-ana` for a title, `/manga/nozoki-ana/86` for a
  chapter and `/manga/nozoki-ana/86/5` for a page of it, instead of the source and its opaque id
  (`/manga/kotatsu/MANGAPILL~L21hbmdh…`).

  A name stands for a title; `manga_addresses` says which source entry (`source`, `slug`) it is.
  The same title on several sources shares a name (a copy moved to another source keeps its
  address), so `resolve/2` picks: the signed-in reader's own saved copy first, else the entry
  used most recently. A name is made from the title the first time an entry is seen
  (`name_for/3`) and never changes after.
  """
  use Ecto.Schema
  import Ecto.Query

  alias Roki.Repo

  schema "manga_addresses" do
    field :name, :string
    field :source, :string
    field :slug, :string
    field :title, :string
    timestamps(type: :utc_datetime)
  end

  # The fixed pages under /manga, and the sources' own names (an old-form address starts with
  # one): a title is never given these.
  @reserved ~w(manga manga2 explore search categories stats settings history legacy home2
               comments tierlist grid extensions trackers kotatsu proxy api categories u)

  @doc "The name of a source entry, made (from `title`) and kept the first time it is asked."
  def name_for(source, slug, title) when is_binary(source) and is_binary(slug) do
    case Repo.one(from a in __MODULE__, where: a.source == ^source and a.slug == ^slug) do
      %{name: name} = row ->
        # Used now: a name shared by several sources leans to this one for visitors.
        Repo.update_all(from(a in __MODULE__, where: a.id == ^row.id), set: [updated_at: now()])
        name

      nil ->
        name = make_name(source, slug, title)

        Repo.insert(
          %__MODULE__{name: name, source: source, slug: slug, title: title},
          on_conflict: :nothing,
          conflict_target: [:source, :slug]
        )

        # Lost a race: whatever the other insert gave it.
        Repo.one(
          from a in __MODULE__, where: a.source == ^source and a.slug == ^slug, select: a.name
        ) ||
          name
    end
  end

  def name_for(_source, _slug, _title), do: nil

  @doc """
  The source entry a name stands for, as `{source, slug}`: the reader's own saved copy among
  them, else the most recently used. Nil when the name is unknown.
  """
  def resolve(name, user_uuid \\ nil) when is_binary(name) do
    rows =
      Repo.all(
        from a in __MODULE__,
          where: a.name == ^String.downcase(name),
          order_by: [desc: a.updated_at],
          select: {a.source, a.slug}
      )

    saved =
      user_uuid && rows != [] &&
        Enum.find(rows, fn {source, slug} ->
          Roki.Manga.Library.get_saved_manga(user_uuid, source, slug)
        end)

    saved || List.first(rows)
  end

  @doc "The clean address of a title, a chapter of it, or a page of that chapter."
  def path(name, chapter \\ nil, page \\ nil)
  def path(name, nil, _page), do: "/manga/" <> name
  def path(name, chapter, nil), do: "/manga/#{name}/#{URI.encode(to_string(chapter))}"
  def path(name, chapter, page), do: "/manga/#{name}/#{URI.encode(to_string(chapter))}/#{page}"

  @doc "Whether a first address segment is a source's name (an old-form address) or not."
  def source?(segment), do: Roki.Manga.Sources.valid?(segment)

  defp make_name(source, slug, title) do
    title =
      (is_binary(title) and String.trim(title) != "" and title) || metadata_title(source, slug)

    base = title && PhoenixKit.Utils.Slug.slugify(title, max_length: 60)

    base =
      cond do
        base in [nil, ""] -> "manga-" <> short_hash(source <> slug)
        base in @reserved or source?(base) or Regex.match?(~r/^\d+$/, base) -> base <> "-manga"
        true -> base
      end

    # The name is free, or held by the same title (another source of it): use it. Held by a
    # different title: numbered.
    taken =
      Repo.all(from a in __MODULE__, where: a.name == ^base, select: a.title, limit: 5)

    if taken == [] or Enum.any?(taken, &same_title?(&1, title)) do
      base
    else
      Enum.find_value(2..50, "#{base}-#{short_hash(source <> slug)}", fn n ->
        candidate = "#{base}-#{n}"
        if not Repo.exists?(from a in __MODULE__, where: a.name == ^candidate), do: candidate
      end)
    end
  end

  defp same_title?(a, b) when is_binary(a) and is_binary(b),
    do: String.downcase(String.trim(a)) == String.downcase(String.trim(b))

  defp same_title?(_, _), do: false

  defp metadata_title(source, slug) do
    case Roki.Manga.Library.get_manga_metadata(source, slug) do
      %{title: t} when is_binary(t) and t != "" -> t
      _ -> nil
    end
  end

  defp short_hash(s),
    do:
      :crypto.hash(:sha256, s)
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 6)
      |> String.downcase()

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
