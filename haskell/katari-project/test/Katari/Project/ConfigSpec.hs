module Katari.Project.ConfigSpec (spec) where

import qualified Data.Map.Strict as Map
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

    it "parses [package] in the new form" $ do
      let raw =
            Text.unlines
              [ "[package]",
                "name = \"my-app\"",
                "version = \"0.1.0\""
              ]
      case parseKatariToml "katari.toml" raw of
        Left e -> expectationFailure (show e)
        Right cfg -> do
          cfg.projectName `shouldBe` "my-app"
          cfg.packageSection.packageName `shouldBe` "my-app"
          cfg.packageSection.packageVersion `shouldBe` Just "0.1.0"
          cfg.dependencies `shouldBe` Map.empty

    it "collects every [dependencies.<name>] section as a PathDependency" $ do
      let raw =
            Text.unlines
              [ "[package]",
                "name = \"my-app\"",
                "",
                "[dependencies.list-utils]",
                "path = \"../list-utils\"",
                "",
                "[dependencies.string-utils]",
                "path = \"vendor/string-utils\""
              ]
      case parseKatariToml "katari.toml" raw of
        Left e -> expectationFailure (show e)
        Right cfg -> do
          Map.keys cfg.dependencies
            `shouldMatchList` ["list-utils", "string-utils"]
          fmap (.depPath) (Map.lookup "list-utils" cfg.dependencies)
            `shouldBe` Just "../list-utils"
          fmap (.depPath) (Map.lookup "string-utils" cfg.dependencies)
            `shouldBe` Just "vendor/string-utils"

    it "rejects a dependency that is missing a 'path' key" $ do
      let raw =
            Text.unlines
              [ "[package]",
                "name = \"x\"",
                "[dependencies.bogus]",
                "version = \"1.0\""
              ]
      parseKatariToml "katari.toml" raw `shouldSatisfy` isValidationError

  where
    isValidationError = \case
      Left (ConfigValidationError _ _) -> True
      _ -> False
