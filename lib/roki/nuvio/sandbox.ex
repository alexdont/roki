defmodule Roki.Nuvio.Sandbox do
  @moduledoc """
  Runs one Nuvio provider in a short-lived, isolated Node process.

  The process is started through `env -i` (no inherited environment, so no application
  secrets), with Node's permission model on, code generation from strings disabled, and no
  filesystem, child-process or worker permission. The provider source arrives on stdin and
  the result leaves on stdout; no file is written for it.

  This is deliberately a *containment* boundary rather than a proof of good behaviour. The
  source still passed `Roki.Nuvio.Validator`; this module only decides what a provider can
  reach once it runs. A provider that hangs is killed at the deadline; output is capped.
  """

  require Logger

  @max_source 2_000_000
  @max_output 8_000_000
  @default_timeout 25_000

  @doc "Whether a Node runtime is available to the application."
  def available? do
    is_binary(node_path()) and is_binary(env_path())
  end

  @doc "Run `getStreams` for the provider source. `args` is `[tmdb_id, type, season, episode]`."
  def run(source, args, settings, opts \\ []) when is_binary(source) and is_list(args) do
    execute(source, %{"mode" => "streams", "args" => args, "settings" => settings}, opts)
  end

  @doc "Ask a provider for its `onSettings` description."
  def settings(source, opts \\ []) when is_binary(source) do
    execute(
      source,
      %{"mode" => "settings", "settings" => %{}},
      Keyword.put_new(opts, :timeout, 8_000)
    )
  end

  defp execute(source, payload, opts) do
    with :ok <- source_size(source),
         :ok <- Roki.Nuvio.Validator.check(source),
         {:ok, node} <- runtime(),
         {:ok, output} <- spawn_and_collect(node, source, payload, timeout(opts)),
         {:ok, result} <- decode(output) do
      {:ok, result}
    end
  end

  defp source_size(source) when byte_size(source) > @max_source,
    do: {:error, :source_too_large}

  defp source_size(_), do: :ok

  defp runtime do
    case {node_path(), env_path()} do
      {node, env} when is_binary(node) and is_binary(env) -> {:ok, {env, node}}
      _ -> {:error, :runtime_missing}
    end
  end

  defp node_path,
    do: Application.get_env(:roki, :nuvio_node, "node") |> System.find_executable()

  defp env_path, do: System.find_executable("env")

  defp timeout(opts), do: Keyword.get(opts, :timeout, @default_timeout)

  defp spawn_and_collect({env, node}, source, payload, timeout) do
    _previous = Process.flag(:trap_exit, true)
    on_exit = fn -> Process.flag(:trap_exit, false) end
    runner = runner_path()
    vendor = Path.join(Path.dirname(runner), "vendor/nuvio-vendor.js") |> realpath()
    dir = System.tmp_dir!() |> String.to_charlist()

    args = [
      ~c"-i",
      String.to_charlist(node),
      ~c"--permission",
      ~c"--allow-fs-read=#{runner}",
      ~c"--allow-fs-read=#{vendor}",
      ~c"--disallow-code-generation-from-strings",
      ~c"--no-warnings",
      String.to_charlist(runner)
    ]

    port =
      Port.open({:spawn_executable, String.to_charlist(env)}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        args: args,
        cd: dir,
        env: []
      ])

    payload =
      payload
      |> Map.put("source", source)
      |> Jason.encode!()

    result =
      if Port.command(port, payload <> "\n") do
        collect(port, System.monotonic_time(:millisecond) + timeout, [], 0)
      else
        kill(port)
        {:error, :runtime_failed}
      end

    on_exit.()
    result
  rescue
    e ->
      Process.flag(:trap_exit, false)
      Logger.warning("Nuvio sandbox could not start: #{Exception.message(e)}")
      {:error, :runtime_failed}
  end

  defp collect(port, deadline, acc, size) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)
    ref = make_ref()
    pid = self()
    timer = :erlang.start_timer(left, pid, {:nuvio_timeout, ref})

    receive do
      {^port, {:data, data}} ->
        :erlang.cancel_timer(timer)

        if size + byte_size(data) > @max_output do
          kill(port)
          {:error, :output_too_large}
        else
          collect(port, deadline, [acc, data], size + byte_size(data))
        end

      {^port, {:exit_status, status}} ->
        :erlang.cancel_timer(timer)
        output = IO.iodata_to_binary(acc)
        if status == 0, do: {:ok, output}, else: {:error, {:exit, status, tail(output)}}

      {:timeout, _timer, {:nuvio_timeout, ^ref}} ->
        kill(port)
        {:error, :timeout}

      {:EXIT, ^port, reason} ->
        :erlang.cancel_timer(timer)
        {:error, {:exit, reason}}
    end
  end

  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)

      _ ->
        :ok
    end

    try do
      Port.close(port)
    rescue
      _ -> :ok
    end

    :ok
  end

  defp decode(output) do
    line =
      output
      |> String.split("\n", trim: true)
      |> Enum.reverse()
      |> Enum.find(&String.starts_with?(String.trim(&1), "{"))

    case line && Jason.decode(String.trim(line)) do
      {:ok, %{"ok" => true} = result} -> {:ok, result}
      {:ok, %{"ok" => false, "error" => error}} -> {:error, {:provider, error}}
      _ -> {:error, {:bad_output, tail(output)}}
    end
  end

  defp tail(output) when is_binary(output) do
    output |> String.slice(-800, 800) |> String.trim()
  end

  defp tail(_), do: ""

  defp realpath(path) do
    case System.cmd("realpath", [path], stderr_to_stdout: true) do
      {real, 0} -> String.trim(real)
      _ -> path
    end
  rescue
    _ -> path
  end

  defp runner_path do
    path =
      case :code.priv_dir(:roki) do
        dir when is_list(dir) -> Path.join(to_string(dir), "nuvio/runner.js")
        _ -> Path.expand("../../../priv/nuvio/runner.js", __DIR__)
      end

    # Node's permission model resolves symlinks before it checks the main module; the priv
    # directory in `_build` is a symlink, so hand it the real path it will stat.
    realpath(path)
  end
end
