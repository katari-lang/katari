module Katari.Cli.LsSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import GHC.List (List)
import Katari.Cli.Command.Ls (PackageRow (..), packageRows, packageStatusCell, packageVersionCell)
import Katari.Project.Config
  ( DependenciesSection (..),
    OverrideSource (..),
    PackageSection (..),
    PathOverride (..),
    ProjectConfig (..),
    RuntimeSection (..),
  )
import Katari.Project.Lockfile (GitSource (..))
import Katari.Project.Snapshot (Snapshot (..), SnapshotEntry (..))
import Test.Hspec

-- | A registry cut holding three packages; @web@ is the one nothing in the fixture project uses.
snapshot :: Snapshot
snapshot =
  Snapshot
    { compilerVersion = Just "0.1.0",
      packages =
        Map.fromList
          [ ("ai", entry (Just "0.4.0")),
            ("google_common", entry (Just "0.2.0")),
            ("web", entry Nothing)
          ]
    }
  where
    entry version =
      SnapshotEntry
        { version = version,
          source = GitSource {url = "https://example.invalid/pkg", rev = "v1", sha = "abc"}
        }

-- | A project that declares @ai@, holds @google_common@ only as somebody else's dependency, and pins
-- a local checkout of @fleet@ that the snapshot has never heard of.
configWith :: List Text -> Map.Map Text OverrideSource -> ProjectConfig
configWith declared overrides =
  ProjectConfig
    { package = PackageSection {name = "demo", version = Nothing, description = Nothing, src = "src"},
      sidecar = Nothing,
      runtime = RuntimeSection {url = "http://localhost:3000"},
      dependencies =
        DependenciesSection
          { registry = Just "https://example.invalid/registry",
            snapshot = Just "snapshot-2026-07-30-b49b81c9",
            packages = declared
          },
      overrides = overrides
    }

localOverride :: OverrideSource
localOverride = OverridePath PathOverride {path = "../fleet"}

rowNamed :: Text -> List PackageRow -> Maybe PackageRow
rowNamed name rows = case filter (\row -> row.name == name) rows of
  (found : _) -> Just found
  [] -> Nothing

spec :: Spec
spec = do
  describe "packageRows" $ do
    let rows = packageRows (configWith ["ai"] (Map.singleton "fleet" localOverride)) snapshot (Set.fromList ["ai", "google_common"])

    it "lists the snapshot's packages in name order" $
      map (.name) rows `shouldBe` ["ai", "fleet", "google_common", "web"]

    it "marks a declared dependency" $
      fmap (.declared) (rowNamed "ai" rows) `shouldBe` Just True

    -- The reason the lock is read at all: it is what tells "not yours" apart from "already downloaded
    -- as somebody else's dependency", which is the difference between adding a package and adopting one.
    it "marks a package the lock holds without the manifest declaring it" $ do
      fmap (.declared) (rowNamed "google_common" rows) `shouldBe` Just False
      fmap (.inClosure) (rowNamed "google_common" rows) `shouldBe` Just True

    it "leaves a package the project has never touched unmarked" $ do
      fmap (.declared) (rowNamed "web" rows) `shouldBe` Just False
      fmap (.inClosure) (rowNamed "web" rows) `shouldBe` Just False

    -- `katari add` accepts an override name, so a listing that claims to answer "what can I add" has
    -- to carry one even though the snapshot does not.
    it "includes an override the snapshot does not carry" $
      fmap (.overridden) (rowNamed "fleet" rows) `shouldBe` Just True

    it "carries the snapshot's version label" $
      fmap (.version) (rowNamed "ai" rows) `shouldBe` Just (Just "0.4.0")

    it "carries no version for an unlabelled snapshot entry" $
      fmap (.version) (rowNamed "web" rows) `shouldBe` Just Nothing

    -- Overrides are root-authoritative, so a name in BOTH resolves from the override; borrowing the
    -- snapshot's label here would print a version the project will never fetch.
    it "drops the snapshot's version when an override outranks it" $ do
      let overridden = packageRows (configWith ["ai"] (Map.singleton "ai" localOverride)) snapshot Set.empty
      fmap (.version) (rowNamed "ai" overridden) `shouldBe` Just Nothing
      fmap (.overridden) (rowNamed "ai" overridden) `shouldBe` Just True

  describe "packageVersionCell / packageStatusCell" $ do
    let row = PackageRow {name = "ai", version = Just "0.4.0", overridden = False, declared = False, inClosure = False}

    it "shows the version label" $
      packageVersionCell row `shouldBe` "0.4.0"

    it "says (override) instead of a version for an overridden package" $
      packageVersionCell row {overridden = True} `shouldBe` "(override)"

    it "leaves the version cell empty when there is no label" $
      packageVersionCell row {version = Nothing} `shouldBe` ""

    it "reads `added` for a declared package" $
      packageStatusCell row {declared = True} `shouldBe` "added"

    it "reads `in closure` for a locked but undeclared package" $
      packageStatusCell row {inClosure = True} `shouldBe` "in closure"

    it "prefers `added` when a package is both declared and locked" $
      packageStatusCell row {declared = True, inClosure = True} `shouldBe` "added"

    it "leaves the status cell empty for a package the project does not have" $
      packageStatusCell row `shouldBe` ""
