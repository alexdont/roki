defmodule Roki.RateLimit do
  @moduledoc """
  Fixed-window rate limits, in memory (Hammer's ETS backend).

  Used to keep a busy or hostile client from spending the site's TMDB quota:
  searches and list loads count against the caller — the signed-in user, or the
  IP for a visitor — and against a site-wide budget besides. Only requests that
  would reach TMDB are counted; an answer served from `Roki.TTLCache` is free.

  The counters are per node and reset on restart, which is fine for protecting an
  upstream quota; it is not an abuse ledger.
  """
  use Hammer, backend: :ets

  @doc """
  `:ok`, or `{:error, {:rate_limited, seconds}}` when `limit` is spent for this
  `bucket` and `client` inside the last `scale_ms`.
  """
  def check(bucket, client, limit, scale_ms) do
    case hit({bucket, client}, scale_ms, limit) do
      {:allow, _count} -> :ok
      {:deny, retry_ms} -> {:error, {:rate_limited, max(div(retry_ms, 1000), 1)}}
    end
  end
end
