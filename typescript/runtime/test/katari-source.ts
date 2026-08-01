// The one place a test that reads `.ktr` files AS TEXT strips the parts that are prose.
//
// Several trip-wires scan the stdlib source for declarations (`^request NAME`, `^primitive agent NAME`,
// …) because there is no Katari parser to reach for on this side and a top-level declaration is
// unambiguous at column 0. Anchoring alone is not enough: a docstring is free text that may contain
// anything, including a line that starts with `request ` at column 0, and one did — a `@"…"` body
// beginning `request this` was read as a third `-> never` declaration and failed `never-requests.test.ts`
// for a sentence. Comments have the same exposure.
//
// So prose comes out BEFORE any declaration is scanned, which is what `check-twin.mjs` in the
// katari-packages tree does for the same reason. Stripped text is replaced character-for-character with
// spaces (newlines kept), so offsets, line numbers and column-0 anchoring all still hold against the
// original file.

/** The index just past the closing quote of the string literal whose body starts at `start`, or the end
 *  of the source when it is never closed. `\"` and `\\` escape as in the lexer (`rawStringLiteral`). */
function endOfStringLiteral(source: string, start: number): number {
  for (let index = start; index < source.length; index++) {
    const character = source[index];
    if (character === "\\") index++;
    else if (character === '"') return index + 1;
  }
  return source.length;
}

/**
 * `source` with every line comment, block comment and `@"…"` docstring blanked out —
 * each replaced by spaces of the same width, with newlines preserved, so the result lines up with the
 * original byte for byte and only structure is left to scan.
 *
 * Ordinary string literals are kept verbatim, but are skipped over rather than read, so a `//` or a `/*`
 * inside one (a URL, a format string) does not open a comment.
 */
export function withoutCommentsAndDocstrings(source: string): string {
  const characters = source.split("");
  const blank = (from: number, to: number): void => {
    for (let index = from; index < to; index++) {
      if (characters[index] !== "\n") characters[index] = " ";
    }
  };

  let index = 0;
  while (index < source.length) {
    const character = source[index];
    const next = source[index + 1];
    if (character === "/" && next === "/") {
      const newline = source.indexOf("\n", index);
      const end = newline === -1 ? source.length : newline;
      blank(index, end);
      index = end;
    } else if (character === "/" && next === "*") {
      const close = source.indexOf("*/", index + 2);
      const end = close === -1 ? source.length : close + 2;
      blank(index, end);
      index = end;
    } else if (character === "@" && next === '"') {
      const end = endOfStringLiteral(source, index + 2);
      blank(index, end);
      index = end;
    } else if (character === '"') {
      index = endOfStringLiteral(source, index + 1);
    } else {
      index++;
    }
  }
  return characters.join("");
}
