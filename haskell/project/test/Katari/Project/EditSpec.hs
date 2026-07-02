module Katari.Project.EditSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as Text
import Katari.Project.Edit (EditError (..), rewritePackages)
import Test.Hspec

-- | A config with formatting worth preserving: comments, blank lines, spacing, neighbouring tables.
sampleConfig :: Text
sampleConfig =
  Text.unlines
    [ "# my project",
      "[package]",
      "name = \"demo\"   # the name",
      "",
      "[dependencies]",
      "registry = \"https://example.com/registry\"",
      "snapshot = \"staging\"",
      "packages = [\"list_utils\"]",
      "",
      "[runtime]",
      "url = \"http://localhost:3000\""
    ]

expectRight :: Either EditError Text -> IO Text
expectRight result = case result of
  Left editError -> do
    expectationFailure ("expected success, got " <> show editError)
    pure ""
  Right text -> pure text

spec :: Spec
spec = describe "rewritePackages" $ do
  it "replaces the array and preserves every other byte" $ do
    rewritten <- expectRight (rewritePackages sampleConfig ["list_utils", "extra"])
    rewritten
      `shouldBe` Text.unlines
        [ "# my project",
          "[package]",
          "name = \"demo\"   # the name",
          "",
          "[dependencies]",
          "registry = \"https://example.com/registry\"",
          "snapshot = \"staging\"",
          "packages = [\"list_utils\", \"extra\"]",
          "",
          "[runtime]",
          "url = \"http://localhost:3000\""
        ]

  it "rewrites to an empty array when the last package is removed" $ do
    rewritten <- expectRight (rewritePackages sampleConfig [])
    rewritten `shouldSatisfy` Text.isInfixOf "packages = []"

  it "preserves the assignment's own spacing style and a trailing comment" $ do
    let spaced = "[dependencies]\npackages   =   [] # deps here\n"
    rewritten <- expectRight (rewritePackages spaced ["a"])
    rewritten `shouldBe` "[dependencies]\npackages   =   [\"a\"] # deps here\n"

  it "collapses a multi-line array onto the assignment line" $ do
    let multiLine =
          Text.unlines
            [ "[dependencies]",
              "packages = [",
              "  \"one\",",
              "  \"two\",",
              "]",
              "",
              "[runtime]",
              "url = \"http://localhost\""
            ]
    rewritten <- expectRight (rewritePackages multiLine ["one"])
    rewritten
      `shouldBe` Text.unlines
        [ "[dependencies]",
          "packages = [\"one\"]",
          "",
          "[runtime]",
          "url = \"http://localhost\""
        ]

  it "inserts the packages key right under an existing [dependencies] header lacking one" $ do
    let noKey = "[dependencies]\nregistry = \"https://example.com\"\n"
    rewritten <- expectRight (rewritePackages noKey ["a"])
    rewritten `shouldBe` "[dependencies]\npackages = [\"a\"]\nregistry = \"https://example.com\"\n"

  it "appends a [dependencies] table when the file has none" $ do
    let noTable = "[package]\nname = \"demo\"\n"
    rewritten <- expectRight (rewritePackages noTable ["a"])
    rewritten `shouldBe` "[package]\nname = \"demo\"\n\n[dependencies]\npackages = [\"a\"]\n"

  it "is idempotent: rewriting with the same list changes nothing further" $ do
    once <- expectRight (rewritePackages sampleConfig ["x", "y"])
    twice <- expectRight (rewritePackages once ["x", "y"])
    twice `shouldBe` once

  it "refuses an array holding a comment (it cannot be preserved)" $ do
    let commented =
          Text.unlines
            [ "[dependencies]",
              "packages = [",
              "  \"one\", # keep me",
              "]"
            ]
    rewritePackages commented ["one"] `shouldSatisfy` either (const True) (const False)

  it "refuses a nested array (not a flat package list)" $ do
    let nested = "[dependencies]\npackages = [[\"one\"]]\n"
    rewritePackages nested ["one"] `shouldSatisfy` either (const True) (const False)

  it "refuses an array that never closes" $ do
    let unterminated = "[dependencies]\npackages = [\"one\","
    rewritePackages unterminated ["one"] `shouldSatisfy` either (const True) (const False)

  it "refuses a package name that is not a plain identifier" $
    rewritePackages sampleConfig ["not a name"] `shouldSatisfy` either (const True) (const False)

  it "does not mistake a longer key for packages" $ do
    let lookalike = "[dependencies]\npackages_extra = [\"z\"]\npackages = []\n"
    rewritten <- expectRight (rewritePackages lookalike ["a"])
    rewritten `shouldBe` "[dependencies]\npackages_extra = [\"z\"]\npackages = [\"a\"]\n"
