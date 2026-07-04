# @katari-lang/cli

The `katari` command, installable from npm.

This package is a thin Node shim: the actual CLI is a prebuilt native
binary shipped by the matching `@katari-lang/cli-<platform>` package
(selected automatically by npm/pnpm as an optionalDependency). The shim
locates that binary, wires up `katari-bundle` (from
`@katari-lang/bundle`, used by `katari apply` for FFI sidecars), and
forwards arguments, stdio, and the exit code untouched.

## Install

```sh
npm i -g @katari-lang/cli
# or per project
pnpm add -D @katari-lang/cli
```

## Usage

```sh
katari init my-project
katari check
katari apply
katari run main.main
```

Run `katari --help` for the full command list.

## Supported platforms

- `linux-x64`
- `darwin-arm64` (Intel macOS runs via Rosetta 2)

On other platforms, download a release tarball from
<https://github.com/katari-lang/katari/releases> or build from source
with stack.
