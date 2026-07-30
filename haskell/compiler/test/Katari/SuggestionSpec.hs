module Katari.SuggestionSpec (spec) where

import Katari.Suggestion (editDistance, nearestNames, renderSuggestion)
import Test.Hspec

spec :: Spec
spec = do
  describe "editDistance" $ do
    it "is zero for equal names" $
      editDistance "join" "join" `shouldBe` 0

    it "counts one substitution, insertion, or deletion as one edit" $ do
      editDistance "join" "coin" `shouldBe` 1
      editDistance "join" "joins" `shouldBe` 1
      editDistance "joins" "join" `shouldBe` 1

    -- The whole reason for optimal string alignment rather than plain Levenshtein: a swap is ONE typo,
    -- and pricing it at two would push `jion` past the budget a four-character name can afford.
    it "counts an adjacent transposition as one edit" $ do
      editDistance "jion" "join" `shouldBe` 1
      editDistance "lenght" "length" `shouldBe` 1

    it "counts unrelated names as far apart" $
      editDistance "join" "stringify" `shouldBe` 7

    it "handles an empty name against a non-empty one" $ do
      editDistance "" "join" `shouldBe` 4
      editDistance "join" "" `shouldBe` 4

  describe "nearestNames" $ do
    it "offers the transposed name a misspelling meant" $
      nearestNames "jion" ["join", "split", "trim", "length"] `shouldBe` ["join"]

    it "orders by distance, then by name for a deterministic message" $
      nearestNames "pst" ["post", "past", "pest"] `shouldBe` ["past", "pest", "post"]

    it "offers at most three candidates" $
      nearestNames "post" ["pest", "past", "cost", "posts", "port"] `shouldBe` ["cost", "past", "pest"]

    it "offers nothing when no candidate is close" $
      nearestNames "publish" ["join", "split", "trim"] `shouldBe` []

    it "never offers the written name itself" $
      nearestNames "join" ["join"] `shouldBe` []

    -- Under three characters every other short name is within one edit, so a suggestion would be a
    -- coin toss dressed as a hint.
    it "stays silent for a one- or two-character name" $ do
      nearestNames "x" ["y", "z"] `shouldBe` []
      nearestNames "id" ["is", "it"] `shouldBe` []

    it "allows more edits in a long name than in a short one" $ do
      -- Two edits over four characters is half the name: not a typo, a different word.
      nearestNames "post" ["cast"] `shouldBe` []
      nearestNames "post_mesage" ["post_message"] `shouldBe` ["post_message"]

  describe "renderSuggestion" $ do
    it "renders nothing for no candidates, so a caller can append it unconditionally" $
      renderSuggestion [] `shouldBe` ""

    it "renders one candidate as a single question" $
      renderSuggestion ["join"] `shouldBe` "; did you mean `join`?"

    it "renders several candidates as a list" $
      renderSuggestion ["join", "joins"] `shouldBe` "; did you mean one of `join`, `joins`?"
