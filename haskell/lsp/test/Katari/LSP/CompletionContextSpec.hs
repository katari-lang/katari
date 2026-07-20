module Katari.LSP.CompletionContextSpec (spec) where

import Data.Set qualified as Set
import Data.Vector qualified as Vector
import Katari.LSP.CompletionContext (declarationPrefix, detectLabelContext, detectMemberPrefix)
import Test.Hspec

spec :: Spec
spec = do
  describe "detectMemberPrefix" $ do
    it "detects a path at a trailing dot" $
      detectMemberPrefix "  let x = discord." `shouldBe` Just "discord"

    it "keeps the path while the member is being typed" $
      detectMemberPrefix "  let x = discord.wa" `shouldBe` Just "discord"

    it "walks a nested path" $
      detectMemberPrefix "  foo.bar.ba" `shouldBe` Just "foo.bar"

    it "does not fire on a bare identifier" $
      detectMemberPrefix "  let x = discord" `shouldBe` Nothing

    it "does not fire after a string literal" $
      detectMemberPrefix "  \"abc\"." `shouldBe` Nothing

  describe "detectLabelContext" $ do
    it "detects the callable and no used labels in an empty call" $
      detectLabelContext "  helper(" `shouldBe` Just ("helper", Set.empty)

    it "collects labels already written" $
      detectLabelContext "  helper(value = 1, other = 2, " `shouldBe` Just ("helper", Set.fromList ["value", "other"])

    it "sees a dotted callable" $
      detectLabelContext "  mod.func(a = 1, " `shouldBe` Just ("mod.func", Set.fromList ["a"])

    it "sees through a generic application" $
      detectLabelContext "  use mcp.provide[mcp.scope](url = u, " `shouldBe` Just ("mcp.provide", Set.fromList ["url"])

    it "ignores a closed call" $
      detectLabelContext "  helper(value = 1)" `shouldBe` Nothing

    it "spans lines when given a multi-line prefix" $
      detectLabelContext "  helper(\n    value = 1,\n    " `shouldBe` Just ("helper", Set.fromList ["value"])

  describe "declarationPrefix" $ do
    let lines' =
          Vector.fromList
            [ "agent main() -> string {",
              "  helper(",
              "    value = 1,",
              "    "
            ]

    it "gathers lines back to the enclosing declaration head" $
      declarationPrefix lines' 3 4 `shouldBe` "agent main() -> string {\n  helper(\n    value = 1,\n    "

    it "stays on the head line itself" $
      declarationPrefix lines' 0 5 `shouldBe` "agent"

    it "truncates the cursor line at the cursor" $
      declarationPrefix lines' 2 9 `shouldBe` "agent main() -> string {\n  helper(\n    value"
