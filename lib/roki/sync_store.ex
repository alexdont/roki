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

  defdelegate max_bytes, to: Laev.SyncServer
  defdelegate valid_token?(token), to: Laev.SyncServer, as: :token_ok?
  defdelegate plausible_document?(body), to: Laev.SyncServer, as: :plausible?

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
  Merge a partial bundle into the stored document: the rules are `Laev.SyncServer.merge/2`,
  this adds the storage. Returns `{:ok, etag}` of the merged document, or `{:error, :invalid}`
  when a named collection isn't a map of records.

  Concurrency: the whole read-merge-write runs in a transaction under a per-(token, doc)
  advisory lock, so concurrent merges serialize — no If-Match needed, and no lost updates from
  read-modify-write races.
  """
  def merge(token, doc, patch) when is_map(patch) do
    Repo.transaction(fn ->
      lock_doc(token, doc)

      stored =
        with {:ok, body, _etag} <- get(token, doc),
             {:ok, %{} = map} <- Jason.decode(body) do
          map
        else
          _ -> %{}
        end

      case Laev.SyncServer.merge(stored, patch) do
        {:ok, merged} ->
          {:ok, etag} = put(token, doc, Jason.encode!(merged))
          etag

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  # Serializes merges per (token, doc) for the transaction's lifetime.
  # hashtext is a stable 32-bit hash; collisions merely over-serialize.
  defp lock_doc(token, doc) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [hash(token) <> "/" <> doc])
  end

  defp hash(token), do: Laev.SyncServer.token_hash(token)

  defp etag_for(body), do: Laev.SyncServer.etag(body)
end
