module Katari.Cli.OutputSpec (spec) where

import Katari.Cli.Output (compactTimestamp, renderTable)
import Test.Hspec

spec :: Spec
spec = do
  describe "renderTable" $ do
    it "aligns each column to its widest cell and strips trailing padding" $
      renderTable ["ID", "STATE"] [["1", "running"], ["22", "done"]]
        `shouldBe` "ID  STATE\n1   running\n22  done"

    it "tolerates ragged rows (missing cells render empty)" $
      renderTable ["A", "B"] [["x"]] `shouldBe` "A  B\nx"

  describe "compactTimestamp" $ do
    it "cuts an ISO timestamp down to minutes" $
      compactTimestamp "2026-07-01T12:34:56.789Z" `shouldBe` "2026-07-01 12:34"

    it "passes short values through untouched" $
      compactTimestamp "(none)" `shouldBe` "(none)"
