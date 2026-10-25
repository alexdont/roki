defmodule Roki.Study do
  @moduledoc """
  Study mode: watching one title in the languages chosen for it, with the account's own settings
  left alone. The choice (audio and subtitle language) is remembered per account and title, in
  the account's laev directory, so the next time it is already filled in.

  A study session is the same laev scope as always with `lang` and `subs_lang` replaced, by
  laev's own scope overrides (`Laev.Scope.put_overrides/1`). `Laev.Scope.async/1` carries them to
  other processes; Phoenix's `start_async` does not, so wrap that work in `wrap/1`.
  """

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

  @doc "Bind a choice's overrides to this process (laev's scope overrides)."
  def bind(overrides) when overrides == %{}, do: Laev.Scope.clear_overrides()
  def bind(overrides) when is_map(overrides), do: Laev.Scope.put_overrides(overrides)

  @doc "The overrides bound to this process (`%{}` outside study mode)."
  def current, do: Laev.Scope.overrides()

  def active?, do: current() != %{}

  @doc "`fun` for a process laev does not carry the overrides into (`start_async`)."
  def wrap(fun) when is_function(fun, 0) do
    overrides = current()
    fn -> Laev.Scope.with_overrides(overrides, fun) end
  end

  defp path(uuid, type, id) when type in ["movie", "tv"] and is_integer(id),
    do: Path.join([Roki.Laev.dir(uuid), "roki-study", "#{type}-#{id}.json"])

  defp clean(value, default) do
    case value |> to_string() |> String.trim() |> String.downcase() do
      "" -> default
      "off" -> "off"
      other -> (Laev.Config.normalise_lang(other) || other) |> String.slice(0, 12)
    end
  end
end
