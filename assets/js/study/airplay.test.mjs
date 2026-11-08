import test from "node:test"
import assert from "node:assert/strict"
import {remoteSubtitleTrack, shortCode} from "./airplay.js"

const tt = (...list) => list.map(([label, language, kind = "subtitles"]) => ({label, language, kind, mode: "disabled"}))

test("the receiver's track is found by name, else by language, telling fetched from embedded", () => {
  const tracks = tt(["Japanese", "ja"], ["English", "en"], ["English (fetched)", "en"], ["English (OpenSubtitles)", "en"], ["Chapters", "en", "chapters"])
  assert.equal(remoteSubtitleTrack(tracks, {url: "/stream/x/sub0.vtt", lang: "jpn", label: "Japanese"}), tracks[0])
  assert.equal(remoteSubtitleTrack(tracks, {url: "/stream/x/sub1.vtt", lang: "eng", label: "English"}), tracks[1])
  // A provider's file is labelled by the provider in the page; the playlist says "(fetched)".
  assert.equal(remoteSubtitleTrack(tracks, {url: "/stream/x/ext-en.vtt", lang: "en", label: "English · Jimaku · file"}), tracks[2])
  assert.equal(remoteSubtitleTrack(tracks, {url: "/stream/x/ext-eng-os12.vtt", lang: "eng", label: "English · OpenSubtitles · r"}), tracks[3])
  // An embedded track whose page label differs still lands on the plain one of its language.
  assert.equal(remoteSubtitleTrack(tracks, {url: "/stream/x/sub1.vtt", lang: "en", label: "English (SDH)"}), tracks[1])
  assert.equal(remoteSubtitleTrack(tracks, {url: "/stream/x/sub9.vtt", lang: "fr", label: "French"}), null)
  assert.equal(remoteSubtitleTrack(tracks, null), null)
  // The page's own <track> elements are never the receiver's.
  const ours = tt(["Japanese", "ja"])
  assert.equal(remoteSubtitleTrack([...ours, ...tracks], {url: "/stream/x/sub0.vtt", lang: "ja", label: "Japanese"}, new Set(ours)), tracks[0])
})

test("language codes meet in the middle", () => {
  assert.equal(shortCode("jpn"), "ja")
  assert.equal(shortCode("ja"), "ja")
  assert.equal(shortCode("en-US"), "en")
  assert.equal(shortCode("fre"), "fr")
  assert.equal(shortCode(""), "")
})
