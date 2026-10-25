defmodule RokiWeb.NotesLive do
  @moduledoc """
  `/notes/laev` — the current task for the laev package agent, as one block of text with a copy button. Only for an admin of the site: the task is the
  owner's working note, not part of the product.
  """
  use RokiWeb, :live_view

  alias PhoenixKit.Users.Auth.Scope

  @brief Path.expand("../../../priv/notes/laev-agent-brief.md", __DIR__)
  @external_resource @brief

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    if scope && Scope.authenticated?(scope) && Scope.can_access_admin_area?(scope) do
      {:ok, socket |> assign(:page_title, "laev task") |> assign(:brief, File.read!(@brief))}
    else
      {:ok, push_navigate(socket, to: ~p"/home")}
    end
  end

  @impl true
  def render(%{brief: _} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      wide
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      current_path="/notes/laev"
    >
      <div class="space-y-3">
        <div class="flex flex-wrap items-center gap-3">
          <h1 class="text-2xl font-bold tracking-tight">Task for the laev agent</h1>
          <span class="text-sm text-base-content/60">
            {byte_size(@brief) |> div(1024)} KB · {length(String.split(@brief, "\n"))} lines
          </span>
          <button
            type="button"
            class="btn btn-primary btn-sm ml-auto"
            onclick="const t=document.getElementById('brief-text');navigator.clipboard.writeText(t.value).then(()=>{this.textContent='Copied'}).catch(()=>{t.select();this.textContent='Selected — press Ctrl+C'})"
          >
            Copy all
          </button>
        </div>
        <p class="text-sm text-base-content/60">
          Paste it to the agent that works on the laev package. It is self-contained.
        </p>
        <textarea
          id="brief-text"
          readonly
          rows="38"
          spellcheck="false"
          class="textarea textarea-bordered w-full font-mono text-xs leading-relaxed"
        >{@brief}</textarea>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns), do: ~H""
end
