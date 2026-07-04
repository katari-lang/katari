module Katari.PanicSpec (spec) where

import Control.Exception (evaluate)
import Katari.Panic (panic)
import Test.Hspec

spec :: Spec
spec =
  describe "panic" $
    it "aborts" $
      evaluate (panic "boom" :: ()) `shouldThrow` anyErrorCall
