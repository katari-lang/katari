module Katari.Project.SnapshotSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
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
        p.repo `shouldBe` "https://github.com/example/katari-list-utils"
        p.ref `shouldBe` "abc1234567890abcdef1234567890abcdef12345"
        p.sha
          `shouldBe` "0000000000000000000000000000000000000000000000000000000000000000"

  it "rejects a package missing 'sha256'" $ do
    let raw =
          Text.unlines
            [ "[packages.list_utils]",
              "repo = \"https://github.com/x/y\"",
              "ref  = \"abc1234567890abcdef1234567890abcdef12345\""
            ]
    parseSnapshot "x.toml" raw `shouldSatisfy` isLeftErr

  it "rejects a package missing 'repo'" $ do
    let raw =
          Text.unlines
            [ "[packages.list_utils]",
              "ref = \"abc1234567890abcdef1234567890abcdef12345\""
            ]
    parseSnapshot "x.toml" raw `shouldSatisfy` isLeftErr

  it "rejects a package missing 'ref'" $ do
    let raw =
          Text.unlines
            [ "[packages.list_utils]",
              "repo = \"https://github.com/x/y\""
            ]
    parseSnapshot "x.toml" raw `shouldSatisfy` isLeftErr
  where
    isLeftErr = \case
      Left _ -> True
      _ -> False
