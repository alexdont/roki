defmodule Mix.Tasks.Roki.Manga.Import do
  @shortdoc "Copies the old reader's manga reading into this app"
  @moduledoc """
  Copies manga reading out of the old reader into roki. See `Roki.Manga.Import` for what it does
  and `dev_docs/manga-import-staging.md` for loading the staging schema it reads.

      PHX_SERVER=false mix roki.manga.import            # what would be written, nothing written
      PHX_SERVER=false mix roki.manga.import --rehearse # write it all, count it, roll it back
      PHX_SERVER=false mix roki.manga.import --run      # write it, for real

  `--run` refuses while anyone in the mapping has no account on one side, because a half-finished
  import is worse than none. It replaces rather than merges: see the module doc.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    alias Roki.Manga.Import

    unless Import.staged?() do
      Mix.raise("the reader_import schema is not loaded — see dev_docs/manga-import-staging.md")
    end

    case args do
      ["--run"] -> do_run(Import)
      ["--rehearse"] -> Import.rehearse() |> show("rehearsed, then rolled back")
      [] -> Import.report() |> show("would write")
      other -> Mix.raise("unknown argument: #{Enum.join(other, " ")}")
    end
  end

  defp do_run(mod) do
    case mod.run() do
      {:ok, counts} ->
        show({counts, []}, "written")

      {:error, {:blocked, blocked}} ->
        Mix.shell().error(
          "Not run. No account yet for: " <> Enum.map_join(blocked, ", ", & &1.from)
        )

        Mix.shell().info("Make it, then run again — the import is all of them or none.")
        exit({:shutdown, 1})
    end
  end

  defp show({counts, blocked}, what) do
    Mix.shell().info(what <> ":")

    for {label, n} <- counts do
      Mix.shell().info("  " <> String.pad_trailing(label, 18) <> to_string(n))
    end

    if blocked != [] do
      Mix.shell().info(
        "not included (no account here yet): " <> Enum.map_join(blocked, ", ", & &1.from)
      )
    end
  end
end
