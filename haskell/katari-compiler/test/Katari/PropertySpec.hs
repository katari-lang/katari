-- | Property-based tests for the compiler's invariants.
--
-- The properties exercised here are deliberately small in scope: they
-- pin core JSON contracts and small algebraic laws that any future
-- refactor risks breaking. Generators are kept compact (size-bounded)
-- so the suite stays fast.
module Katari.PropertySpec (spec) where

import Data.Aeson qualified as Aeson
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Hedgehog (Gen, forAll, tripping, (===))
import Hedgehog qualified
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Katari.Common (LiteralValue (..), QualifiedName (..), parseQualifiedName, renderQualifiedName)
import Katari.Compile
  ( CompileInput (..),
    CompileResult (..),
    SourceEntry (..),
  )
import Katari.TestSupport (compileSync)
import Katari.IR
  ( BlockId (..),
    VarId (..),
  )
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "property tests" $ do
  qualifiedNameRoundtrip
  literalValueJsonRoundtrip
  irIdJsonRoundtrip
  compileDeterminism

-- ===========================================================================
-- QualifiedName: parse . render = id
-- ===========================================================================

qualifiedNameRoundtrip :: Spec
qualifiedNameRoundtrip =
  describe "QualifiedName" $ do
    it "parseQualifiedName . renderQualifiedName = id" $
      hedgehog $ do
        qualifiedName <- forAll genQualifiedName
        parseQualifiedName (renderQualifiedName qualifiedName) === qualifiedName

    it "round-trips through Aeson" $
      hedgehog $ do
        qualifiedName <- forAll genQualifiedName
        tripping qualifiedName Aeson.toJSON Aeson.fromJSON

-- ===========================================================================
-- LiteralValue: JSON round-trip
-- ===========================================================================

literalValueJsonRoundtrip :: Spec
literalValueJsonRoundtrip =
  describe "LiteralValue" $
    it "round-trips through Aeson" $
      hedgehog $ do
        literal <- forAll genLiteralValue
        tripping literal Aeson.toJSON Aeson.fromJSON

-- ===========================================================================
-- IR id newtypes: JSON round-trip
-- ===========================================================================

irIdJsonRoundtrip :: Spec
irIdJsonRoundtrip =
  describe "IR id newtypes round-trip through Aeson" $ do
    it "BlockId" $ hedgehog $ do
      value <- forAll (BlockId <$> Gen.word32 (Range.linear 0 1_000_000))
      tripping value Aeson.toJSON Aeson.fromJSON

    it "VarId" $ hedgehog $ do
      value <- forAll (VarId <$> Gen.word32 (Range.linear 0 1_000_000))
      tripping value Aeson.toJSON Aeson.fromJSON

-- ===========================================================================
-- compile is deterministic
-- ===========================================================================

compileDeterminism :: Spec
compileDeterminism =
  describe "compile" $
    it "is deterministic on a fixed source" $
      hedgehog $ do
        sourceText <- forAll genTrivialSource
        let mkInput =
              CompileInput
                { sources =
                    Map.singleton
                      "main"
                      ( SourceEntry
                          { filePath = "<property>",
                            sourceText = sourceText
                          }
                      ),
                  cache = Map.empty
                }
            r1 = compileSync mkInput
            r2 = compileSync mkInput
        -- Compare the externally-observable parts (Aeson works around
        -- the ZonkResult / SolverResult / IdentifierResult lacking Eq).
        Aeson.toJSON r1.irModule === Aeson.toJSON r2.irModule
        Aeson.toJSON r1.schemaEntries === Aeson.toJSON r2.schemaEntries
        Aeson.toJSON r1.diagnostics === Aeson.toJSON r2.diagnostics

-- ===========================================================================
-- Generators
-- ===========================================================================

genQualifiedName :: Gen QualifiedName
genQualifiedName = do
  -- Module path is a possibly-empty dot-joined sequence of bare names.
  segments <-
    Gen.frequency
      [ (1, pure []),
        (3, Gen.list (Range.linear 1 3) genBareName)
      ]
  let modulePath =
        case segments of
          [] -> ""
          xs -> Text.intercalate "." xs
  bareName <- genBareName
  pure QualifiedName {module_ = modulePath, name = bareName}

genBareName :: Gen Text
genBareName = do
  -- Identifiers are letter-led, alphanumeric / underscore body. Avoid
  -- `.` so renderQualifiedName / parseQualifiedName remain a clean
  -- inverse pair.
  firstChar <- Gen.alpha
  rest <- Gen.text (Range.linear 0 6) (Gen.choice [Gen.alphaNum, pure '_'])
  pure (Text.cons firstChar rest)

genLiteralValue :: Gen LiteralValue
genLiteralValue =
  Gen.choice
    [ LiteralValueInteger <$> Gen.integral (Range.linear (-1_000_000) 1_000_000),
      LiteralValueNumber <$> Gen.double (Range.linearFrac (-1_000) 1_000),
      LiteralValueString <$> Gen.text (Range.linear 0 20) Gen.unicode,
      LiteralValueBoolean <$> Gen.bool,
      pure LiteralValueNull
    ]

genTrivialSource :: Gen Text
genTrivialSource =
  -- A grab-bag of compile-able single-agent programs. Keep it compact:
  -- the property checks determinism, not coverage.
  Gen.element
    [ "agent main() -> integer { 0 }",
      "agent main() -> integer { 1 + 2 }",
      "agent main() -> string { \"hello\" }",
      "agent main(x: integer) -> integer { x }",
      "agent main() -> boolean { true }",
      "agent main() -> null { null }"
    ]
