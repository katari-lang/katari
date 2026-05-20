# Publishing Katari

Release artifacts are produced by GitHub Actions on `v*` tag push. This
document covers the **one-time setup** required before the first
release, then the per-release procedure.

## Distribution overview

| Artefact | Channel | Workflow |
|---|---|---|
| `katari` Haskell binary | GitHub Release tarballs | `release-katari.yml` |
| `katari-runtime` Docker image | `ghcr.io/katari-lang/katari-runtime` | `release-katari-runtime.yml` |
| `@katari-lang/*` (7 packages) | npm | `release-npm.yml` |
| `katari-vscode` VSIX | GitHub Release | `release-vsix.yml` |

The 7 npm packages are:

| Package | Type |
|---|---|
| `@katari-lang/cli` | shim |
| `@katari-lang/cli-linux-x64` | prebuilt binary |
| `@katari-lang/cli-darwin-arm64` | prebuilt binary |
| `@katari-lang/runtime` | library |
| `@katari-lang/api-server` | library |
| `@katari-lang/port` | library |
| `@katari-lang/bundle` | library |

## One-time setup

### 1. Create the npm scope

```sh
npm login
npm org create katari-lang
```

Or via web UI at <https://www.npmjs.com/org/create>.

### 2. Bootstrap publish each package (one-time)

npm's Trusted Publisher settings page only exists for **already-published
packages**, so each name must be bootstrapped once with a classic
token. After that, the token can be deleted and OIDC takes over for
all subsequent releases.

```sh
# Generate an Automation token on npmjs.com, scoped to @katari-lang/*.
# Build platform binaries locally (or download from a pre-release):
stack build katari:katari --copy-bins --local-bin-path ./bin
mkdir -p .binaries
# Pack a "linux-x64" tarball — repeat (or skip) for the other platforms.
tar czf .binaries/katari-0.0.1-bootstrap-linux-x64.tar.gz -C bin katari

# Run the bootstrap. Use a version you'll never use for a real release.
NPM_TOKEN=<token> BOOTSTRAP_VERSION=0.0.1-bootstrap \
  bash scripts/bootstrap-publish.sh

# If you can only build for the current platform, skip the binary set:
NPM_TOKEN=<token> BOOTSTRAP_VERSION=0.0.1-bootstrap SKIP_CLI_BINARIES=1 \
  bash scripts/bootstrap-publish.sh
# (the @katari-lang/cli-<plat> packages will then bootstrap on the
# first real CI run instead.)
```

The script publishes everything with the `bootstrap` dist-tag — your
package's `latest` is still unset, so `npm i @katari-lang/cli` continues
to 404 until the first real release lands.

### 3. Configure Trusted Publishing for each package

For each of the 7 packages now on npm, open
<https://www.npmjs.com/settings/katari-lang/packages>, click into the
package, then **Settings → Trusted publisher**, and add:

| Field | Value |
|---|---|
| Provider | GitHub Actions |
| Organization | `katari-lang` |
| Repository | `katari` |
| Workflow filename | `release-npm.yml` |
| Environment | *(blank — no GitHub Environment is used)* |

Once all 7 are configured, **delete the Automation token** you used
for the bootstrap. No `NPM_TOKEN` GitHub secret is needed —
authentication is short-lived OIDC issued by Actions at publish time.
See the [npm announcement][npm-tp] for background.

[npm-tp]: https://github.blog/changelog/2025-10-01-npm-trusted-publishing-with-oidc-is-generally-available/

### 4. Confirm Docker registry access

The runtime image pushes to GHCR (`ghcr.io/katari-lang/katari-runtime`).
This works out of the box with the default `GITHUB_TOKEN` — no manual
setup required, provided the org has GHCR enabled and the workflow has
`packages: write` permission (already declared in
`release-katari-runtime.yml`).

## Cutting a release

1. Make sure `main` is green and you've decided on a version `vX.Y.Z`.
2. Tag and push:

   ```sh
   git tag v0.1.0
   git push --tags
   ```

3. CI runs four workflows automatically:
   - `release-katari` — builds 2 platform binaries (linux-x64 +
     darwin-arm64), attaches to the GitHub Release.
   - `release-katari-runtime` — builds multi-arch Docker image, pushes
     to GHCR.
   - `release-vsix` — builds `katari-vscode-X.Y.Z.vsix`, attaches to
     the Release.
   - `release-npm` — chained off `release-katari` completion; downloads
     the binaries, stages `@katari-lang/cli-<platform>` packages, then
     publishes all 7 npm packages via OIDC. Provenance attestations are
     automatic.

The 4 workflows run in parallel except `release-npm`, which waits for
`release-katari` to finish so the binary tarballs are available on the
Release.

## Manual re-publish

If a publish step fails partway through, fix the underlying cause and
re-trigger `release-npm` via the **workflow_dispatch** form on the
Actions tab, passing the same tag (`v0.1.0`). Publishing an
already-published exact `name@version` is rejected by npm — bump the
patch version and re-tag for a true re-release.

## Toolchain constraints

- **Node.js 24+** is required in CI. Earlier versions ship npm CLI
  below 11.5.1 and the Trusted Publishing handshake fails with a
  cryptic E404 (`'<pkg>@<ver>' is not in this registry`).
- **pnpm 11+** is required (we pin 11.1.3 via `packageManager`).
  Earlier pnpm doesn't speak OIDC, and pnpm 10 had unrelated workspace
  detection issues that are fixed in 11.
- `pnpm publish --no-git-checks` is used in CI. Without `--no-git-checks`
  pnpm refuses because the Actions checkout lands on a detached HEAD
  rather than `main`.
- `setup-node`'s `registry-url` is set even under OIDC. The auth-token
  line in `.npmrc` is empty (no `NODE_AUTH_TOKEN`) and npm falls
  through to OIDC automatically.
- `workspace:*` cross-deps are left as-is in the committed manifests;
  `pnpm publish` rewrites them to the registry-published version on
  the fly.
