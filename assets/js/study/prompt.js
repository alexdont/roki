// Prompts to paste into an AI chat, to be taught a word or a whole line of what is being watched.
// Pure: text in, text out (tested in prompt.test.mjs). Each asks for the same fixed layout, so the
// answer is always in the same place whatever the model: word by word, grammar, idioms and set
// phrases (never translated literally), register (formal, casual, slang), and the meaning of
// the whole. Written in English; the answer is asked for in the learner's own language.

// A language's name in English from its code ("ja" → "Japanese"); the code itself if unknown.
export function languageName(code) {
  const c = String(code || "").trim()
  if (!c) return "the original language"
  try {
    return new Intl.DisplayNames(["en"], {type: "language"}).of(c) || c
  } catch {
    return c
  }
}

const clean = (s) => String(s || "").replace(/\s+/g, " ").trim()

// Where the line is from, when known: a film or an episode.
const from = (title) => (clean(title) ? ` from "${clean(title)}"` : "")

// The layout of the answer, the same for a word and a line.
const LAYOUT = (answer, forWord) => `Answer in ${answer}, using exactly the headings below, in this order, and nothing before or after them. Be concise: short lines, no introduction, no closing remarks.

${forWord ? "## The word" : "## Word by word"}
${
  forWord
    ? `The word as written, its reading or romanization if the language has one, its dictionary form if it differs, its part of speech, and the exact conjugation or inflection it has here. Then what it means IN THIS LINE, and in one short line its other common meanings.`
    : `A list, in the order they appear: every word, particle or morpheme as written, its reading or romanization if the language has one, its dictionary form if different, its literal meaning, and its role (noun, verb and its conjugation, particle, grammar word...). End each with its register: FORMAL, NEUTRAL, CASUAL, SLANG, VULGAR or DIALECT.`
}

## Grammar
Every grammar point in ${forWord ? "the line that touches this word" : "the line"} (conjugation, particle, construction, word order), one line each: what it is, what it does here, and why it is used.

## Idioms and set phrases
Say whether ${forWord ? "this word is part of" : "any part of the line is"} an idiom, slang expression or set phrase. If it is, give its real meaning and tone, and DO NOT translate it word for word: an idiom's literal words make no sense and are not its meaning, so say "idiom: the literal words do not apply" and explain what people actually mean. If there is none, write "None".

## Register
Formal, neutral, casual, slang, vulgar or dialect? Who would say this, to whom, in what situation? Mark what is slang and what is formal.

## Meaning
One natural translation of the whole line into ${answer}, giving its meaning and tone (not word for word).`

// A whole line (or a few lines said together) to be explained.
export function sentencePrompt({sentence, lang, answerLang, title}) {
  const L = languageName(lang), A = languageName(answerLang)
  return `You are a patient ${L} teacher. I am learning ${L} from what I watch. Explain this line${from(title)} so that I understand every word, what is grammar, what is slang or formal, and what the whole line means.

Line (${L}):
"${clean(sentence)}"

${LAYOUT(A, false)}`
}

// One word in its line, to be explained as it is used there.
export function wordPrompt({word, lemma, sentence, lang, answerLang, title}) {
  const L = languageName(lang), A = languageName(answerLang)
  const w = clean(word)
  const base = clean(lemma) && clean(lemma) !== w ? ` (dictionary form: ${clean(lemma)})` : ""
  return `You are a patient ${L} teacher. I am learning ${L} from what I watch. Explain the word "${w}"${base} as it is used in this line${from(title)}, and what the line means.

Line (${L}):
"${clean(sentence)}"

Word: ${w}

${LAYOUT(A, true)}`
}
