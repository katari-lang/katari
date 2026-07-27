module Katari.Project.ReconcileSpec (spec) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.List (List)
import Katari.Project.Config
  ( DependenciesSection (..),
    GitOverride (..),
    OverrideSource (..),
    PackageSection (..),
    PathOverride (..),
    ProjectConfig (..),
    RuntimeSection (..),
  )
import Katari.Project.Error (DependencyInfo (..), LockMismatch (..), SnapshotPinInfo (..), SourceChangeInfo (..))
import Katari.Project.Lockfile (GitSource (..), LockedSource (..), Lockfile (..), PathLock (..))
import Katari.Project.Reconcile (closureMismatches, manifestMismatches)
import Test.Hspec

sampleSha :: Text
sampleSha = Text.replicate 64 "a"

configWith :: Maybe Text -> List Text -> Map Text OverrideSource -> ProjectConfig
configWith snapshot packages overrides =
  ProjectConfig
    { package = PackageSection {name = "app", version = Nothing, description = Nothing, src = "src"},
      sidecar = Nothing,
      runtime = RuntimeSection {url = "http://localhost"},
      dependencies = DependenciesSection {registry = Just "https://registry.example", snapshot = snapshot, packages = packages},
      overrides = overrides
    }

lockWith :: Maybe Text -> List (Text, LockedSource) -> Lockfile
lockWith snapshot packages =
  Lockfile {version = 1, snapshot = snapshot, katariCompiler = Nothing, packages = Map.fromList packages}

gitSource :: Text -> Text -> LockedSource
gitSource url rev = LockedGit GitSource {url = url, rev = rev, sha = sampleSha}

fromRegistry :: LockedSource
fromRegistry = gitSource "https://github.com/katari-lang/lib" "deadbeef"

spec :: Spec
spec = do
  describe "manifestMismatches" $ do
    it "accepts a lock whose pin and sources are what the manifest asks for" $
      manifestMismatches
        (configWith (Just "snapshot-2026-07-26-a7cc1e51") ["lib"] Map.empty)
        (lockWith (Just "snapshot-2026-07-26-a7cc1e51") [("lib", fromRegistry)])
        `shouldBe` []

    it "reports a moved snapshot pin" $
      manifestMismatches
        (configWith (Just "snapshot-b") ["lib"] Map.empty)
        (lockWith (Just "snapshot-a") [("lib", fromRegistry)])
        `shouldBe` [SnapshotPinChanged SnapshotPinInfo {locked = Just "snapshot-a", declared = Just "snapshot-b"}]

    it "reports a pin that appeared where the lock recorded none" $
      manifestMismatches
        (configWith (Just "snapshot-a") ["lib"] Map.empty)
        (lockWith Nothing [("lib", fromRegistry)])
        `shouldBe` [SnapshotPinChanged SnapshotPinInfo {locked = Nothing, declared = Just "snapshot-a"}]

    it "reports an override that was added over a registry-resolved package" $
      manifestMismatches
        (configWith (Just "snapshot-a") ["lib"] (Map.singleton "lib" (OverridePath PathOverride {path = "../fork"})))
        (lockWith (Just "snapshot-a") [("lib", fromRegistry)])
        `shouldBe` [ DependencySourceChanged
                       SourceChangeInfo
                         { dependency = "lib",
                           locked = "git https://github.com/katari-lang/lib @ deadbeef",
                           declared = "path ../fork"
                         }
                   ]

    -- The registry only ever hands out git sources, so a path entry proves an override once existed.
    -- Deleting it silently would otherwise keep compiling the local fork forever.
    it "reports a path override that was deleted" $
      manifestMismatches
        (configWith (Just "snapshot-a") ["lib"] Map.empty)
        (lockWith (Just "snapshot-a") [("lib", LockedPath PathLock {location = "../fork"})])
        `shouldBe` [ DependencySourceChanged
                       SourceChangeInfo {dependency = "lib", locked = "path ../fork", declared = "the registry snapshot"}
                   ]

    it "reports a git override whose revision moved" $
      manifestMismatches
        ( configWith
            (Just "snapshot-a")
            ["lib"]
            (Map.singleton "lib" (OverrideGit GitOverride {url = "https://github.com/x/y", rev = "cafe"}))
        )
        (lockWith (Just "snapshot-a") [("lib", gitSource "https://github.com/x/y" "beef")])
        `shouldSatisfy` \mismatches -> length mismatches == 1

    it "accepts a git override the lock recorded at the same url and revision" $
      manifestMismatches
        ( configWith
            (Just "snapshot-a")
            ["lib"]
            (Map.singleton "lib" (OverrideGit GitOverride {url = "https://github.com/x/y", rev = "cafe"}))
        )
        (lockWith (Just "snapshot-a") [("lib", gitSource "https://github.com/x/y" "cafe")])
        `shouldBe` []

    -- A project that declares nothing and locks nothing has no closure to disagree about: the pin
    -- resolved no packages, so it cannot have changed what compiles. This is what lets a freshly
    -- scaffolded project — pinned but with no dependencies yet — be checked before it is locked.
    it "has nothing to reconcile when no dependency is declared or locked" $
      manifestMismatches (configWith (Just "staging") [] Map.empty) (lockWith Nothing []) `shouldBe` []

  describe "closureMismatches" $ do
    it "accepts a lock that is exactly the reachable closure" $
      closureMismatches ["a"] (Map.fromList [("a", ["b"]), ("b", [])]) `shouldBe` []

    it "reports a transitive dependency the lock leaves out" $
      closureMismatches ["a"] (Map.fromList [("a", ["b"])])
        `shouldBe` [DependencyMissingFromLock DependencyInfo {dependency = "b"}]

    -- Removing a dependency from katari.toml leaves its resolution — and its own subtree — behind in
    -- the lock. Nothing else notices, because an unreferenced package still compiles fine.
    it "reports packages the lock keeps that nothing reaches any more" $
      closureMismatches ["a"] (Map.fromList [("a", []), ("gone", ["also_gone"]), ("also_gone", [])])
        `shouldBe` [ DependencyOrphanedInLock DependencyInfo {dependency = "also_gone"},
                     DependencyOrphanedInLock DependencyInfo {dependency = "gone"}
                   ]

    it "terminates on a dependency cycle inside the locked graph" $
      closureMismatches ["a"] (Map.fromList [("a", ["b"]), ("b", ["a"])]) `shouldBe` []

    it "has nothing to say about a project with no dependencies" $
      closureMismatches [] Map.empty `shouldBe` []
