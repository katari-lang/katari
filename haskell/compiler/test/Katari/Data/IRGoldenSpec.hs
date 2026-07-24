{-# LANGUAGE TemplateHaskell #-}

-- | IR golden fixture: a small program that touches a spread of surface constructs (a data type, a
-- parameterised request + `use handler`, a `for`-fold with `var` state and a then-clause, a `match`, an
-- `if`, arithmetic / comparison operators, an f-string, and a delegation) is compiled and its lowered
-- IR is compared, as JSON, to a committed golden. The IR JSON is the hand-mirrored contract between the
-- Haskell 'Katari.Data.IR' and the runtime's `ir.ts`; this catches an unintended change to that wire
-- shape (a renamed field, a dropped tag) HERE — one recompile — rather than only at the e2e boundary.
--
-- Only the user module is compared, not the spliced-in stdlib, so the golden is small and stable against
-- stdlib content changes; a wire-shape change still shows because the user module uses the same IR types.
-- The comparison is over decoded JSON VALUES, so it is insensitive to key order and formatting.
--
-- Regenerate the golden after an INTENTIONAL IR change (or a change to the fixture source), from the
-- repo root:
--
--   stack build
--   stack exec katari -- build -C haskell/compiler/test/golden/golden_probe -o /tmp/golden-full.json
--   python3 -c "import json; d = json.load(open('/tmp/golden-full.json')); \
--     open('haskell/compiler/test/golden/golden_probe/golden.ir.json', 'w').write(\
--     json.dumps(d['golden_probe'], indent=2, sort_keys=True) + '\n')"
--
-- (`katari build` emits every module; the extraction keeps just the `golden_probe` user module — the
-- exact value this test's `toJSON` produces.) Review the golden diff: it IS the wire change, and the
-- runtime's `ir.ts` must move with it.
module Katari.Data.IRGoldenSpec (spec) where

import Data.Aeson (Value, eitherDecodeStrict, toJSON)
import Data.ByteString (ByteString)
import Data.FileEmbed (embedFile, embedStringFile, makeRelativeToProject)
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Katari.Compile (CompileInput (..), CompileResult (..), compile)
import Katari.Data.ModuleName (ModuleName (..))
import Test.Hspec

-- | The fixture source, embedded at build time — the single source the update procedure above also
-- recompiles, so the golden and this test can never diverge on which program was measured.
goldenSource :: Text
goldenSource =
  Text.pack $(makeRelativeToProject "test/golden/golden_probe/src/golden_probe.ktr" >>= embedStringFile)

-- | The committed golden JSON (the `golden_probe` module's lowered IR), embedded at build time.
goldenIr :: ByteString
goldenIr = $(makeRelativeToProject "test/golden/golden_probe/golden.ir.json" >>= embedFile)

moduleName :: ModuleName
moduleName = ModuleName "golden_probe"

spec :: Spec
spec = describe "IR golden fixture (golden_probe)" $ do
  let result = compile CompileInput {sources = Map.singleton moduleName goldenSource}

  it "compiles the fixture program with no errors (so it lowers to IR)" $
    -- Lowering is gated on an error-free program, so a present module also witnesses a clean compile.
    Map.member moduleName result.loweredModules `shouldBe` True

  it "lowers to the committed golden IR (the IR.hs ↔ ir.ts wire-shape trip-wire)" $
    case Map.lookup moduleName result.loweredModules of
      Nothing -> expectationFailure "golden_probe did not compile — see the sibling clean-compile check"
      Just irModule ->
        case eitherDecodeStrict goldenIr :: Either String Value of
          Left parseError -> expectationFailure ("golden.ir.json is not valid JSON: " <> parseError)
          Right golden -> toJSON irModule `shouldBe` golden
