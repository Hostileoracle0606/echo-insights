// Which of many names occur in a text, in one pass.
//
// Checking each name with `text.includes(name)` costs O(V · T) for V names
// and text length T. A trie of the names, walked from each position of the
// text, costs O(T · L) for the longest name L, however many names there are.
// Matching is on UTF-16 code units, exactly like String.prototype.includes.

interface TrieNode {
  next: Map<number, TrieNode>;
  ends?: number[];
}

export class NameTrie {
  private readonly root: TrieNode = { next: new Map() };

  constructor(keys: Iterable<string>) {
    let index = 0;
    for (const key of keys) {
      let node = this.root;
      for (let i = 0; i < key.length; i++) {
        const unit = key.charCodeAt(i);
        let step = node.next.get(unit);
        if (!step) {
          step = { next: new Map() };
          node.next.set(unit, step);
        }
        node = step;
      }
      (node.ends ??= []).push(index);
      index++;
    }
  }

  /** Indexes of the keys that occur in `text`, as `text.includes(key)` would say. */
  containedIn(text: string): Set<number> {
    const found = new Set<number>(this.root.ends ?? []);
    for (let start = 0; start < text.length; start++) {
      let node = this.root;
      for (let i = start; i < text.length; i++) {
        const step = node.next.get(text.charCodeAt(i));
        if (!step) break;
        node = step;
        if (node.ends) for (const k of node.ends) found.add(k);
      }
    }
    return found;
  }
}
