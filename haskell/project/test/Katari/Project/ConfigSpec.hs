module Katari.Project.ConfigSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Katari.Project.Config
  ( DependenciesSection (..),
    GitOverride (..),
    OverrideSource (..),
    PackageSection (..),
    PathOverride (..),
    ProjectConfig (..),
    RuntimeSection (..),
    isValidPackageName,
    parseKatariToml,
  )
import Katari.Project.Error (ProjectError (..))
import Test.Hspec

-- | A well-formed @katari.toml@ exercising the optional fields, a dependency list, and a path
-- override.
validToml :: Text
validToml =
  Text.unlines
    [ "[package]",
      "name = \"hello\"",
      "version = \"0.1.0\"",
      "",
      "[runtime]",
      "url = \"http://localhost:8000\"",
      "",
      "[dependencies]",
      "packages = [\"list_utils\", \"my_fork\"]",
      "",
      "[overrides.my_fork]",
      "path = \"../my_fork\""
    ]

isConfigValidationError :: ProjectError -> Bool
isConfigValidationError projectError = case projectError of
  ConfigValidationError _ -> True
  _ -> False

isConfigParseError :: ProjectError -> Bool
isConfigParseError projectError = case projectError of
  ConfigParseError _ -> True
  _ -> False

spec :: Spec
spec = do
  describe "parseKatariToml" $ do
    it "parses a well-formed config" $ case parseKatariToml "katari.toml" validToml of
      Left projectError -> expectationFailure ("expected success, got " <> show projectError)
      Right config -> do
        config.package.name `shouldBe` "hello"
        config.package.version `shouldBe` Just "0.1.0"
        -- 'src' defaults to "src" when omitted.
        config.package.src `shouldBe` "src"
        config.runtime.url `shouldBe` ("http://localhost:8000" :: Text)
        config.dependencies.packages `shouldBe` ["list_utils", "my_fork"]
        Map.lookup "my_fork" config.overrides `shouldBe` Just (OverridePath PathOverride {path = "../my_fork"})

    it "rejects an override that sets both path and git" $ do
      let toml =
            Text.unlines
              [ "[package]",
                "name = \"hello\"",
                "[runtime]",
                "url = \"http://x\"",
                "[dependencies]",
                "packages = [\"dep\"]",
                "[overrides.dep]",
                "path = \"../dep\"",
                "git = \"https://github.com/a/b\""
              ]
      parseKatariToml "katari.toml" toml `shouldSatisfy` either isConfigValidationError (const False)

    it "rejects a git override without a rev" $ do
      let toml =
            Text.unlines
              [ "[package]",
                "name = \"hello\"",
                "[runtime]",
                "url = \"http://x\"",
                "[dependencies]",
                "packages = [\"dep\"]",
                "[overrides.dep]",
                "git = \"https://github.com/a/b\""
              ]
      parseKatariToml "katari.toml" toml `shouldSatisfy` either isConfigValidationError (const False)

    it "accepts a git override pinned to a full commit SHA" $ do
      let commitSha = Text.replicate 40 "a"
          toml =
            Text.unlines
              [ "[package]",
                "name = \"hello\"",
                "[runtime]",
                "url = \"http://x\"",
                "[dependencies]",
                "packages = [\"dep\"]",
                "[overrides.dep]",
                "git = \"https://github.com/a/b\"",
                "rev = \"" <> commitSha <> "\""
              ]
      case parseKatariToml "katari.toml" toml of
        Left projectError -> expectationFailure ("expected success, got " <> show projectError)
        Right config ->
          Map.lookup "dep" config.overrides
            `shouldBe` Just (OverrideGit GitOverride {url = "https://github.com/a/b", rev = commitSha})

    it "rejects a git override whose rev is a mutable ref, not a commit SHA" $ do
      let toml =
            Text.unlines
              [ "[package]",
                "name = \"hello\"",
                "[runtime]",
                "url = \"http://x\"",
                "[dependencies]",
                "packages = [\"dep\"]",
                "[overrides.dep]",
                "git = \"https://github.com/a/b\"",
                "rev = \"v0.2.1\""
              ]
      parseKatariToml "katari.toml" toml `shouldSatisfy` either isConfigValidationError (const False)

    it "rejects a declared dependency name that is not an identifier" $ do
      let toml =
            Text.unlines
              [ "[package]",
                "name = \"hello\"",
                "[runtime]",
                "url = \"http://x\"",
                "[dependencies]",
                "packages = [\"../escape\"]"
              ]
      parseKatariToml "katari.toml" toml `shouldSatisfy` either isConfigValidationError (const False)

    it "rejects a [package].src that escapes the project root" $ do
      let toml =
            Text.unlines
              [ "[package]",
                "name = \"hello\"",
                "src = \"../outside\"",
                "[runtime]",
                "url = \"http://x\"",
                "[dependencies]",
                "packages = []"
              ]
      parseKatariToml "katari.toml" toml `shouldSatisfy` either isConfigValidationError (const False)

    it "rejects an override that names no declared dependency" $ do
      let toml =
            Text.unlines
              [ "[package]",
                "name = \"hello\"",
                "[runtime]",
                "url = \"http://x\"",
                "[dependencies]",
                "packages = []",
                "[overrides.ghost]",
                "path = \"../ghost\""
              ]
      parseKatariToml "katari.toml" toml `shouldSatisfy` either isConfigValidationError (const False)

    it "reports a malformed document as a parse error" $
      parseKatariToml "katari.toml" "this is not = = toml"
        `shouldSatisfy` either isConfigParseError (const False)

  describe "isValidPackageName" $ do
    it "accepts identifier-shaped names" $ do
      isValidPackageName "foo" `shouldBe` True
      isValidPackageName "_private9" `shouldBe` True
      isValidPackageName "List_Utils" `shouldBe` True

    it "rejects non-identifier names" $ do
      isValidPackageName "" `shouldBe` False
      isValidPackageName "9lives" `shouldBe` False
      isValidPackageName "a-b" `shouldBe` False
      isValidPackageName "a.b" `shouldBe` False
