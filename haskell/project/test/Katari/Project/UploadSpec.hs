module Katari.Project.UploadSpec (spec) where

import Data.Char (isHexDigit)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.List (List)
import Katari.Data.IR (BlockId (..), IRModule (..), currentMetadata)
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Project.Upload (ModuleHash (..), UploadPlan (..), hashModule, planUpload)
import Test.Hspec

-- | A minimal module with the given debug names. Varying only 'names' is enough to vary the IR
-- content (and so the hash), which keeps the fixtures small.
moduleWithNames :: List (BlockId, Text) -> IRModule
moduleWithNames namePairs =
  IRModule
    { metadata = currentMetadata,
      blocks = Map.empty,
      entries = Map.empty,
      names = Map.fromList namePairs
    }

spec :: Spec
spec = do
  describe "hashModule" $ do
    it "is deterministic for the same module" $
      hashModule (moduleWithNames [(BlockId 0, "foo")])
        `shouldBe` hashModule (moduleWithNames [(BlockId 0, "foo")])

    it "differs when the IR content differs" $
      hashModule (moduleWithNames [(BlockId 0, "foo")])
        `shouldNotBe` hashModule (moduleWithNames [(BlockId 0, "bar")])

    it "produces a 64-char hex SHA-256 digest" $ do
      let ModuleHash hex = hashModule (moduleWithNames [])
      Text.length hex `shouldBe` 64
      Text.all isHexDigit hex `shouldBe` True

  describe "planUpload" $ do
    let moduleA = moduleWithNames [(BlockId 0, "a")]
        moduleB = moduleWithNames [(BlockId 0, "b")]
        nameA = ModuleName "a"
        nameB = ModuleName "b"
        nameC = ModuleName "c"
        built = Map.fromList [(nameA, moduleA), (nameB, moduleB)]

    it "uploads everything when the runtime holds nothing" $ do
      let plan = planUpload built Map.empty
      Map.keysSet plan.changed `shouldBe` Set.fromList [nameA, nameB]
      plan.unchanged `shouldBe` Set.empty
      plan.removed `shouldBe` Set.empty

    it "skips modules whose hash already matches and flags runtime-only ones for removal" $ do
      let runtimeHashes =
            Map.fromList
              [ (nameA, hashModule moduleA), -- already current
                (nameC, hashModule moduleA) -- runtime-only; this build no longer produces it
              ]
          plan = planUpload built runtimeHashes
      Map.keysSet plan.changed `shouldBe` Set.singleton nameB
      plan.unchanged `shouldBe` Set.singleton nameA
      plan.removed `shouldBe` Set.singleton nameC

    it "re-uploads a module whose runtime hash is stale" $ do
      let runtimeHashes = Map.fromList [(nameA, hashModule moduleB)] -- wrong hash recorded for A
          plan = planUpload built runtimeHashes
      Map.member nameA plan.changed `shouldBe` True
      plan.unchanged `shouldBe` Set.empty
