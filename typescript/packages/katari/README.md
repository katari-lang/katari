# @katari-lang/cli

The Katari command-line tool, distributed as an npm package. Installs
the `katari` executable.

```sh
npm i -g @katari-lang/cli
katari --help
```

This package itself contains only a small Node shim. The actual binary
is shipped per-platform via optional dependencies:

| Platform | Package |
|---|---|
| Linux x64 | `@katari-lang/cli-linux-x64` |
| macOS Apple Silicon | `@katari-lang/cli-darwin-arm64` |

npm / pnpm pick the matching one automatically based on `os` / `cpu`.
macOS Intel users can run the Apple Silicon binary via Rosetta 2, or
build from source with stack.

## Optional companion: `@katari-lang/bundle`

`katari apply` invokes the `katari-bundle` CLI to produce sidecar JS
bundles. Install it alongside if you have sidecars:

```sh
npm i -g @katari-lang/cli @katari-lang/bundle
```

If your project has no sidecars (no `.ts` / `.js` files next to `.ktr`
sources), `@katari-lang/bundle` is not needed.

## Manual install (alternative)

Prebuilt tarballs live on
[GitHub Releases](https://github.com/katari-lang/katari/releases). Each
contains a single `katari` executable; drop it on your `PATH`.
