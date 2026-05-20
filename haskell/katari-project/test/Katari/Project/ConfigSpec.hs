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
          cfg.snapshotSection.snapshotDependencies `shouldBe` []
          cfg.overrides `shouldBe` Map.empty

    it "parses [snapshot] + [overrides.X] as a Model-2 config" $ do
      let raw =
            Text.unlines
              [ "[package]",
                "name = \"my_app\"",
                "",
                "[snapshot]",
                "version = \"2026-05-01\"",
                "dependencies = [\"list_utils\", \"local_fork\"]",
                "",
                "[overrides.local_fork]",
                "path = \"../local_fork\""
              ]
      case parseKatariToml "katari.toml" raw of
        Left e -> expectationFailure (show e)
        Right cfg -> do
          cfg.snapshotSection.snapshotVersion `shouldBe` Just "2026-05-01"
          cfg.snapshotSection.snapshotDependencies
            `shouldMatchList` ["list_utils", "local_fork"]
          Map.keys cfg.overrides `shouldMatchList` ["local_fork"]
          Map.lookup "local_fork" cfg.overrides
            `shouldBe` Just (OverridePath "../local_fork")

    it "parses git overrides" $ do
      let raw =
            Text.unlines
              [ "[package]",
                "name = \"my_app\"",
                "[snapshot]",
                "dependencies = [\"bleeding_edge\"]",
                "[overrides.bleeding_edge]",
                "git = \"https://example.com/repo\"",
                "rev = \"abc1234\""
              ]
      case parseKatariToml "katari.toml" raw of
        Left e -> expectationFailure (show e)
        Right cfg ->
          Map.lookup "bleeding_edge" cfg.overrides
            `shouldBe` Just
              ( OverrideGit
                  { gitUrl = "https://example.com/repo",
                    gitRev = "abc1234"
                  }
              )

    it "rejects an override that names neither path nor git" $ do
      let raw =
            Text.unlines
              [ "[package]",
                "name = \"x\"",
                "[snapshot]",
                "dependencies = [\"bogus\"]",
                "[overrides.bogus]",
                "version = \"1.0\""
              ]
      parseKatariToml "katari.toml" raw `shouldSatisfy` isValidationError

    it "rejects an override whose name is not in [snapshot].dependencies" $ do
      let raw =
            Text.unlines
              [ "[package]",
                "name = \"x\"",
                "[overrides.orphan]",
                "path = \"../orphan\""
              ]
      parseKatariToml "katari.toml" raw `shouldSatisfy` isValidationError

  where
    isValidationError = \case
      Left (ConfigValidationError _ _) -> True
      _ -> False
