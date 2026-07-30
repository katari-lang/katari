module Katari.Cli.CommonSpec (spec) where

import Katari.Cli.Common (PrefixError (..), isBrowsableUrl, isLoopbackUrl, isPreludeName, resolveIdPrefix, resolveNodeHelperInvocation)
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

  describe "isPreludeName" $ do
    it "recognises a member of the prelude root module" $
      isPreludeName "prelude.concat" `shouldBe` True

    it "recognises a member of a prelude sub-module" $
      isPreludeName "prelude.store.get" `shouldBe` True

    it "leaves an application agent visible" $
      isPreludeName "main.main" `shouldBe` False

    it "does not mistake a look-alike module for the prelude" $
      -- The `.` guard `covers` applies: `prelude` covers its descendants, never a name-prefix sibling.
      isPreludeName "preludex.helper" `shouldBe` False

    it "treats a name with no module as an application name" $
      isPreludeName "prelude" `shouldBe` False

  -- The host test behind the plaintext-runtime warning and behind the gate on what may be handed to the
  -- desktop's URL opener. Both read the authority out of the URL themselves, so the parsing is what
  -- these cases pin down.
  describe "isLoopbackUrl" $ do
    it "recognises the local runtime in the spellings it is reached by" $ do
      isLoopbackUrl "http://localhost:8000" `shouldBe` True
      isLoopbackUrl "http://127.0.0.1:8000/api/v1" `shouldBe` True
      isLoopbackUrl "http://[::1]:8000" `shouldBe` True
      isLoopbackUrl "http://LOCALHOST:8000" `shouldBe` True

    it "does not mistake a remote host for the local one" $ do
      isLoopbackUrl "https://runtime.example.com" `shouldBe` False
      isLoopbackUrl "http://localhost.evil.example" `shouldBe` False
      -- A host may only appear in the authority; putting it in the path or the userinfo must not count.
      isLoopbackUrl "http://evil.example/localhost" `shouldBe` False
      isLoopbackUrl "http://evil.example?host=localhost" `shouldBe` False

  describe "isBrowsableUrl" $ do
    it "accepts the web URLs an authorization flow legitimately produces" $ do
      isBrowsableUrl "https://accounts.example.com/o/oauth2/auth?client_id=x" `shouldBe` True
      isBrowsableUrl "http://localhost:8000/oauth/authorize" `shouldBe` True

    -- The value comes off the wire, and the opener launches whatever the desktop registered for the
    -- scheme, so anything that is not ordinary web transport is refused and merely printed.
    it "refuses a scheme that would launch something other than a browser" $ do
      isBrowsableUrl "file:///home/dev/.ssh/id_ed25519" `shouldBe` False
      isBrowsableUrl "vscode://file/etc/passwd" `shouldBe` False
      isBrowsableUrl "javascript:alert(1)" `shouldBe` False

    it "refuses plaintext http to a remote host" $
      isBrowsableUrl "http://evil.example/authorize" `shouldBe` False

  -- The helper-spawn resolution `katari apply` (katari-bundle) and `katari mcp pull` (katari-mcp)
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
