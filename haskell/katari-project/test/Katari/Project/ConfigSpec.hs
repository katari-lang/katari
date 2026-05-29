module Katari.Project.ConfigSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
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

    it "parses [package].description when present" $ do
      let raw =
            Text.unlines
              [ "[package]",
                "name = \"x\"",
                "description = \"hello world\""
              ]
      case parseKatariToml "katari.toml" raw of
        Left e -> expectationFailure (show e)
        Right cfg ->
          cfg.packageSection.packageDescription `shouldBe` Just "hello world"

    it "defaults [package].description to Nothing when omitted" $ do
      let raw = Text.unlines ["[package]", "name = \"x\""]
      case parseKatariToml "katari.toml" raw of
        Left e -> expectationFailure (show e)
        Right cfg -> cfg.packageSection.packageDescription `shouldBe` Nothing

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
        `shouldSatisfy` isError

    it "parses [dependencies] with registry + snapshot + packages" $ do
      let raw =
            Text.unlines
              [ "[package]",
                "name = \"my_app\"",
                "[dependencies]",
                "registry = \"https://github.com/katari-lang/katari-registry\"",
                "snapshot = \"v0.1.0\"",
                "packages = [\"list_utils\", \"http_client\"]"
              ]
      case parseKatariToml "katari.toml" raw of
        Left e -> expectationFailure (show e)
        Right cfg -> do
          cfg.dependenciesSection.dependenciesRegistry
            `shouldBe` Just "https://github.com/katari-lang/katari-registry"
          cfg.dependenciesSection.dependenciesSnapshot `shouldBe` Just "v0.1.0"
          cfg.dependenciesSection.dependenciesPackages
            `shouldMatchList` ["list_utils", "http_client"]
          cfg.overrides `shouldBe` Map.empty

    it "parses a path override" $ do
      let raw =
            Text.unlines
              [ "[package]",
                "name = \"my_app\"",
                "[dependencies]",
                "packages = [\"local_fork\"]",
                "[overrides.local_fork]",
                "path = \"../local_fork\""
              ]
      case parseKatariToml "katari.toml" raw of
        Left e -> expectationFailure (show e)
        Right cfg ->
          Map.lookup "local_fork" cfg.overrides
            `shouldBe` Just (OverridePath "../local_fork")

    it "parses a git override" $ do
      let raw =
            Text.unlines
              [ "[package]",
                "name = \"my_app\"",
                "[dependencies]",
                "packages = [\"upstream\"]",
                "[overrides.upstream]",
                "git = \"https://example.com/repo\"",
                "ref = \"abc1234\""
              ]
      case parseKatariToml "katari.toml" raw of
        Left e -> expectationFailure (show e)
        Right cfg ->
          Map.lookup "upstream" cfg.overrides
            `shouldBe` Just OverrideGit {gitUrl = "https://example.com/repo", gitRev = "abc1234"}

    it "rejects an override whose name is not in [dependencies].packages" $ do
      let raw =
            Text.unlines
              [ "[package]",
                "name = \"x\"",
                "[dependencies]",
                "packages = []",
                "[overrides.orphan]",
                "path = \"../orphan\""
              ]
      parseKatariToml "katari.toml" raw `shouldSatisfy` isError

    it "rejects an override that names neither path nor git" $ do
      let raw =
            Text.unlines
              [ "[package]",
                "name = \"x\"",
                "[dependencies]",
                "packages = [\"bogus\"]",
                "[overrides.bogus]"
              ]
      parseKatariToml "katari.toml" raw `shouldSatisfy` isError
  where
    isError :: Either ConfigError a -> Bool
    isError = \case
      Left _ -> True
      Right _ -> False
