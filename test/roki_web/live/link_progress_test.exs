defmodule RokiWeb.LinkProgressTest do
  use RokiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Roki.Link

  @show 4242

  alias Roki.LinkFakeWatch, as: FakeWatch

  defmodule Host do
    use Phoenix.LiveView

    def mount(_params, %{"uuid" => uuid}, socket),
      do: {:ok, Phoenix.Component.assign(socket, uuid: uuid, solo?: false, reloads: 0)}

    def handle_info({:link_solo, s}, socket),
      do: {:noreply, Phoenix.Component.assign(socket, :solo?, s)}

    def handle_info(:link_reload, socket),
      do: {:noreply, Phoenix.Component.assign(socket, :reloads, socket.assigns.reloads + 1)}

    def handle_info(_, socket), do: {:noreply, socket}

    def render(assigns) do
      ~H"""
      <p id="state">solo={inspect(@solo?)} reloads={@reloads}</p>
      <.live_component
        module={RokiWeb.LinkProgress}
        id="link-progress"
        uuid={@uuid}
        title={%{id: 4242, type: "tv", title: "Frieren"}}
      />
      """
    end
  end

  setup %{conn: conn} do
    FakeWatch.start()
    Application.put_env(:roki, :link_watch, FakeWatch)

    on_exit(fn ->
      Application.delete_env(:roki, :link_watch)
      FakeWatch.stop()
    end)

    make = fn name ->
      {:ok, u} =
        PhoenixKit.Users.Auth.register_user(%{
          "email" => "#{name}@example.com",
          "password" => "a-long-enough-password-123",
          "username" => name
        })

      u.uuid
    end

    alex = make.("panelalex")
    max = make.("panelmax")
    Roki.Social.request(alex, max)
    Roki.Social.accept(max, alex)
    {:ok, conn: conn, alex: alex, max: max}
  end

  defp host(conn, uuid), do: live_isolated(conn, Host, session: %{"uuid" => uuid})

  test "invite a friend, who sees the request, reviews it and accepts", %{
    conn: conn,
    alex: alex,
    max: max
  } do
    FakeWatch.put(alex, for(e <- 1..6, do: {1, e}))

    {:ok, view, html} = host(conn, alex)
    assert html =~ "Link progress"

    view |> element("button", "Link progress") |> render_click()
    assert render(view) =~ "panelmax"

    view |> form("form[phx-submit=invite]", %{"friends" => [max]}) |> render_submit()
    assert render(view) =~ "Invitation sent"
    assert render(view) =~ "Waiting for panelmax"

    {:ok, mview, mhtml} = host(conn, max)
    assert mhtml =~ "panelalex wants to link progress"

    mview |> element("button", "Review") |> render_click()
    html = render_async(mview)
    assert html =~ "They have 6 episodes watched and you have none"

    mview |> form("form[phx-submit=accept]") |> render_submit()
    html = render(mview)
    assert html =~ "Progress linked with panelalex"
    assert FakeWatch.get(max) == MapSet.new(for e <- 1..6, do: {1, e})
    assert render(mview) =~ "reloads=1"
  end

  test "different progress asks which is right, and refuses a choice that is nobody's", %{
    conn: conn,
    alex: alex,
    max: max
  } do
    FakeWatch.put(alex, for(e <- 1..8, do: {1, e}))
    FakeWatch.put(max, for(e <- 1..2, do: {1, e}))
    {:ok, id} = Link.invite(alex, @show, [max])

    {:ok, view, _} = host(conn, max)
    view |> element("button", "Review") |> render_click()
    html = render_async(view)
    assert html =~ "Which one is right?"
    assert html =~ "Mine, 2 episodes"
    assert html =~ "panelalex&#39;s, 8 episodes"

    # A choice that names no member does nothing.
    view
    |> element("form[phx-submit=accept]")
    |> render_submit(%{"choice" => Ecto.UUID.generate()})

    assert render(view) =~ "Choose whose progress is right first"
    assert Link.active(max, @show) == nil

    view |> form("form[phx-submit=accept]", %{"choice" => alex}) |> render_submit()
    assert Link.active(max, @show).id == id
    assert FakeWatch.get(max) == MapSet.new(for e <- 1..8, do: {1, e})
  end

  test "pause, just me, and unlink", %{conn: conn, alex: alex, max: max} do
    {:ok, id} = Link.invite(alex, @show, [max])
    Link.accept(max, id)

    {:ok, view, html} = host(conn, alex)
    assert html =~ "Progress linked with panelmax"

    view |> element("input[phx-click=solo]") |> render_click()
    assert render(view) =~ "solo=true"
    assert render(view) =~ "Just me is on"

    view |> element("button", "Pause link") |> render_click()
    assert render(view) =~ "Paused"
    Link.mirror(max, @show, [{1, 1}])
    assert FakeWatch.get(alex) == MapSet.new()

    view |> element("button", "Resume link") |> render_click()
    refute render(view) =~ "Paused: what you mark"

    view |> element("button", "Unlink") |> render_click()
    assert render(view) =~ "Unlinked"
    assert render(view) =~ "solo=false"
    assert Link.active(alex, @show) == nil
  end

  test "a finished season asks both for a score and shows them together", %{
    conn: conn,
    alex: alex,
    max: max
  } do
    {:ok, id} = Link.invite(alex, @show, [max])
    Link.accept(max, id)
    Link.mirror(alex, @show, for(e <- 1..10, do: {1, e}))

    {:ok, aview, html} = host(conn, alex)
    assert html =~ "Season 1 is done. How was it?"
    aview |> form("form[phx-submit=rate_round]", %{"score" => "8"}) |> render_submit()
    assert render(aview) =~ "Your answer is in. 1 of 2 have answered."
    refute render(aview) =~ "linkmax"

    {:ok, mview, _} = host(conn, max)
    mview |> form("form[phx-submit=rate_round]", %{"score" => "9.5"}) |> render_submit()
    html = render(mview)
    assert html =~ "panelalex"
    assert html =~ "9.5"
    assert html =~ "Average 8.8"
  end
end
