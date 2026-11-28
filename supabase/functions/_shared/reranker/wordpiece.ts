// BERT-uncased WordPiece, as the memory reranker was trained with
// (MiniLM cross-encoder vocab). Pair encoding truncates only the second text,
// so the query is always whole. Parity with the Python tokenizer is tested
// on a fixture of real query–card pairs (tokenizer-fixture.json).

const isControl = (ch: string) => ch !== "\t" && ch !== "\n" && ch !== "\r" && /\p{C}/u.test(ch);
const isWhitespace = (ch: string) => ch === " " || ch === "\t" || ch === "\n" || ch === "\r" || /\p{Zs}/u.test(ch);
const isPunctuation = (ch: string) => {
  const cp = ch.codePointAt(0)!;
  if ((cp >= 33 && cp <= 47) || (cp >= 58 && cp <= 64) || (cp >= 91 && cp <= 96) || (cp >= 123 && cp <= 126)) return true;
  return /\p{P}/u.test(ch);
};
const isCjk = (cp: number) =>
  (cp >= 0x4e00 && cp <= 0x9fff) || (cp >= 0x3400 && cp <= 0x4dbf) || (cp >= 0x20000 && cp <= 0x2a6df) ||
  (cp >= 0x2a700 && cp <= 0x2b73f) || (cp >= 0x2b740 && cp <= 0x2b81f) || (cp >= 0x2b820 && cp <= 0x2ceaf) ||
  (cp >= 0xf900 && cp <= 0xfaff) || (cp >= 0x2f800 && cp <= 0x2fa1f);

function basicTokens(text: string): string[] {
  let cleaned = "";
  for (const ch of text) {
    const cp = ch.codePointAt(0)!;
    if (cp === 0 || cp === 0xfffd || isControl(ch)) continue;
    cleaned += isWhitespace(ch) ? " " : isCjk(cp) ? ` ${ch} ` : ch;
  }
  const out: string[] = [];
  for (const word of cleaned.split(" ").filter(Boolean)) {
    const plain = word.toLowerCase().normalize("NFD").replace(/\p{Mn}/gu, "");
    let current = "";
    for (const ch of plain) {
      if (isPunctuation(ch)) {
        if (current) out.push(current);
        out.push(ch);
        current = "";
      } else {
        current += ch;
      }
    }
    if (current) out.push(current);
  }
  return out;
}

export class WordPiece {
  private constructor(private readonly vocab: Map<string, number>) {}

  static fromVocab(text: string): WordPiece {
    const lines = text.split("\n");
    if (lines.at(-1) === "") lines.pop();
    return new WordPiece(new Map(lines.map((token, id) => [token, id])));
  }

  private id(token: string): number {
    return this.vocab.get(token) ?? this.vocab.get("[UNK]")!;
  }

  tokenize(text: string): number[] {
    const ids: number[] = [];
    for (const word of basicTokens(text)) {
      const chars = [...word];
      if (chars.length > 100) {
        ids.push(this.id("[UNK]"));
        continue;
      }
      const pieces: number[] = [];
      let start = 0;
      let bad = false;
      while (start < chars.length) {
        let end = chars.length;
        let found: number | undefined;
        while (start < end) {
          const piece = (start > 0 ? "##" : "") + chars.slice(start, end).join("");
          found = this.vocab.get(piece);
          if (found !== undefined) break;
          end -= 1;
        }
        if (found === undefined) {
          bad = true;
          break;
        }
        pieces.push(found);
        start = end;
      }
      ids.push(...(bad ? [this.id("[UNK]")] : pieces));
    }
    return ids;
  }

  /** [CLS] a [SEP] b [SEP], cutting b so the whole fits maxLength. */
  encodePair(a: string, b: string, maxLength: number): { inputIds: number[]; tokenTypeIds: number[] } {
    const first = this.tokenize(a);
    const second = this.tokenize(b).slice(0, Math.max(0, maxLength - first.length - 3));
    const cls = this.id("[CLS]");
    const sep = this.id("[SEP]");
    return {
      inputIds: [cls, ...first, sep, ...second, sep],
      tokenTypeIds: [...Array(first.length + 2).fill(0), ...Array(second.length + 1).fill(1)],
    };
  }
}
