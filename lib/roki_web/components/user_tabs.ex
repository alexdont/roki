defmodule RokiWeb.UserTabs do
  @moduledoc "Shelf / Stats / Calendar — the three pages that belong to one user."
  use RokiWeb, :html

  attr :username, :string, required: true
  attr :active, :atom, required: true, values: [:shelf, :stats, :calendar]

  def user_tabs(assigns) do
    ~H"""
    <nav class="tabs tabs-box w-fit max-w-full overflow-x-auto" role="tablist">
      <.link navigate={~p"/#{@username}/home"} class={["tab", @active == :shelf && "tab-active"]}>
        Shelf
      </.link>
      <.link navigate={~p"/#{@username}/stats"} class={["tab", @active == :stats && "tab-active"]}>
        Stats
      </.link>
      <.link
        navigate={~p"/#{@username}/calendar"}
        class={["tab", @active == :calendar && "tab-active"]}
      >
        Calendar
      </.link>
    </nav>
    """
  end
end
