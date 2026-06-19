module Katari.Project.SnapshotSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Katari.Project.Snapshot (Snapshot (..), SnapshotPackage (..), parseSnapshot)
import Test.Hspec

sampleSnapshot :: Text
sampleSnapshot =
  Text.unlines
    [ "compiler = \"0.1.0\"",
      "",
      "[packages.list_utils]",
      "url = \"https://github.com/katari-lang/list_utils\"",
      "rev = \"v0.2.1\"",
      "sha256 = \"abc123\""
    ]

spec :: Spec
spec =
  describe "parseSnapshot" $ do
    it "parses packages and renames sha256 to the shared sha vocabulary" $
      case parseSnapshot "snapshot.toml" sampleSnapshot of
        Left projectError -> expectationFailure ("expected success, got " <> show projectError)
        Right snapshot -> do
          snapshot.compilerVersion `shouldBe` Just "0.1.0"
          Map.lookup "list_utils" snapshot.packages
            `shouldBe` Just
              SnapshotPackage
                { url = "https://github.com/katari-lang/list_utils",
                  rev = "v0.2.1",
                  sha = "abc123"
                }

    it "treats a missing compiler field and empty package set as valid" $
      case parseSnapshot "snapshot.toml" "" of
        Left projectError -> expectationFailure ("expected success, got " <> show projectError)
        Right snapshot -> do
          snapshot.compilerVersion `shouldBe` Nothing
          snapshot.packages `shouldBe` Map.empty
