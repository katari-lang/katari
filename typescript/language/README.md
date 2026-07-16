# @katari-lang/language

The single source of truth for Katari's editor-language artifacts:

- `katari.tmLanguage.json` — the TextMate grammar (`source.katari`)
- `language-configuration.json` — comments, brackets, auto-closing pairs, indentation

Consumers must not keep their own copies:

- **`typescript/vscode`** copies both files in at build time (`scripts/bundle.mjs`); the copies
  are gitignored build artifacts.
- **katari-web** imports `@katari-lang/language/grammar` for its code-block highlighting.

The grammar mirrors the compiler's lexical structure. When `reservedWords` in
`haskell/compiler/src/Katari/Parser/Lexer.hs` changes, change the grammar too — the test
(`pnpm test`) trips if a reserved word has no grammar rule. Positional words the lexer leaves
unreserved (`forever`, `extends`, `literal`) are highlighted with lookaheads that reproduce the
parser's positional recognition.
