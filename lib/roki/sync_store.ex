defmodule Roki.SyncStore do
  @moduledoc """
  Dumb blob sync store for the Laev CLI (movie watching).

  One opaque JSON document per `(token, doc)` — stored byte-for-byte,
  never parsed or reshaped; the client does all merging. The server's
  whole job is durability, tenancy isolation, and optimistic concurrency
  via ETags (sha256 of the content, so identical bytes → identical ETag).

  Open registration: ANY well-formed token is a tenant — no allowlist.
  The two gates against junk landing on the server are the token FORMAT
  (`laev_` + ≥30 chars of URL-safe randomness — nothing a scanner emits
  by accident) and `plausible_document?/1` (the body must be a JSON
  object carrying at least one Laev key). If abuse ever shows up, an
  allowlist can return in `valid_token?/1` without touching anything
  else. Only the token's sha256 lands in the database.
  """

  import Ecto.Query

  alias Roki.Repo

  @max_bytes 5 * 1024 * 1024
  @token_format ~r/^laev_[A-Za-z0-9_-]{30,64}$/
  # Reference shape: {"version":1,"watchlist":{…},"resume":{…},…}. Any
  # one of these marks the payload as Laev data; extra keys are fine.
  @laev_keys ~w(version watchlist resume positions tracks)

  def max_bytes, do: @max_bytes

  @doc "Does this look like a Laev token? (format check, not an allowlist)"
  def valid_token?(token) when is_binary(token), do: Regex.match?(@token_format, token)
  def valid_token?(_), do: false

  @doc """
  Is this body plausibly Laev data? Validation ONLY — the stored bytes
  are always the raw body, never a re-encoding of this parse.
  """
  def plausible_document?(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = map} -> Enum.any?(@laev_keys, &Map.has_key?(map, &1))
      _ -> false
    end
  end

  def plausible_document?(_), do: false

  @doc "Fetch a document. `{:ok, body, etag}` or `:not_found`."
  def get(token, doc) do
    from(k in "laev_documents",
      where: k.token_hash == ^hash(token) and k.doc == ^doc,
      select: {k.body, k.etag}
    )
    |> Repo.one()
    |> case do
      nil -> :not_found
      {body, etag} -> {:ok, body, etag}
    end
  end

  @doc """
  Store a document verbatim. Returns `{:ok, etag}`.

  With `if_match`, the write happens only when the stored ETag still
  matches — a single conditional UPDATE, so Postgres's row lock
  serializes concurrent writers and a lost race is `:precondition_failed`
  (→ 412), never a silent overwrite. An `if_match` against a missing
  document is also stale by definition.
  """
  def put(token, doc, body, if_match \\ nil)

  def put(token, doc, body, nil) do
    etag = etag_for(body)

    Repo.insert_all(
      "laev_documents",
      [
        %{
          token_hash: hash(token),
          doc: doc,
          body: body,
          etag: etag,
          updated_at: DateTime.utc_now()
        }
      ],
      on_conflict: {:replace, [:body, :etag, :updated_at]},
      conflict_target: [:token_hash, :doc]
    )

    {:ok, etag}
  end

  def put(token, doc, body, if_match) do
    etag = etag_for(body)

    {updated, _} =
      from(k in "laev_documents",
        where: k.token_hash == ^hash(token) and k.doc == ^doc and k.etag == ^if_match
      )
      |> Repo.update_all(set: [body: body, etag: etag, updated_at: DateTime.utc_now()])

    if updated == 1, do: {:ok, etag}, else: :precondition_failed
  end

  @doc """
  Merge a partial bundle into the stored document — the ONE place the
  server understands the record shape (GET/PUT stay opaque).

  The patch carries only changed records:

      {"version":1,"watchlist":{"tv:99":{"data":{…},"updated_at":1730000000,"deleted":false}}}

  Per (collection, key): last-write-wins on `updated_at`, incoming wins
  ties; `deleted: true` records are tombstones and are STORED as-is so
  deletions propagate to other devices. Anything the patch doesn't
  mention is untouched. Unknown top-level keys are copied over
  wholesale (client evolution). Returns `{:ok, etag}` of the merged
  document, or `{:error, :invalid}` when a named collection isn't a
  map of records.

  Concurrency: the whole read-merge-write runs in a transaction under a
  per-(token, doc) advisory lock, so concurrent merges serialize — no
  If-Match needed, and no lost updates from read-modify-write races.
  """
  def merge(token, doc, patch) when is_map(patch) do
    if collections_valid?(patch) do
      Repo.transaction(fn ->
        lock_doc(token, doc)

        stored =
          case get(token, doc) do
            {:ok, body, _etag} -> safe_decode(body)
            :not_found -> %{}
          end

        merged = merge_docs(stored, patch)
        body = Jason.encode!(merged)
        {:ok, etag} = put(token, doc, body)
        etag
      end)
    else
      {:error, :invalid}
    end
  end

  @collections ~w(watchlist resume positions tracks)

  defp collections_valid?(patch) do
    Enum.all?(@collections, fn coll ->
      case patch[coll] do
        nil -> true
        %{} -> true
        _ -> false
      end
    end)
  end

  defp merge_docs(stored, patch) do
    Enum.reduce(patch, stored, fn
      {coll, incoming}, acc when coll in @collections and is_map(incoming) ->
        Map.update(acc, coll, incoming, fn existing ->
          merge_collection(existing, incoming)
        end)

      {"version", v}, acc ->
        Map.update(acc, "version", v, fn old ->
          if is_number(old) and is_number(v), do: max(old, v), else: v
        end)

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end

  defp merge_collection(existing, incoming) when is_map(existing) do
    Enum.reduce(incoming, existing, fn {key, rec}, acc ->
      case acc do
        %{^key => current} ->
          if record_ts(rec) >= record_ts(current), do: Map.put(acc, key, rec), else: acc

        _ ->
          Map.put(acc, key, rec)
      end
    end)
  end

  # A stored collection that isn't a map (client wrote something odd via
  # PUT) is replaced by the incoming records rather than crashed on.
  defp merge_collection(_existing, incoming), do: incoming

  defp record_ts(%{"updated_at" => ts}) when is_number(ts), do: ts
  defp record_ts(_), do: 0

  defp safe_decode(body) do
    case Jason.decode(body) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  # Serializes merges per (token, doc) for the transaction's lifetime.
  # hashtext is a stable 32-bit hash; collisions merely over-serialize.
  defp lock_doc(token, doc) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [hash(token) <> "/" <> doc])
  end

  defp hash(token), do: Base.encode16(:crypto.hash(:sha256, token), case: :lower)

  defp etag_for(body), do: Base.encode16(:crypto.hash(:sha256, body), case: :lower)
end
