defmodule Roki.Study do
  @moduledoc """
  Study mode: watching one title in the languages chosen for it, with the account's own settings
  left alone. The choice (audio and subtitle language) is remembered per account and title, in
  the account's laev directory, so the next time it is already filled in.

  A study session is the same laev scope as always with `lang` and `subs_lang` replaced. The
  replacement is held in the process dictionary under `:roki_study` and read by
  `Roki.Laev.run/2`, so every call a page makes inside `bind/1`'s process is in the chosen
  language. Work handed to another process does not inherit it: wrap that work in `wrap/2`.
  """

  @key :roki_study

  @doc "The remembered choice for a title: `%{\"lang\" => \"fr\", \"subs\" => \"fr\"}` or nil."
  def get(uuid, type, id) do
    with {:ok, body} <- File.read(path(uuid, type, id)),
         {:ok, %{"lang" => lang, "subs" => subs} = prefs} when is_binary(lang) and is_binary(subs) <-
           Jason.decode(body) do
      prefs
    else
      _ -> nil
    end
  end

  @doc "Remember the choice. `subs` is a language code or \"off\"."
  def put(uuid, type, id, lang, subs) do
    path = path(uuid, type, id)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(%{"lang" => clean(lang, "en"), "subs" => clean(subs, "off")}))
    :ok
  end

  @doc "What goes into the laev scope for a remembered choice (`%{}` for none)."
  def overrides(%{"lang" => lang, "subs" => subs}), do: %{lang: lang, subs_lang: subs}
  def overrides(_), do: %{}

  @doc "Bind a choice's overrides to this process."
  def bind(overrides) when overrides == %{}, do: Process.delete(@key)
  def bind(overrides) when is_map(overrides), do: Process.put(@key, overrides)

  @doc "The overrides bound to this process (`%{}` outside study mode)."
  def current, do: Process.get(@key) || %{}

  def active?, do: current() != %{}

  @doc "`fun` for another process (a task, `start_async`) that keeps what is bound here."
  def wrap(fun) when is_function(fun, 0) do
    overrides = current()

    fn ->
      bind(overrides)
      fun.()
    end
  end

  defp path(uuid, type, id) when type in ["movie", "tv"] and is_integer(id),
    do: Path.join([Roki.Laev.dir(uuid), "roki-study", "#{type}-#{id}.json"])

  defp clean(value, default) do
    case value |> to_string() |> String.trim() |> String.downcase() do
      "" -> default
      code -> String.slice(code, 0, 12)
    end
  end
end
