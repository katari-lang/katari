module Katari.Project.ConfigSpec (spec) where

import qualified Data.Text as Text
import Katari.Project.Config
import Test.Hspec

spec :: Spec
spec = do
  describe "parseKatariToml" $ do
    it "parses the minimal sample shape" $ do
      let raw =
            Text.unlines
              [ "project = \"hello\"",
                "",
                "[compile]",
                "src = \"src/\"",
                "",
                "[api]",
                "url = \"http://localhost:8080\""
              ]
      case parseKatariToml "katari.toml" raw of
        Left e -> expectationFailure (show e)
        Right cfg -> do
          cfg.projectName `shouldBe` "hello"
          cfg.compileSection.compileSrc `shouldBe` "src/"
          cfg.compileSection.compileRoot `shouldBe` Nothing
          cfg.apiSection.apiUrl `shouldBe` "http://localhost:8080"

    it "defaults compile.src when omitted" $ do
      let raw = "project = \"x\""
      case parseKatariToml "katari.toml" raw of
        Left e -> expectationFailure (show e)
        Right cfg -> cfg.compileSection.compileSrc `shouldBe` "src/"

    it "reads [compile].root override" $ do
      let raw =
            Text.unlines
              [ "project = \"x\"",
                "[compile]",
                "root = \"entry\""
              ]
      case parseKatariToml "katari.toml" raw of
        Left e -> expectationFailure (show e)
        Right cfg -> cfg.compileSection.compileRoot `shouldBe` Just "entry"

    it "parses [sidecar].sourceRoots array" $ do
      let raw =
            Text.unlines
              [ "project = \"x\"",
                "[sidecar]",
                "sourceRoots = [\"a\", \"b\"]"
              ]
      case parseKatariToml "katari.toml" raw of
        Left e -> expectationFailure (show e)
        Right cfg ->
          fmap (.sidecarSourceRoots) cfg.sidecarSection `shouldBe` Just ["a", "b"]

    it "rejects missing 'project'" $ do
      parseKatariToml "katari.toml" "# nothing here\n"
        `shouldSatisfy` isValidationError

    it "ignores comments and blank lines" $ do
      let raw =
            Text.unlines
              [ "# leading comment",
                "project = \"x\"  # trailing comment",
                "",
                "[api]",
                "url = \"http://example.com\""
              ]
      case parseKatariToml "katari.toml" raw of
        Left e -> expectationFailure (show e)
        Right cfg -> do
          cfg.projectName `shouldBe` "x"
          cfg.apiSection.apiUrl `shouldBe` "http://example.com"

  where
    isValidationError = \case
      Left (ConfigValidationError _ _) -> True
      _ -> False
