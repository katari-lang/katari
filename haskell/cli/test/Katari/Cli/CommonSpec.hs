module Katari.Cli.CommonSpec (spec) where

import Katari.Cli.Common (PrefixError (..), resolveIdPrefix, resolveNodeHelperInvocation)
import System.Directory (canonicalizePath, createDirectoryIfMissing, createFileLink)
import System.Environment (setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = do
  describe "resolveIdPrefix" $ do
    let identifiers = ["aaa-111", "aab-222", "bbb-333"]

    it "resolves a unique prefix to the full id" $
      resolveIdPrefix "bb" identifiers `shouldBe` Right "bbb-333"

    it "an exact match wins even when it prefixes another id" $
      resolveIdPrefix "aaa-111" ("aaa-111-extended" : identifiers) `shouldBe` Right "aaa-111"

    it "reports ambiguity with every candidate" $
      resolveIdPrefix "aa" identifiers `shouldBe` Left (PrefixAmbiguous ["aaa-111", "aab-222"])

    it "reports a prefix nothing starts with" $
      resolveIdPrefix "zz" identifiers `shouldBe` Left PrefixNotFound

  -- The helper-spawn resolution `katari apply` (katari-bundle) and `katari mcp login` (katari-mcp)
  -- share. The helper name below is chosen to never exist on a real PATH, so the fallthrough cases
  -- end deterministically at Nothing.
  describe "resolveNodeHelperInvocation" $ do
    let environmentVariable = "KATARI_TEST_HELPER_BIN"
        helperName = "katari-test-helper-not-on-path"
        withoutOverride action = unsetEnv environmentVariable >> action

    it "honours the env override, running a JS entry through node" $
      withSystemTempDirectory "katari-helper" $ \directory -> do
        let entry = directory </> "cli.mjs"
        writeFile entry ""
        setEnv environmentVariable entry
        invocation <- resolveNodeHelperInvocation environmentVariable helperName directory
        unsetEnv environmentVariable
        invocation `shouldBe` Just ("node", [entry])

    it "a stale env override (missing file) falls through instead of spawning a dead path" $
      withSystemTempDirectory "katari-helper" $ \directory -> do
        setEnv environmentVariable (directory </> "gone.mjs")
        invocation <- resolveNodeHelperInvocation environmentVariable helperName directory
        unsetEnv environmentVariable
        invocation `shouldBe` Nothing

    it "finds a local node_modules/.bin entry, walking up from a nested start directory" $
      withoutOverride . withSystemTempDirectory "katari-helper" $ \directory -> do
        let binDirectory = directory </> "node_modules" </> ".bin"
            launcher = binDirectory </> helperName
            nested = directory </> "packages" </> "app"
        createDirectoryIfMissing True binDirectory
        createDirectoryIfMissing True nested
        -- A pnpm-style POSIX launcher script (no JS suffix): spawned directly, never through node.
        writeFile launcher "#!/bin/sh\n"
        invocation <- resolveNodeHelperInvocation environmentVariable helperName nested
        invocation `shouldBe` Just (launcher, [])

    it "an npm-style .bin symlink to a JS entry runs through node (canonicalized)" $
      withoutOverride . withSystemTempDirectory "katari-helper" $ \directory -> do
        let binDirectory = directory </> "node_modules" </> ".bin"
            entry = directory </> "node_modules" </> "pkg" </> "cli.mjs"
        createDirectoryIfMissing True binDirectory
        createDirectoryIfMissing True (directory </> "node_modules" </> "pkg")
        writeFile entry ""
        createFileLink entry (binDirectory </> helperName)
        invocation <- resolveNodeHelperInvocation environmentVariable helperName directory
        -- Canonicalize the expectation too: the temp root itself may sit behind a symlink.
        resolvedEntry <- canonicalizePath entry
        invocation `shouldBe` Just ("node", [resolvedEntry])

    it "resolves to Nothing when no override, no local install and nothing on PATH" $
      withoutOverride . withSystemTempDirectory "katari-helper" $ \directory -> do
        invocation <- resolveNodeHelperInvocation environmentVariable helperName directory
        invocation `shouldBe` Nothing
