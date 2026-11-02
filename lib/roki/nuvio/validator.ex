defmodule Roki.Nuvio.Validator do
  @moduledoc """
  Static, conservative checks on a downloaded Nuvio provider.

  A provider is JavaScript from a third-party repository, so it is never trusted because
  the manifest lists it. Before it reaches the sandbox this module requires that it:

    * is plain UTF-8 JavaScript below `@max_bytes`;
    * uses only literal `require` calls from a small allowlist: the two HTML/crypto libraries
      bundled in `priv/nuvio/vendor`, and Node's side-effect-free built-ins;
    * does not reach for the filesystem, child processes, workers, raw network modules,
      `eval`, `Function`, WebAssembly, or a DOM/browser storage API;
    * declares `getStreams` and a CommonJS export.

  Libraries are bundled once into `priv/nuvio/vendor/nuvio-vendor.js`; the runner gives the
  provider a `require` that can return only those two libraries and the safe built-ins. A
  dynamic `require(expression)` is rejected because its destination cannot be checked before
  execution. Network access still goes through the runner's guarded `fetch`, not through
  `http`/`https`/`net`.

  Obfuscated providers (the common minified/string-array style in this repository) are still
  accepted, but are marked `:obfuscated` so the interface can say that a human review of intent
  was not possible and that isolation, not inspection, is what contains them.
  """

  @max_bytes 2_000_000

  # Side-effect-free Node built-ins. These cannot open a socket, read a file, or start a
  # process. `http`, `https`, `net`, `tls`, `http2`, `zlib`, `fs`, `child_process`,
  # `worker_threads`, `vm`, `module`, `os`, and `path` are deliberately absent.
  @safe_builtins ~w(
    assert buffer crypto events querystring stream string_decoder timers url util
  )

  @vendored ~w(cheerio cheerio-without-node-native crypto-js)

  @allowed_requires MapSet.new(
                      @vendored ++ @safe_builtins ++ Enum.map(@safe_builtins, &"node:#{&1}")
                    )

  # `{pattern, why}`. Keep these about capabilities, not style: a provider that needs one of
  # these is rejected rather than shimmed.
  @forbidden [
    {~r/\bchild_process\b/, "spawns processes"},
    {~r/\bworker_threads\b/, "starts worker threads"},
    {~r/\b(?:node:)?fs\b/, "reaches the filesystem"},
    {~r/\bprocess\s*[.[]/, "reads the host process"},
    {~r/\beval\s*\(/, "evaluates strings (eval)"},
    {~r/\bFunction\s*\(/, "builds code at runtime (Function)"},
    {~r/\bimport\s*\(/, "imports code at runtime"},
    {~r/\bWebAssembly\b/, "uses WebAssembly"},
    {~r/\bhttp:\/\//, "requests plain http"},
    {~r/\b(?:document|localStorage|sessionStorage|indexedDB|navigator)\s*[.[]/, "reaches the DOM"}
  ]

  @doc "`:ok` or `{:error, reasons}` for a downloaded source."
  def check(source) when is_binary(source) do
    cond do
      byte_size(source) == 0 -> {:error, ["the file is empty"]}
      byte_size(source) > @max_bytes -> {:error, ["the file is larger than 2 MB"]}
      not String.valid?(source) -> {:error, ["the file is not UTF-8"]}
      not export?(source) -> {:error, ["it does not export getStreams"]}
      true -> forbidden(source)
    end
  end

  def check(_), do: {:error, ["the file is not text"]}

  defp forbidden(source) do
    with {:ok, requires} <- requires(source),
         :ok <- allowed_requires(requires) do
      reasons =
        for {pattern, why} <- @forbidden, Regex.match?(pattern, source), do: why

      reasons = Enum.uniq(reasons)
      if reasons == [], do: :ok, else: {:error, reasons}
    end
  end

  # Every `require` must be a literal, so the allowlist can be checked before the code runs.
  # `require(moduleName)` and the obfuscated variants in some bundles are rejected here.
  defp requires(source) do
    calls = length(Regex.scan(~r/\brequire\s*\(/, source))

    literals =
      ~r/\brequire\s*\(\s*(["'])([^"']+)\1\s*\)/
      |> Regex.scan(source, capture: :all_but_first)
      |> Enum.map(fn [_quote, name] -> name end)

    if calls == length(literals),
      do: {:ok, Enum.uniq(literals)},
      else: {:error, ["uses a dynamic require"]}
  end

  defp allowed_requires(requires) do
    case Enum.reject(requires, &MapSet.member?(@allowed_requires, &1)) do
      [] -> :ok
      bad -> {:error, ["requires a module Roki does not allow: #{Enum.join(bad, ", ")}"]}
    end
  end

  defp export?(source) do
    (String.contains?(source, "getStreams") and
       (String.contains?(source, "module.exports") or String.contains?(source, "module["))) or
      String.contains?(source, "__provider")
  end

  @doc """
  A coarse review marker for the interface: `:clear` when the source is readable enough to
  review, `:obfuscated` when it is built from hex-named identifiers/string arrays.
  """
  def verification(source) when is_binary(source) do
    hex = length(Regex.scan(~r/\b_0x[0-9a-f]{4,}\b/i, source))
    if hex >= 8, do: :obfuscated, else: :clear
  end
end
