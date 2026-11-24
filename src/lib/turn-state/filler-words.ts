/**
 * Hesitation sounds Gemini's transcription keeps ("um", "uh", "hmm"). Mirrors
 * lib/logic/filler_words.dart rule for rule.
 *
 * Only sounds that never carry meaning are removed. Real words sometimes used
 * as filler ("like", "well", "you know") and affirmative sounds ("uh-huh",
 * "mm-hmm") stay, because removing them can change what the user said.
 */
const FILLER =
  /(,\s*)?(?<![\w'-])(u+m+|u+h+m*|e+r+m*|h+m+|m{2,})(?![\w'-])(\s*(?:,|…|\.{2,}))?\s*/gi;
const SENTENCE_END = /(^|[.?!])\s*$/;
const SPACE_BEFORE_PUNCT = /\s+([,.?!;:])/g;
const SPACES = /\s{2,}/g;
const ONLY_PUNCT = /^[\s,.…?!;:-]*$/;

/**
 * `text` without hesitation sounds and the commas or ellipses around them. A
 * sentence that started with one starts with a capital again. A turn of
 * nothing but hesitation becomes empty.
 */
export function stripFillers(text: string): string {
  const matches = [...text.matchAll(FILLER)];
  if (matches.length === 0) return text;

  let out = "";
  let last = 0;
  let capitalizeNext = false;
  const keep = (segment: string) => {
    if (capitalizeNext) {
      const i = segment.search(/[A-Za-z]/);
      if (i >= 0) {
        segment = segment.slice(0, i) + segment[i].toUpperCase() + segment.slice(i + 1);
        capitalizeNext = false;
      }
    }
    out += segment;
  };

  for (const match of matches) {
    keep(text.slice(last, match.index));
    if (SENTENCE_END.test(out)) capitalizeNext = true;
    out += " ";
    last = match.index! + match[0].length;
  }
  keep(text.slice(last));

  const cleaned = out.replace(SPACE_BEFORE_PUNCT, "$1").replace(SPACES, " ").trim();
  return ONLY_PUNCT.test(cleaned) ? "" : cleaned;
}
