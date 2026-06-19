module Katari.Project.LockfileSpec (spec) where

import Data.Map.Strict qualified as Map
import Katari.Project.Lockfile
  ( GitLock (..),
    LockedPackage (..),
    LockedSource (..),
    Lockfile (..),
    PathLock (..),
    SnapshotLock (..),
    parseLockfile,
    renderLockfile,
  )
import Test.Hspec

-- | A lockfile covering all three source variants, so the round-trip exercises every render/parse
-- branch.
sampleLockfile :: Lockfile
sampleLockfile =
  Lockfile
    { version = 1,
      snapshot = Just "v0.1.0",
      packages =
        Map.fromList
          [ ( "list_utils",
              LockedPackage
                { name = "list_utils",
                  source =
                    LockedSnapshot
                      SnapshotLock {url = "https://github.com/katari-lang/list_utils", rev = "v0.2.1", sha = "abc123"}
                }
            ),
            ( "local_fork",
              LockedPackage {name = "local_fork", source = LockedPath PathLock {location = "../local_fork"}}
            ),
            ( "bleeding_edge",
              LockedPackage
                { name = "bleeding_edge",
                  source = LockedGit GitLock {url = "https://github.com/foo/bar", rev = "deadbeef", sha = "def456"}
                }
            )
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

    it "is byte-stable: rendering is independent of insertion order" $ do
      let reordered =
            sampleLockfile
              { packages = Map.fromList (reverse (Map.toList sampleLockfile.packages))
              }
      renderLockfile reordered `shouldBe` renderLockfile sampleLockfile
