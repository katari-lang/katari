#!/bin/sh
set -e

hs_files=$(git diff --cached --name-only --diff-filter=d -- 'haskell/**/*.hs')
ts_files=$(git diff --cached --name-only --diff-filter=d -- 'typescript/**/*.ts' 'typescript/**/*.tsx' 'e2e/**/*.ts' 'scripts/**/*.mjs')

if [ -n "$hs_files" ]; then
  ormolu -i $hs_files
fi

if [ -n "$ts_files" ]; then
  pnpm biome check --no-errors-on-unmatched $ts_files
fi
