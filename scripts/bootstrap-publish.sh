#!/usr/bin/env bash
#
# One-time bootstrap publish for the 8 @katari-lang npm packages.
#
# npm Trusted Publishing requires the package to already exist on the
# registry before its trusted-publisher settings page is accessible.
# This script does that bootstrap: it publishes every package once
# using a short-lived classic token, after which Trusted Publisher
# config can be set up per package on npmjs.com and this script never
# needs to run again.
#
# Usage:
#   1. Create the @katari-lang npm org (web UI or `npm org create katari-lang`).
#   2. Generate an Automation token scoped to @katari-lang/* on npmjs.com.
#   3. Build platform tarballs you want to bootstrap (optional — see
#      SKIP_CLI_BINARIES below):
#        stack build katari:katari --copy-bins --local-bin-path ./bin
#        mkdir -p .binaries
#        tar czf .binaries/katari-${BOOTSTRAP_VERSION}-linux-x64.tar.gz \
#          -C bin katari
#        # repeat for darwin-arm64 if you have that build.
#   4. Run:
#        NPM_TOKEN=<token> BOOTSTRAP_VERSION=0.0.1-bootstrap \
#          bash scripts/bootstrap-publish.sh
#   5. On npmjs.com, configure Trusted Publisher for each of the 8
#      published packages (see docs/PUBLISHING.md).
#   6. Delete the token. Future releases run via OIDC on tag push.
#
# Phase-skip env vars (for partial retry):
#   SKIP_LIBS=1          — skip @katari-lang/{runtime,port,bundle,api-server}
#   SKIP_CLI_BINARIES=1  — skip @katari-lang/cli-<platform>
#   SKIP_SHIM=1          — skip @katari-lang/cli
#
# The script always restores the committed package.json files on exit
# (success or failure), so the working tree is never left polluted.
#
# Tip: pick a version you'll never use for a real release (eg.
# 0.0.1-bootstrap). npm refuses re-publish of the same name@version,
# so a botched bootstrap means changing BOOTSTRAP_VERSION to retry.

set -euo pipefail

: "${NPM_TOKEN:?set NPM_TOKEN to a classic Automation token}"
: "${BOOTSTRAP_VERSION:?set BOOTSTRAP_VERSION (eg. 0.0.1-bootstrap)}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v pnpm > /dev/null; then
  echo "::error::pnpm not found on PATH" >&2
  exit 1
fi

NPMRC="$(mktemp)"
cleanup() {
  echo "==> restoring committed package.json files"
  # Use `git checkout` for tracked files. The shim's package.json may
  # be untracked the first time around; fall back to a targeted edit
  # then.
  for pkg in katari-runtime katari-port katari-bundle katari-api-server katari; do
    f="typescript/packages/${pkg}/package.json"
    if git ls-files --error-unmatch "$f" > /dev/null 2>&1; then
      git checkout --quiet -- "$f"
    else
      # untracked: just strip the bumped version + optionalDeps in place
      node -e "
        const fs = require('fs');
        const path = '$f';
        const pkg = JSON.parse(fs.readFileSync(path, 'utf8'));
        pkg.version = '0.1.0';
        delete pkg.optionalDependencies;
        fs.writeFileSync(path, JSON.stringify(pkg, null, 2) + '\n');
      " || true
    fi
  done
  rm -f "$NPMRC"
}
trap cleanup EXIT

cat > "$NPMRC" <<EOF
//registry.npmjs.org/:_authToken=${NPM_TOKEN}
EOF
export npm_config_userconfig="$NPMRC"

echo "==> verifying token"
pnpm whoami

echo "==> building TS packages"
pnpm install --frozen-lockfile
pnpm -r --filter "./typescript/packages/*" run build

echo "==> bumping versions to ${BOOTSTRAP_VERSION} (workspace:* left intact)"
node scripts/bump-versions.mjs --version "${BOOTSTRAP_VERSION}"

if [[ "${SKIP_LIBS:-0}" != "1" ]]; then
  echo "==> publishing library packages"
  for pkg in katari-runtime katari-port katari-bundle katari-api-server; do
    echo "--- $pkg ---"
    ( cd "typescript/packages/$pkg" \
      && pnpm publish --access public --no-git-checks --tag bootstrap )
  done
else
  echo "==> SKIP_LIBS=1 — skipping library packages"
fi

if [[ "${SKIP_CLI_BINARIES:-0}" != "1" ]]; then
  echo "==> staging @katari-lang/cli-<platform> packages"
  node scripts/stage-binary-packages.mjs --version "${BOOTSTRAP_VERSION}"

  echo "==> publishing @katari-lang/cli-<platform> packages"
  for plat in linux-x64 darwin-arm64; do
    echo "--- @katari-lang/cli-${plat} ---"
    ( cd ".staged/${plat}" \
      && npm publish --access public --tag bootstrap )
  done
else
  echo "==> SKIP_CLI_BINARIES=1 — skipping @katari-lang/cli-<platform>"
fi

if [[ "${SKIP_SHIM:-0}" != "1" ]]; then
  echo "==> publishing @katari-lang/cli shim"
  ( cd typescript/packages/katari \
    && pnpm publish --access public --no-git-checks --tag bootstrap )
else
  echo "==> SKIP_SHIM=1 — skipping @katari-lang/cli"
fi

echo
echo "✅ bootstrap publish complete."
echo
echo "Next steps:"
echo "  1. Visit https://www.npmjs.com/settings/katari-lang/packages"
echo "  2. For each published package, open Settings → Trusted Publisher"
echo "     and add: GitHub Actions / katari-lang / katari / release-npm.yml"
echo "  3. Delete the Automation token you used for this bootstrap."
echo "  4. Subsequent releases: tag and push (see docs/PUBLISHING.md)."
echo
echo "Bootstrap packages are tagged 'bootstrap' (not 'latest'), so end users"
echo "won't pick them up until your first real release."
