#!/bin/sh
set -e

ts_files=$(git diff --cached --name-only --diff-filter=d -- 'typescript/**/*.ts' 'typescript/**/*.tsx' 'e2e/**/*.ts' 'scripts/**/*.mjs')

if [ -n "$ts_files" ]; then
  pnpm biome check --no-errors-on-unmatched $ts_files
fi
