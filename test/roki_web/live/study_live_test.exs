defmodule RokiWeb.StudyLiveTest do
  use RokiWeb.ConnCase

  import Phoenix.LiveViewTest

  @srt "1\n00:00:01,000 --> 00:00:03,500\nBonjour\n\n2\n00:00:04,000 --> 00:00:06,000\nÀ bientôt\n"

  test "the page is public and has everything the hook looks for", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/study")

    assert html =~ ~s(phx-hook="StudySidebar")
    assert html =~ ~s(data-video="study-video")
    assert html =~ ~s(id="study-video")

    for role <-
          ~w(list title count empty resume stage overlay subs-btn subs-list settings-btn audio-btn audio-menu next-btn lines-btn
                   theater fullscreen collapse compact offset later earlier study replay peek backdrop
                   video-file video-url-form demo) do
      assert html =~ ~s(data-role="#{role}"), "missing data-role=#{role}"
    end

    # the parts JavaScript owns are not patched away by LiveView
    for id <- ~w(study-ui study-sources) do
      assert Regex.match?(
               ~r/id="#{id}"[^>]*phx-update="ignore"|phx-update="ignore"[^>]*id="#{id}"/,
               html
             ),
             "#{id} must be phx-update=ignore"
    end
  end

  test "an uploaded SubRip file reaches the hook as WebVTT", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/study")

    upload =
      file_input(view, "#subtitles-form", :subtitles, [
        %{name: "episode.srt", content: @srt, type: "application/x-subrip"}
      ])

    render_upload(upload, "episode.srt")

    assert_push_event(view, "study:subtitles", %{vtt: vtt, name: "episode.srt"})
    assert String.starts_with?(vtt, "WEBVTT")
    assert vtt =~ "00:00:01.000 --> 00:00:03.500"
    assert vtt =~ "À bientôt"
  end

  test "something that is not a subtitle file is refused, not converted", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/study")

    upload =
      file_input(view, "#subtitles-form", :subtitles, [
        %{name: "notes.txt", content: "hello", type: "text/plain"}
      ])

    html = render_upload(upload, "notes.txt")

    assert html =~ "not a subtitle file"
    refute_push_event(view, "study:subtitles", _)
  end

  test "a file over 5 MB is refused", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/study")
    big = String.duplicate("a", 5_000_001)

    upload = file_input(view, "#subtitles-form", :subtitles, [%{name: "huge.srt", content: big}])
    assert {:error, [[_, :too_large]]} = render_upload(upload, "huge.srt")
  end
end
