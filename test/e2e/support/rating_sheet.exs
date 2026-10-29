# Renders the rating dialog as the page first draws it, for test/e2e/rating_slider.js:
#
#   mix run test/e2e/support/rating_sheet.exs <directory>
#
# One file for each case the script drives: a TMDB slider on seven, a MyAnimeList slider on seven,
# and a TMDB slider that opens on ten.
import Phoenix.LiveViewTest

[dir] = System.argv()
File.mkdir_p!(dir)

title = %{title: "Masterplan", vote: 6.9, vote_count: 1204, type: "movie", id: 1}

render = fn rating ->
  %{title: title, rating: rating, error: nil, label: nil, __changed__: nil}
  |> RokiWeb.TitleLive.rate_sheet()
  |> rendered_to_string()
end

for {name, rating} <- [
      {"tmdb", %{state: :ok, value: 7.0, provider: :tmdb}},
      {"mal", %{state: :ok, value: 7.0, provider: :mal}},
      {"gold", %{state: :ok, value: 10.0, provider: :tmdb}}
    ] do
  File.write!(Path.join(dir, "#{name}.html"), render.(rating))
end
