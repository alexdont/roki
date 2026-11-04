import test from "node:test"
import assert from "node:assert/strict"
import {languageName, sentencePrompt, wordPrompt} from "./prompt.js"

test("language names come from their codes", () => {
  assert.equal(languageName("ja"), "Japanese")
  assert.equal(languageName("fr"), "French")
  assert.equal(languageName(""), "the original language")
})

test("a sentence prompt names the line, the languages and every section, in order", () => {
  const p = sentencePrompt({sentence: "  Ça  roule ?\n", lang: "fr", answerLang: "en", title: "Primetime"})
  assert.match(p, /French teacher/)
  assert.match(p, /from "Primetime"/)
  assert.match(p, /"Ça roule \?"/)
  const order = ["## Word by word", "## Grammar", "## Idioms and set phrases", "## Register", "## Meaning"].map((h) => p.indexOf(h))
  assert.ok(order.every((i) => i > 0) && order.join() === [...order].sort((a, b) => a - b).join())
  assert.match(p, /DO NOT translate it word for word/)
  assert.match(p, /Answer in English/)
})

test("a word prompt asks about the word in its line, with the dictionary form when it differs", () => {
  const p = wordPrompt({word: "mangeons", lemma: "manger", sentence: "Nous mangeons ici.", lang: "fr", answerLang: "es"})
  assert.match(p, /"mangeons" \(dictionary form: manger\)/)
  assert.match(p, /Answer in Spanish/)
  assert.match(p, /## The word/)
  assert.doesNotMatch(p, /## Word by word/)
  assert.doesNotMatch(wordPrompt({word: "ici", lemma: "ici", sentence: "Ici.", lang: "fr", answerLang: "en"}), /dictionary form:/)
})

test("no title, no 'from'", () => {
  assert.doesNotMatch(sentencePrompt({sentence: "Oui.", lang: "fr", answerLang: "en"}), /from "/)
})
