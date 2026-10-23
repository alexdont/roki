defmodule RokiWeb.SyncPull do
  @moduledoc """
  `on_mount` for the site's LiveViews: what you did on another device (the terminal app marking a
  film watched) reaches this site only when it pulls from the sync store. So opening a page pulls,
  in the background and at most once a minute per account; when something new came in, the page
  loads again so the marks show.

  Not on the pages that play video (a reload would interrupt them), and never for an account
  without laev connected.
  """
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, push_navigate: 2, start_async: 3]

  alias PhoenixKit.Users.Auth.Scope

  @every_s 60
  @skip [RokiWeb.WatchLive, RokiWeb.StudyLive]

  def on_mount(:default, _params, _session, socket) do
    uuid = uuid(socket)

    if uuid && connected?(socket) && socket.view not in @skip do
      {:cont,
       socket
       |> attach_hook(:sync_pull_path, :handle_params, &remember_path/3)
       |> attach_hook(:sync_pull, :handle_async, &handle_async/3)
       |> start_pull(uuid)}
    else
      {:cont, socket}
    end
  end

  defp uuid(socket) do
    with scope when not is_nil(scope) <- socket.assigns[:phoenix_kit_current_scope],
         true <- Scope.authenticated?(scope),
         uuid = Scope.user_uuid(scope),
         true <- Roki.Laev.connected?(uuid) do
      uuid
    else
      _ -> nil
    end
  end

  # Within the minute of the last pull there is nothing to do; otherwise one pull for the account
  # (a second page opened meanwhile waits for that one rather than starting another).
  defp start_pull(socket, uuid) do
    if Roki.TTLCache.cached?({:sync_pull, uuid}),
      do: socket,
      else: start_async(socket, :sync_pull, fn -> pull(uuid) end)
  end

  @doc "Pull from the store (at most once a minute per account). The number of records that came in."
  def pull(uuid) do
    {:ok, pulled} =
      Roki.TTLCache.fetch({:sync_pull, uuid}, @every_s, fn ->
        case Roki.Laev.sync(uuid) do
          {:ok, summary} -> {:ok, pulled(summary)}
          # Failed: do not ask again for the minute either.
          _ -> {:ok, 0}
        end
      end)

    pulled
  end

  defp pulled(summary) when is_map(summary) do
    summary |> Map.values() |> Enum.sum_by(fn v -> if is_map(v), do: v[:pulled] || 0, else: 0 end)
  end

  defp pulled(_), do: 0

  defp remember_path(_params, uri, socket) do
    %URI{path: path, query: query} = URI.parse(uri)

    {:cont,
     Phoenix.Component.assign(
       socket,
       :sync_pull_path,
       if(query, do: path <> "?" <> query, else: path)
     )}
  end

  defp handle_async(:sync_pull, {:ok, pulled}, socket) when is_integer(pulled) and pulled > 0 do
    case socket.assigns[:sync_pull_path] do
      path when is_binary(path) -> {:halt, push_navigate(socket, to: path)}
      _ -> {:halt, socket}
    end
  end

  defp handle_async(:sync_pull, _result, socket), do: {:halt, socket}
  defp handle_async(_name, _result, socket), do: {:cont, socket}
end
