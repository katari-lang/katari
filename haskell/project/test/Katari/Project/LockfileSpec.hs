module Katari.Project.LockfileSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Katari.Project.Error (ProjectError (..))
import Katari.Project.Lockfile
  ( GitSource (..),
    LockedSource (..),
    Lockfile (..),
    PathLock (..),
    parseLockfile,
    renderLockfile,
  )
import Test.Hspec

isLockfileValidationError :: ProjectError -> Bool
isLockfileValidationError projectError = case projectError of
  LockfileValidationError _ -> True
  _ -> False

-- | Distinct well-formed (64 hex char) content hashes; the parser now rejects malformed ones.
shaListUtils, shaBleedingEdge :: Text
shaListUtils = Text.replicate 64 "a"
shaBleedingEdge = Text.replicate 64 "b"

-- | A lockfile covering both source variants, so the round-trip exercises every render/parse branch.
sampleLockfile :: Lockfile
sampleLockfile =
  Lockfile
    { version = 1,
      snapshot = Just "v0.1.0",
      packages =
        Map.fromList
          [ ("list_utils", LockedGit GitSource {url = "https://github.com/katari-lang/list_utils", rev = "v0.2.1", sha = shaListUtils}),
            ("local_fork", LockedPath PathLock {location = "../local_fork"}),
            ("bleeding_edge", LockedGit GitSource {url = "https://github.com/foo/bar", rev = "deadbeef", sha = shaBleedingEdge})
          ]
    }

spec :: Spec
spec = do
  describe "renderLockfile / parseLockfile" $ do
    it "round-trips a lockfile through render and parse" $
      parseLockfile "katari.lock" (renderLockfile sampleLockfile) `shouldBe` Right sampleLockfile

    it "renders an empty path-only project deterministically (no [packages] when none)" $ do
      let lockfile = Lockfile {version = 1, snapshot = Nothing, packages = Map.empty}
      parseLockfile "katari.lock" (renderLockfile lockfile) `shouldBe` Right lockfile

    it "emits package tables in ascending key order (deterministic, reproducible bytes)" $ do
      let headers = filter ("[packages." `Text.isPrefixOf`) (Text.lines (renderLockfile sampleLockfile))
      headers
        `shouldBe` ["[packages.bleeding_edge]", "[packages.list_utils]", "[packages.local_fork]"]

    it "rejects a git pin whose sha256 is not 64 hex characters" $ do
      let malformed =
            Text.unlines
              [ "[lock]",
                "version = 1",
                "",
                "[packages.dep]",
                "source = \"git\"",
                "url = \"https://github.com/a/b\"",
                "rev = \"deadbeef\"",
                "sha256 = \"abc123\""
              ]
      parseLockfile "katari.lock" malformed `shouldSatisfy` either isLockfileValidationError (const False)

    it "rejects an unsupported lockfile format version" $
      parseLockfile "katari.lock" "[lock]\nversion = 999\n"
        `shouldSatisfy` either isLockfileValidationError (const False)
