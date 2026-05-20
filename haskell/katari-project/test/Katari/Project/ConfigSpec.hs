module Katari.Project.ConfigSpec (spec) where

import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import Katari.Project.Config
import Test.Hspec

spec :: Spec
spec = do
  describe "parseKatariToml" $ do
    it "parses a minimal [package] + [runtime] config" $ do
      let raw =
            Text.unlines
              [ "[package]",
                "name = \"hello\"",
                "",
                "[runtime]",
                "url = \"http://localhost:8000\""
              ]
      case parseKatariToml "katari.toml" raw of
        Left e -> expectationFailure (show e)
        Right cfg -> do
          cfg.projectName `shouldBe` "hello"
          cfg.packageSection.packageName `shouldBe` "hello"
          cfg.packageSection.packageSrc `shouldBe` "src"
          cfg.runtimeSection.runtimeUrl `shouldBe` "http://localhost:8000"

    it "defaults [package].src to \"src\" when omitted" $ do
      let raw = Text.unlines ["[package]", "name = \"x\""]
      case parseKatariToml "katari.toml" raw of
        Left e -> expectationFailure (show e)
        Right cfg -> cfg.packageSection.packageSrc `shouldBe` "src"

    it "reads [package].src override" $ do
      let raw =
            Text.unlines
              [ "[package]",
                "name = \"x\"",
                "src = \"lib\""
              ]
      case parseKatariToml "katari.toml" raw of
        Left e -> expectationFailure (show e)
        Right cfg -> cfg.packageSection.packageSrc `shouldBe` "lib"

    it "defaults [runtime].url when omitted" $ do
      let raw = Text.unlines ["[package]", "name = \"x\""]
      case parseKatariToml "katari.toml" raw of
        Left e -> expectationFailure (show e)
        Right cfg -> cfg.runtimeSection.runtimeUrl `shouldBe` "http://localhost:8000"

    it "parses [sidecar].sourceRoots array" $ do
      let raw =
            Text.unlines
              [ "[package]",
                "name = \"x\"",
                "[sidecar]",
                "sourceRoots = [\"a\", \"b\"]"
              ]
      case parseKatariToml "katari.toml" raw of
        Left e -> expectationFailure (show e)
        Right cfg ->
          fmap (.sidecarSourceRoots) cfg.sidecarSection `shouldBe` Just ["a", "b"]

    it "rejects missing [package].name" $ do
      parseKatariToml "katari.toml" "# nothing here\n"
        `shouldSatisfy` isValidationError

    it "ignores comments and blank lines" $ do
      let raw =
            Text.unlines
              [ "# leading comment",
                "[package]",
                "name = \"x\"  # trailing comment",
                "",
                "[runtime]",
                "url = \"http://example.com\""
              ]
      case parseKatariToml "katari.toml" raw of
        Left e -> expectationFailure (show e)
        Right cfg -> do
          cfg.projectName `shouldBe` "x"
          cfg.runtimeSection.runtimeUrl `shouldBe` "http://example.com"

    it "parses snapshot pin (= \"*\") in [dependencies]" $ do
      let raw =
            Text.unlines
              [ "[package]",
                "name = \"my_app\"",
                "[snapshot]",
                "version = \"2026-05-01\"",
                "url = \"https://example.com/registry\"",
                "[dependencies]",
                "list_utils = \"*\""
              ]
      case parseKatariToml "katari.toml" raw of
        Left e -> expectationFailure (show e)
        Right cfg -> do
          cfg.snapshotVersion `shouldBe` Just "2026-05-01"
          cfg.snapshotUrl `shouldBe` Just "https://example.com/registry"
          Map.lookup "list_utils" cfg.dependencies `shouldBe` Just DepSnapshot

    it "parses an inline-table path dep" $ do
      let raw =
            Text.unlines
              [ "[package]",
                "name = \"my_app\"",
                "[dependencies]",
                "local_fork = { path = \"../local_fork\" }"
              ]
      case parseKatariToml "katari.toml" raw of
        Left e -> expectationFailure (show e)
        Right cfg ->
          Map.lookup "local_fork" cfg.dependencies
            `shouldBe` Just (DepPath "../local_fork")

    it "parses an inline-table git dep" $ do
      let raw =
            Text.unlines
              [ "[package]",
                "name = \"my_app\"",
                "[dependencies]",
                "bleeding_edge = { git = \"https://example.com/repo\", ref = \"abc1234\" }"
              ]
      case parseKatariToml "katari.toml" raw of
        Left e -> expectationFailure (show e)
        Right cfg ->
          Map.lookup "bleeding_edge" cfg.dependencies
            `shouldBe` Just
              DepGit
                { gitUrl = "https://example.com/repo",
                  gitRev = "abc1234"
                }

    it "rejects an inline-table dep that names neither path nor git" $ do
      let raw =
            Text.unlines
              [ "[package]",
                "name = \"x\"",
                "[dependencies]",
                "bogus = { version = \"1.0\" }"
              ]
      parseKatariToml "katari.toml" raw `shouldSatisfy` isValidationError

    it "rejects a string-valued dep that isn't \"*\"" $ do
      let raw =
            Text.unlines
              [ "[package]",
                "name = \"x\"",
                "[dependencies]",
                "weird = \"1.2.3\""
              ]
      parseKatariToml "katari.toml" raw `shouldSatisfy` isValidationError
  where
    isValidationError = \case
      Left (ConfigValidationError _ _) -> True
      _ -> False
