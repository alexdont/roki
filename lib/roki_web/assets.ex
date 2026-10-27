defmodule RokiWeb.Assets do
  @moduledoc """
  The address of a built file with its build time in it (`?vsn=`): a new build is a new address,
  so a browser never serves yesterday's script or styles from its cache. This site runs without
  a static manifest (no digests), and Plug.Static tells browsers to keep a `vsn=` address for a
  year — which is right, since it changes with every build.
  """

  @doc "`/assets/js/app.js` → `/assets/js/app.js?vsn=1793141480`."
  def versioned(path) when is_binary(path) do
    file = Path.join(:code.priv_dir(:roki), "static" <> path)

    case File.stat(file, time: :posix) do
      {:ok, %{mtime: t}} -> path <> "?vsn=" <> Integer.to_string(t)
      _ -> path
    end
  end
end
