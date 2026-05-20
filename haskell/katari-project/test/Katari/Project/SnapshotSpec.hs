module Katari.Project.SnapshotSpec (spec) where

import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import Katari.Project.Snapshot
import Test.Hspec

spec :: Spec
spec = describe "parseSnapshot" $ do
  it "parses the registry's example snapshot" $ do
    let raw =
          Text.unlines
            [ "katari_compiler = \"0.1.0\"",
              "",
              "[packages.list_utils]",
              "repo   = \"https://github.com/example/katari-list-utils\"",
              "ref    = \"abc1234567890abcdef1234567890abcdef12345\"",
              "sha256 = \"0000000000000000000000000000000000000000000000000000000000000000\""
            ]
    case parseSnapshot "example.toml" raw of
      Left e -> expectationFailure (show e)
      Right snap -> do
        snap.snapshotCompilerVersion `shouldBe` Just "0.1.0"
        Map.keys snap.snapshotPackages `shouldBe` ["list_utils"]
        let p = snap.snapshotPackages Map.! "list_utils"
        p.spRepo `shouldBe` "https://github.com/example/katari-list-utils"
        p.spRef `shouldBe` "abc1234567890abcdef1234567890abcdef12345"
        p.spSha
          `shouldBe` Just "0000000000000000000000000000000000000000000000000000000000000000"

  it "allows sha256 to be absent" $ do
    let raw =
          Text.unlines
            [ "[packages.list_utils]",
              "repo = \"https://github.com/x/y\"",
              "ref  = \"abc1234567890abcdef1234567890abcdef12345\""
            ]
    case parseSnapshot "x.toml" raw of
      Left e -> expectationFailure (show e)
      Right snap ->
        (snap.snapshotPackages Map.! "list_utils").spSha
          `shouldBe` Nothing

  it "rejects a package missing 'repo'" $ do
    let raw =
          Text.unlines
            [ "[packages.list_utils]",
              "ref = \"abc1234567890abcdef1234567890abcdef12345\""
            ]
    parseSnapshot "x.toml" raw `shouldSatisfy` isValidationError

  it "rejects a package missing 'ref'" $ do
    let raw =
          Text.unlines
            [ "[packages.list_utils]",
              "repo = \"https://github.com/x/y\""
            ]
    parseSnapshot "x.toml" raw `shouldSatisfy` isValidationError
  where
    isValidationError = \case
      Left (SnapshotValidationError _ _) -> True
      _ -> False
