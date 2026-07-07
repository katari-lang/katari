# katari-vscode

VSCode extension for the Katari language: syntax highlighting (TextMate
grammar) + language client (LSP).

## Features

- `.ktr` syntax highlighting.
- Hover types, go-to-definition, find-references, completion, and
  diagnostics — all served by the
  [`katari-lsp`](../../haskell/lsp) server.

## The bundled language server

A published (release-page) install is **platform-specific**: each VSIX
bundles the matching `katari-lsp` binary at `bin/katari-lsp`, so there is
nothing to install separately. The extension resolves the server in three
tiers (see `src/extension.ts`):

1. an explicit `katari.server.path` setting (your own build — the override);
2. the bundled `bin/katari-lsp` (a release install);
3. `katari-lsp` on `PATH` (a from-source checkout — see below).

CI builds the per-platform VSIXes in `release-vsix.yml`, pulling each
binary from the `katari-lsp-<version>-<platform>.tar.gz` tarballs that
`release-katari.yml` attaches to the GitHub Release.

## Setup (from source)

Two ways to run the extension against a local checkout:

- **PATH (simplest for iterating on the LSP):** install the server on
  `PATH`, then launch a dev host — no binary is bundled, so tier 3 applies.
  ```sh
  stack install katari-lsp          # copies to ~/.local/bin
  pnpm --filter katari-vscode run build
  code --extensionDevelopmentPath=$PWD/typescript/vscode
  ```
  Re-run `stack install katari-lsp` after changing the LSP (a bare
  `stack build` only updates `.stack-work`, not `~/.local/bin`).

- **Bundled (to exercise the packaging path):** copy the locally built
  binary into `bin/` first, so tier 2 applies exactly like a release
  install.
  ```sh
  stack build katari-lsp
  pnpm --filter katari-vscode run server:copy   # → typescript/vscode/bin/katari-lsp
  pnpm --filter katari-vscode run package:local # builds a universal .vsix with the binary
  ```

Then open any `.ktr` file (e.g. the e2e samples). If `katari-lsp` cannot be
found, set an absolute path via the `katari.server.path` setting.

## Manual smoke test checklist

- Hover over a function name → shows type-info popup.
- F12 on a name → jumps to its definition.
- Shift+F12 → lists all references.
- Ctrl+Space → completion popup with locals + top-level callables.
- Introduce a typo → red squiggle appears.
- Fix it → squiggle disappears.
