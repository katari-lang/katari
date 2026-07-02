module Katari.Cli.CommonSpec (spec) where

import Katari.Cli.Common (PrefixError (..), resolveIdPrefix)
import Test.Hspec

spec :: Spec
spec = describe "resolveIdPrefix" $ do
  let identifiers = ["aaa-111", "aab-222", "bbb-333"]

  it "resolves a unique prefix to the full id" $
    resolveIdPrefix "bb" identifiers `shouldBe` Right "bbb-333"

  it "an exact match wins even when it prefixes another id" $
    resolveIdPrefix "aaa-111" ("aaa-111-extended" : identifiers) `shouldBe` Right "aaa-111"

  it "reports ambiguity with every candidate" $
    resolveIdPrefix "aa" identifiers `shouldBe` Left (PrefixAmbiguous ["aaa-111", "aab-222"])

  it "reports a prefix nothing starts with" $
    resolveIdPrefix "zz" identifiers `shouldBe` Left PrefixNotFound
