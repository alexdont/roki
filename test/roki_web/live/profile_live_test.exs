defmodule RokiWeb.ProfileLiveTest do
  use RokiWeb.ConnCase

  import Phoenix.LiveViewTest

  defp register(username) do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "#{username}@example.com",
        "password" => "a-long-enough-password-123",
        "username" => username
      })

    user
  end

  defp signed_in(user) do
    token = PhoenixKit.Users.Auth.generate_user_session_token(user, [])
    Plug.Test.init_test_session(build_conn(), %{user_token: token})
  end

  test "a name nobody has shows nothing; every profile is open to a visitor", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/nobody-here")
    assert html =~ "There is no one called"

    register("quietone")
    {:ok, view, html} = live(conn, "/quietone")
    assert html =~ "quietone"
    assert html =~ "written anything here yet"
    # Empty shelves are the owner's to see, not a visitor's.
    refute render_async(view) =~ "Favorite Movies"
  end

  test "the owner writes the words where they go, and the rest from the banner's button", %{
    conn: conn
  } do
    user = register("ownerone")
    {:ok, view, html} = live(signed_in(user), "/ownerone")
    assert html =~ "Press here to write it"
    assert html =~ "Edit profile"

    # The placeholder becomes the place to write, Enter (the form) keeps it.
    view |> element("button", "Say something about yourself") |> render_click()
    assert has_element?(view, "form input[name=bio]")
    view |> form("form[phx-submit=bio_save]", %{bio: "Mostly anime."}) |> render_submit()
    html = render(view)
    assert html =~ "Mostly anime."
    refute html =~ "Press here to write it"

    # Written, the words are no longer a button; the panel on the banner changes them.
    refute has_element?(view, "button", "Mostly anime.")
    view |> element("button", "Edit profile") |> render_click()
    assert has_element?(view, "#profile-form")
    assert has_element?(view, "#profile-form a", "Change picture")
    refute has_element?(view, "#profile-form input[name='profile[public]']")

    view |> form("#profile-form", profile: %{bio: "Mostly anime, some films."}) |> render_submit()
    assert render(view) =~ "Mostly anime, some films."

    # A visitor sees it all, and the watched page with its controls.
    {:ok, _view, html} = live(conn, "/ownerone")
    assert html =~ "Mostly anime, some films."
    assert html =~ "Watched →"

    {:ok, _view, html} = live(conn, "/ownerone/watched")
    assert html =~ "By rating"
    assert html =~ "Rated 10"
  end

  test "the shelves are the owner's to fill, ten a shelf, from what they watched", %{conn: conn} do
    user = register("shelfowner")
    {:ok, view, _html} = live(signed_in(user), "/shelfowner")
    html = render_async(view)
    assert html =~ "Favorite Movies"
    assert html =~ "Nothing on this shelf yet"

    # A visitor sees only the shelves with something on them.
    {:ok, visitor, _} = live(conn, "/shelfowner")
    refute render_async(visitor) =~ "Favorite Movies"

    assert {:ok, favs} = Roki.Profile.add_favorite(user.uuid, :movie, {"movie", 10_331}, "Easy A")
    assert [%{title: "Easy A", position: 1, badge: "#1"}] = favs.movie
    assert {:error, msg} = Roki.Profile.add_favorite(user.uuid, :tv, {"movie", 10_331}, "Easy A")
    assert msg =~ "already"

    for n <- 1..9,
        do: {:ok, _} = Roki.Profile.add_favorite(user.uuid, :movie, {"movie", n}, "Film #{n}")

    assert {:error, msg} =
             Roki.Profile.add_favorite(user.uuid, :movie, {"movie", 99}, "One too many")

    assert msg =~ "holds 10"

    {:ok, favs} = Roki.Profile.move_favorite(user.uuid, {"movie", 9}, :up)
    assert Enum.map(favs.movie, & &1.id) |> Enum.take(3) == [10_331, 1, 2]
    assert Enum.map(Enum.drop(favs.movie, 8), & &1.id) == [9, 8]
    {:ok, favs} = Roki.Profile.remove_favorite(user.uuid, {"movie", 10_331})
    assert Enum.map(favs.movie, & &1.position) == Enum.to_list(1..9)
    assert hd(favs.movie).id == 1
  end

  test "manga is greyed out for everyone, and its shelf cannot be edited" do
    user = register("mangafan")
    {:ok, view, _} = live(signed_in(user), "/mangafan")
    html = render_async(view)
    assert html =~ "Favorite Manga"
    assert html =~ "Coming soon"
    assert html =~ "opacity-50 grayscale"
    refute has_element?(view, "button[phx-click=shelf_edit][phx-value-kind=manga]")
    assert has_element?(view, "button[phx-click=shelf_edit][phx-value-kind=movie]")
  end

  # Rendered HTML line-wraps wherever the template happens to wrap, which `mix format` may change
  # without changing a thing on screen — so text assertions compare on one line.
  defp squish(html), do: String.replace(html, ~r/\s+/, " ")

  test "editing a shelf: crosses, a drag hook, empty places that open the picker", %{conn: _conn} do
    user = register("shelfedit")
    {:ok, bin} = Ecto.UUID.dump(user.uuid)

    for {id, title} <- [{1, "First Film"}, {2, "Second Film"}] do
      Roki.Repo.query!(
        "insert into roki_watched (user_uuid, type, id, tmdb_type, tmdb_id, title, anime, at, dated) values ($1, 'movie', $2, 'movie', $2, $3, false, now(), true)",
        [bin, id, title]
      )
    end

    {:ok, view, _} = live(signed_in(user), "/shelfedit")
    render_async(view)
    view |> element("button[phx-click=shelf_edit][phx-value-kind=movie]") |> render_click()

    # Ten empty places, each one opens the picker; the grid is the drag hook's.
    assert has_element?(
             view,
             "ul#shelf-movie[phx-hook=SortableGrid][data-sortable-event=shelf_reorder]"
           )

    assert has_element?(view, "button[phx-click=pick_open][phx-value-kind=movie]")

    assert view |> render() |> String.split(~s(phx-click="pick_open")) |> length() == 12
    render_click(view, "pick_open", %{"kind" => "movie"})
    html = render_async(view)
    assert html =~ "Choose your favorite movies"
    assert html =~ "First Film"

    # Tick both, add: they are on the shelf, in the picker's order, with crosses and grips.
    view |> element("button[phx-click=pick_toggle][phx-value-key='movie:1']") |> render_click()
    view |> element("button[phx-click=pick_toggle][phx-value-key='movie:2']") |> render_click()
    assert view |> element("#pick-count") |> render() |> squish() =~ "<b>2</b> of 10 on the shelf"
    view |> element("button", "Add 2 to the shelf") |> render_click()

    refute render(view) =~ "Choose your favorite movies"
    assert has_element?(view, "li.sortable-item[data-id='movie:1']")

    assert has_element?(
             view,
             "li.sortable-item[data-id='movie:2'] button[phx-click=shelf_remove]"
           )

    # The whole poster is what is dragged: no handle, no strip.
    refute has_element?(view, "li.sortable-item .pk-drag-handle")
    refute has_element?(view, "ul#shelf-movie[data-sortable-handle]")

    # Unranked by default: no numbers on the shelf until the owner turns them on.
    refute has_element?(view, "li.sortable-item .badge-primary")
    render_click(view, "shelf_ranked", %{"kind" => "movie"})
    assert has_element?(view, "li.sortable-item .badge-primary", "#1")
    assert render(view) =~ "Top 10 Movies"
    render_click(view, "shelf_ranked", %{"kind" => "movie"})
    refute has_element?(view, "li.sortable-item .badge-primary")
    assert render(view) =~ "Favorite Movies"
    refute render(view) =~ "Top 10 Movies"

    # A drag: the new order is kept.
    render_hook(view, "shelf_reorder", %{
      "ordered_ids" => ["movie:2", "movie:1"],
      "moved_id" => "movie:2",
      "kind" => "movie"
    })

    assert Enum.map(Roki.Profile.favorites(user.uuid).movie, & &1.id) == [2, 1]

    # A cross takes one off and the rest close up.
    view
    |> element("li.sortable-item[data-id='movie:2'] button[phx-click=shelf_remove]")
    |> render_click()

    assert Enum.map(Roki.Profile.favorites(user.uuid).movie, &{&1.id, &1.position}) == [{1, 1}]

    # In the picker what is on the shelf is ticked, not greyed out: unticking it and ticking
    # another swaps them on save.
    render_click(view, "pick_open", %{"kind" => "movie"})
    render_async(view)

    assert has_element?(
             view,
             "button[phx-click=pick_toggle][phx-value-key='movie:1'][aria-pressed=true]"
           )

    refute has_element?(view, "button[phx-click=pick_toggle][disabled]")
    view |> element("button[phx-click=pick_toggle][phx-value-key='movie:1']") |> render_click()
    view |> element("button[phx-click=pick_toggle][phx-value-key='movie:2']") |> render_click()
    view |> element("button", "Save changes") |> render_click()
    assert Enum.map(Roki.Profile.favorites(user.uuid).movie, & &1.id) == [2]
  end

  test "the watched page also lists what was started and not finished, marked, and not selectable" do
    user = register("halfway")
    {:ok, bin} = Ecto.UUID.dump(user.uuid)

    for {id, title, status, note} <- [
          {1, "Done Film", "finished", nil},
          {2, "Half Show", "progress", "2/5 seasons"},
          {3, "Current Show", "up_to_date", "3/3 seasons"}
        ] do
      Roki.Repo.query!(
        "insert into roki_watched (user_uuid, type, id, tmdb_type, tmdb_id, title, anime, at, dated, status, note) values ($1, $2, $3, $2, $3, $4, false, now(), true, $5, $6)",
        [bin, if(id == 1, do: "movie", else: "tv"), id, title, status, note]
      )
    end

    # The finished history stays finished-only: counts, hours and shelf pickers read it.
    assert Roki.Profile.history(user.uuid) |> Enum.map(& &1.title) == ["Done Film"]
    assert Roki.Profile.history_all(user.uuid) |> length() == 3

    {:ok, view, _} = live(signed_in(user), "/halfway/watched")
    html = render_async(view)
    assert html =~ "Half Show"
    assert html =~ "In progress"
    assert html =~ "Up to date"

    # The count follows the status filter.
    {:ok, view, _} = live(signed_in(user), "/halfway/watched?status=progress")
    html = render_async(view)
    assert html =~ "Half Show"
    refute html =~ "Done Film"
    refute html =~ "Current Show"

    # Select mode only takes finished titles.
    {:ok, view, _} = live(signed_in(user), "/halfway/watched")
    render_async(view)
    view |> element("button[phx-click=select_mode]") |> render_click()
    assert has_element?(view, "button[phx-click=select_toggle][phx-value-key='movie:1']")
    refute has_element?(view, "button[phx-click=select_toggle][phx-value-key='tv:2']")
    render_click(view, "select_toggle", %{"key" => "tv:2"})
    assert render(view) =~ "0</b> selected"
    render_click(view, "select_all", %{})
    assert render(view) =~ "1</b> selected"
  end

  test "the watched page filters by genre (each kind's own ids) and by having no rating" do
    user = register("genrefan")
    {:ok, bin} = Ecto.UUID.dump(user.uuid)

    for {type, id, title, genres} <- [
          {"movie", 1, "Scary Film", [27, 53]},
          {"movie", 2, "Funny Film", [35]},
          {"tv", 3, "Action Show", [10759]},
          {"movie", 4, "Unread Film", nil}
        ] do
      Roki.Repo.query!(
        "insert into roki_watched (user_uuid, type, id, tmdb_type, tmdb_id, title, anime, at, dated, status) values ($1, $2, $3, $2, $3, $4, false, now(), true, 'finished')",
        [bin, type, id, title]
      )

      Roki.Repo.query!(
        "insert into roki_titles (type, id, name, genres, seen_at) values ($1, $2, $3, $4, now())",
        [type, id, title, genres]
      )
    end

    # Rated: the scary one. Unrated: the rest.
    Roki.Repo.query!(
      "insert into roki_ratings (user_uuid, type, id, score) values ($1, 'movie', 1, 8)",
      [bin]
    )

    {:ok, view, _} = live(signed_in(user), "/genrefan/watched?genre=horror")
    html = render_async(view)
    assert html =~ "Scary Film"
    refute html =~ "Funny Film"
    refute html =~ "Action Show"

    # A film's Action is not a show's Action: each kind is matched by its own ids.
    {:ok, view, _} = live(signed_in(user), "/genrefan/watched?genre=action")
    html = render_async(view)
    assert html =~ "Action Show"
    refute html =~ "Scary Film"

    # A title whose genres are not read yet is not guessed at.
    {:ok, view, _} = live(signed_in(user), "/genrefan/watched?genre=comedy")
    html = render_async(view)
    assert html =~ "Funny Film"
    refute html =~ "Unread Film"
    assert html =~ "Still reading the genres of 1 titles"

    # A genre that is not on the list is no filter.
    {:ok, view, _} = live(signed_in(user), "/genrefan/watched?genre=nonsense")
    assert render_async(view) =~ "Scary Film"

    # "Not rated yet": only what has no rating.
    {:ok, view, _} = live(signed_in(user), "/genrefan/watched?rating=none")
    html = render_async(view)
    assert html =~ "Funny Film"
    assert html =~ "Action Show"
    refute html =~ "Scary Film"

    assert Enum.map(
             Roki.Profile.arrange(
               Roki.Profile.history(user.uuid),
               Roki.Profile.ratings(user.uuid),
               :all,
               :latest,
               :none
             ),
             & &1.title
           )
           |> Enum.sort() ==
             ["Action Show", "Funny Film", "Unread Film"]

    assert Roki.Profile.rating_param("none") == :none
  end

  test "the watched page: rows and a grid, and only the owner selects, backdates and removes" do
    user = register("historian")
    other = register("visitor")
    {:ok, bin} = Ecto.UUID.dump(user.uuid)

    for {id, title} <- [{1, "Newest Film"}, {2, "Forgotten Film"}] do
      Roki.Repo.query!(
        "insert into roki_watched (user_uuid, type, id, tmdb_type, tmdb_id, title, anime, at, dated) values ($1, 'movie', $2, 'movie', $2, $3, false, now(), true)",
        [bin, id, title]
      )
    end

    # A visitor has the views, and no way to change anything.
    {:ok, visitor, _} = live(signed_in(other), "/historian/watched")
    html = render_async(visitor)
    assert html =~ "Newest Film"
    refute has_element?(visitor, "button[phx-click=select_mode]")
    render_click(visitor, "select_mode", %{})
    refute render(visitor) =~ "Edit watch date"
    render_click(visitor, "remove", %{})
    assert Roki.Profile.history(user.uuid) |> length() == 2

    # The owner: the list view carries the details, the three dots turn on select mode.
    {:ok, view, _} = live(signed_in(user), "/historian/watched?view=rows")
    html = render_async(view)
    assert html =~ "Forgotten Film"
    assert html =~ "not rated"
    assert has_element?(view, "button[phx-click=select_mode]", "Select")

    # One button turns select mode on, and off again.
    view |> element("button[phx-click=select_mode]") |> render_click()
    assert render(view) =~ "0</b> selected"
    assert has_element?(view, "button[phx-click=select_mode]", "Done")
    view |> element("button[phx-click=select_mode]") |> render_click()
    refute render(view) =~ "selected"
    view |> element("button[phx-click=select_mode]") |> render_click()

    # Pick the forgotten one, put it years back: it drops under the other, which keeps its place.
    view |> element("button[phx-click=select_toggle][phx-value-key='movie:2']") |> render_click()
    assert render(view) =~ "1</b> selected"
    view |> element("button", "Edit watch date") |> render_click()
    assert has_element?(view, "#date-form input[type=date]")
    # It opens on today's date, not blank, so it is plain what the field is.
    today = Date.utc_today() |> Date.to_iso8601()
    assert has_element?(view, "#date-form input[type=date][value='#{today}']")

    # The future is refused.
    future = Date.utc_today() |> Date.add(30) |> Date.to_iso8601()
    view |> form("#date-form", %{date: future}) |> render_submit()
    assert render(view) =~ "has happened"

    view |> form("#date-form", %{date: "2018-03-09"}) |> render_submit()
    html = render(view)
    assert html =~ "set to March 9, 2018"
    assert html =~ "March 2018"

    assert Enum.map(Roki.Profile.history(user.uuid), & &1.title) == [
             "Newest Film",
             "Forgotten Film"
           ]

    # Remove the newest.
    view |> element("button[phx-click=select_toggle][phx-value-key='movie:1']") |> render_click()
    view |> element("button", "Remove") |> render_click()
    assert render(view) =~ "1 title taken off"
    assert Enum.map(Roki.Profile.history(user.uuid), & &1.title) == ["Forgotten Film"]
  end
end
