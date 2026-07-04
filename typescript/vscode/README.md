# katari-vscode

VSCode extension for the Katari language: syntax highlighting (TextMate
grammar) + language client (LSP).

## Features

- `.ktr` syntax highlighting.
- Hover types, go-to-definition, find-references, completion, and
  diagnostics — all served by the
  [`katari-lsp`](../../../haskell/katari-lsp) server.

## Setup

1. Install the LSP server on `PATH`:
   ```sh
   stack install katari-lsp
   ```
2. Build the extension:
   ```sh
   cd typescript/packages/katari-vscode
   pnpm install
   pnpm run build
   ```
3. Launch VSCode pointing at this directory:
   ```sh
   code --extensionDevelopmentPath=$PWD
   ```
   Then open any `.ktr` file (e.g. the e2e samples).

If `katari-lsp` is not on `PATH`, set the absolute path via the
`katari.server.path` setting in VSCode.

## Manual smoke test checklist

- Hover over a function name → shows type-info popup.
- F12 on a name → jumps to its definition.
- Shift+F12 → lists all references.
- Ctrl+Space → completion popup with locals + top-level callables.
- Introduce a typo → red squiggle appears.
- Fix it → squiggle disappears.
