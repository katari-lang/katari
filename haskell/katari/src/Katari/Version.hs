-- | The single source of truth for "the katari version" — the string
-- that names this build of the @katari@ CLI binary.
--
-- The constant below is rewritten in place by the release pipeline
-- (see @scripts\/stamp-version.mjs@) immediately before @stack build@,
-- so a binary built from git tag @vX.Y.Z[-pre]@ carries
-- @"X.Y.Z[-pre]"@. In a developer checkout the value stays at the
-- committed @"0.0.0-dev"@ literal.
--
-- All version-bearing surfaces in the CLI route through here so that
-- @katari --version@, the image tag pinned by @katari init@, log
-- headers, and bug reports all name the same string. The cabal
-- @version:@ field is a placeholder that GHC requires for the package
-- to exist; it is NOT the version users see.
module Katari.Version (katariVersion) where

-- | The katari CLI version string.
--
-- Lines flagged with @-- KATARI_VERSION@ are matched verbatim by the
-- release pipeline's stamper / verifier. Do not reformat without
-- updating @scripts\/stamp-version.mjs@ and @scripts\/verify-versions.mjs@.
katariVersion :: String
katariVersion = "0.0.0-dev" -- KATARI_VERSION
