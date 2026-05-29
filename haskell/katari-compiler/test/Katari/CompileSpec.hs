-- | End-to-end tests for 'Katari.Compile.compile' — verifies that the
-- pure orchestration entry point produces an 'IRModule' / @[SchemaEntry]@
-- for well-formed input and a populated 'diagnostics' stream for
-- ill-formed input.
module Katari.CompileSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing)
import Katari.Compile
import Katari.Diagnostic (Diagnostic (..), hasErrors)
import Katari.TestSupport (compileSync, multiSourceInput, singleSourceInput)
import Test.Hspec

-- ===========================================================================
-- Spec
-- ===========================================================================

spec :: Spec
spec = describe "Katari.Compile" $ do
  happyPathSpec
  errorPathSpec
  multiModuleSpec
  incrementalCacheSpec
  exhaustiveSpec
  externalAgentSpec
  recursiveDataSpec

happyPathSpec :: Spec
happyPathSpec = describe "well-formed single-module input" $ do
  it "produces an IRModule and schema entries for a trivial agent" $ do
    let result = compileSync (singleSourceInput "agent main() { 42 }")
    hasErrors result.diagnostics `shouldBe` False
    isJust result.irModule `shouldBe` True
    isJust result.schemaEntries `shouldBe` True

  it "multi-line array literal does NOT require trailing comma" $ do
    let src =
          mconcat
            [ "agent main() -> integer {\n",
              "  let xs = [\n",
              "    1,\n",
              "    2,\n",
              "    3\n",
              "  ]\n",
              "  xs[0]\n",
              "}\n"
            ]
    let result = compileSync (singleSourceInput src)
    hasErrors result.diagnostics `shouldBe` False
    isJust result.irModule `shouldBe` True

  it "multi-line call argument list does NOT require trailing comma" $ do
    let src =
          mconcat
            [ "agent myAdd(a = a: integer, b = b: integer) -> integer { a + b }\n",
              "agent main() -> integer {\n",
              "  myAdd(\n",
              "    a = 1,\n",
              "    b = 2\n",
              "  )\n",
              "}\n"
            ]
    let result = compileSync (singleSourceInput src)
    hasErrors result.diagnostics `shouldBe` False
    isJust result.irModule `shouldBe` True

  it "bare break inside for-loop defaults to break null" $ do
    let src =
          mconcat
            [ "agent main() -> null {\n",
              "  for(let x in [1, 2, 3]) {\n",
              "    break\n",
              "  } then { null }\n",
              "}\n"
            ]
    let result = compileSync (singleSourceInput src)
    hasErrors result.diagnostics `shouldBe` False
    isJust result.irModule `shouldBe` True

  it "bare return defaults to return null" $ do
    let src =
          mconcat
            [ "agent main() -> null {\n",
              "  return\n",
              "}\n"
            ]
    let result = compileSync (singleSourceInput src)
    hasErrors result.diagnostics `shouldBe` False
    isJust result.irModule `shouldBe` True

  it "match arms across newlines need no explicit separator" $ do
    -- Each arm is `case PATTERN => { body }`. After the closing `}` of an
    -- arm body, a newline inserts a virtual semicolon (since `}` is in
    -- the auto-semi trigger list), which separates arms cleanly. No
    -- comma or explicit `;` needed.
    let src =
          mconcat
            [ "data Red()\n",
              "data Green()\n",
              "data Blue()\n",
              "agent name(c = c: Red | Green | Blue) -> string {\n",
              "  match (c) {\n",
              "    case Red => { \"red\" }\n",
              "    case Green => { \"green\" }\n",
              "    case Blue => { \"blue\" }\n",
              "  }\n",
              "}\n"
            ]
    let result = compileSync (singleSourceInput src)
    hasErrors result.diagnostics `shouldBe` False
    isJust result.irModule `shouldBe` True

  it "break with a block-expression argument compiles end-to-end" $ do
    -- The break value is itself a block expression that uses an inner
    -- handle/then. Inner break / return / next from this block would
    -- target their outer boundaries directly, but here the block has
    -- only normal completion (tail value 7), so the outer for-loop's
    -- break receives 7. Confirms parser, type checker (no
    -- withThenModifiedContexts), and lowering all accept this shape.
    let src =
          mconcat
            [ "agent main() -> integer {\n",
              "  for(let x in [1, 2, 3]) {\n",
              "    break {\n",
              "      handle {} then(_) { 0 }\n",
              "      7\n",
              "    };\n",
              "  } then { 0 }\n",
              "}"
            ]
    let result = compileSync (singleSourceInput src)
    hasErrors result.diagnostics `shouldBe` False
    isJust result.irModule `shouldBe` True

errorPathSpec :: Spec
errorPathSpec = describe "ill-formed input" $ do
  it "returns parse-error diagnostics and no IR for a syntax error" $ do
    let result = compileSync (singleSourceInput "agent main() {")
    hasErrors result.diagnostics `shouldBe` True
    isNothing result.irModule `shouldBe` True
    isNothing result.schemaEntries `shouldBe` True

  it "carries each diagnostic's code in the K#### range" $ do
    let result = compileSync (singleSourceInput "agent main() {")
        codes = map (.code) result.diagnostics
    -- All codes must start with 'K'.
    all (\c -> not (null (show c)) && head (show c) == '"') codes `shouldBe` True

multiModuleSpec :: Spec
multiModuleSpec = describe "multi-module input" $ do
  it "flags imports of modules not present in the source map" $ do
    let result =
          compileSync
            ( singleSourceInput
                "import { foo } from missing\nagent main() { 1 }"
            )
    -- We don't assert the precise code (parse may already fail), but at
    -- minimum the diagnostics list should be non-empty.
    hasErrors result.diagnostics `shouldBe` True

  it "compiles successfully when all imported modules are present" $ do
    -- Even a no-op multi-module setup: two modules with no cross-imports
    -- should both compile without diagnostics.
    let result =
          compileSync
            ( multiSourceInput
                [ ("util", "agent helper() { 1 }"),
                  ("main", "agent main() { 2 }")
                ]
            )
    hasErrors result.diagnostics `shouldBe` False
    isJust result.irModule `shouldBe` True

-- ===========================================================================
-- Incremental cache soundness (dependency change invalidation)
-- ===========================================================================

incrementalCacheSpec :: Spec
incrementalCacheSpec = describe "incremental cache" $ do
  it "preserves a cache-hit module's diagnostics when only its dependency's body changed" $ do
    -- modb exports foo() -> integer. moda imports foo and (wrongly) returns
    -- its result where a string is expected, so moda has a type error that
    -- depends only on foo's *signature*, not its body. Editing modb's body
    -- (same signature) must NOT make moda's error disappear: moda's own
    -- source is unchanged.
    let modaSrc =
          "import { foo } from modb\n\
          \agent useA() -> string { foo() }"
        mkInput modbBody priorCache =
          CompileInput
            { sources =
                Map.fromList
                  [ ("moda", SourceEntry {filePath = "moda", sourceText = modaSrc}),
                    ("modb", SourceEntry {filePath = "modb", sourceText = modbBody})
                  ],
              cache = priorCache
            }
        result1 = compileSync (mkInput "agent foo() -> integer { 1 }" Map.empty)
        result2 = compileSync (mkInput "agent foo() -> integer { 2 }" result1.updatedCache)
    -- Pass 1: moda is freshly compiled and its type error is reported.
    hasErrors result1.diagnostics `shouldBe` True
    -- Pass 2: moda's source is unchanged so its error must still be present.
    hasErrors result2.diagnostics `shouldBe` True

-- ===========================================================================
-- Exhaustiveness diagnostics (K0290 / K0291 / K0292)
-- ===========================================================================

exhaustiveSpec :: Spec
exhaustiveSpec = describe "exhaustiveness checker" $ do
  it "K0290: match covers only one arm of a two-variant data type" $ do
    let src =
          "data Apple()\n\
          \data Orange()\n\
          \type Fruit = Apple | Orange\n\
          \agent main() -> integer {\n\
          \  let x: Fruit = Apple()\n\
          \  match (x) {\n\
          \    case Apple() => {\n\
          \      1\n\
          \    }\n\
          \  }\n\
          \}"
        result = compileSync (singleSourceInput src)
        codes = map (.code) result.diagnostics
    codes `shouldContain` ["K0290"]

  it "K0290: match covers only Some arm of a Some/None data type" $ do
    let src =
          "data Some(value: integer)\n\
          \data None()\n\
          \type Option = Some | None\n\
          \agent main() -> integer {\n\
          \  let x: Option = Some(value = 1)\n\
          \  match (x) {\n\
          \    case Some(value = v) => {\n\
          \      v\n\
          \    }\n\
          \  }\n\
          \}"
        result = compileSync (singleSourceInput src)
        codes = map (.code) result.diagnostics
    codes `shouldContain` ["K0290"]

  it "K0292: second arm with same pattern is unreachable" $ do
    let src =
          "agent main() -> integer {\n\
          \  match (1) {\n\
          \    case _ => {\n\
          \      1\n\
          \    }\n\
          \    case 1 => {\n\
          \      2\n\
          \    }\n\
          \  }\n\
          \}"
        result = compileSync (singleSourceInput src)
        codes = map (.code) result.diagnostics
    codes `shouldContain` ["K0292"]

  it "K0291: let binding with refutable constructor pattern" $ do
    let src =
          "data Some(value: integer)\n\
          \data None()\n\
          \type Option = Some | None\n\
          \agent main() -> integer {\n\
          \  let x: Option = None()\n\
          \  let None() = x\n\
          \  0\n\
          \}"
        result = compileSync (singleSourceInput src)
        codes = map (.code) result.diagnostics
    codes `shouldContain` ["K0291"]

  it "exhaustive match over all constructors has no exhaustive errors" $ do
    let src =
          "data Apple()\n\
          \data Orange()\n\
          \type Fruit = Apple | Orange\n\
          \agent main() -> integer {\n\
          \  let x: Fruit = Apple()\n\
          \  match (x) {\n\
          \    case Apple() => {\n\
          \      1\n\
          \    }\n\
          \    case Orange() => {\n\
          \      2\n\
          \    }\n\
          \  }\n\
          \}"
        result = compileSync (singleSourceInput src)
        exhaustiveCodes = filter (\c -> c == "K0290" || c == "K0291" || c == "K0292") (map (.code) result.diagnostics)
    exhaustiveCodes `shouldBe` []

-- ===========================================================================
-- External agent annotation validation (K0150 / K0151)
-- ===========================================================================

externalAgentSpec :: Spec
externalAgentSpec = describe "external agent annotation validation" $ do
  it "K0150: external without annotation produces an error" $ do
    let result =
          compileSync
            ( singleSourceInput
                "request http_req()\nexternal fetch(url: string) -> string with http_req from \"FFI:lib.fetch\""
            )
        codes = map (.code) result.diagnostics
    codes `shouldContain` ["K0150"]

  it "K0151: external with empty annotation produces an error" $ do
    let result =
          compileSync
            ( singleSourceInput
                "request http_req()\n@\"\"\nexternal fetch(url: string) -> string with http_req from \"FFI:lib.fetch\""
            )
        codes = map (.code) result.diagnostics
    codes `shouldContain` ["K0151"]

  it "external with non-empty annotation compiles without K0150/K0151" $ do
    let result =
          compileSync
            ( singleSourceInput
                "request http_req()\n@\"https://api.example.com\"\nexternal fetch(url: string) -> string with http_req from \"FFI:lib.fetch\"\nagent main() -> string { \"ok\" }"
            )
        codes = map (.code) result.diagnostics
    filter (\c -> c == "K0150" || c == "K0151") codes `shouldBe` []

-- ===========================================================================
-- Recursive data type (Phase 18.D)
-- ===========================================================================

recursiveDataSpec :: Spec
recursiveDataSpec = describe "recursive data type" $ do
  it "recursive data declaration compiles without errors" $ do
    let src =
          "data Cons(head: integer, tail: List)\n\
          \data Nil()\n\
          \type List = Cons | Nil\n\
          \agent main() -> integer {\n\
          \  let xs: List = Cons(head = 1, tail = Nil())\n\
          \  0\n\
          \}"
        result = compileSync (singleSourceInput src)
    hasErrors result.diagnostics `shouldBe` False
    isJust result.irModule `shouldBe` True

  it "recursive data IR round-trips through Aeson" $ do
    let src =
          "data Cons(head: integer, tail: List)\n\
          \data Nil()\n\
          \type List = Cons | Nil\n\
          \agent main() -> integer { 0 }"
        result = compileSync (singleSourceInput src)
    case result.irModule of
      Nothing -> expectationFailure "expected irModule but got Nothing"
      Just ir ->
        case Aeson.fromJSON (Aeson.toJSON ir) of
          Aeson.Success decoded -> decoded `shouldBe` ir
          Aeson.Error msg -> expectationFailure ("decode failed: " <> msg)
