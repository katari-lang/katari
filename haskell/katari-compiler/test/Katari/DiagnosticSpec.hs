-- | Round-trip tests for 'Katari.Diagnostic' and the per-phase
-- @toDiagnostic@ converters.
--
-- Goals:
--
--   * Each per-phase converter produces 'Error' severity (compiler errors
--     are not warnings/hints — those tiers are reserved for future use).
--   * Per-phase converters allocate codes from their reserved range
--     (K0001-K0099 lexer\/parser, K0100-K0199 identifier, K0200-K0249
--     constraint\/solver, K0250-K0279 zonker, K0300-K0399 lowering).
--   * 'Diagnostic' / 'DiagnosticNote' round-trip through Aeson.
module Katari.DiagnosticSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as T
import Katari.AST (Position (..), SourceSpan (..))
import Katari.Diagnostic
import Katari.Lexer qualified as Lexer
import Katari.Lowering qualified as Lowering
import Katari.Parser qualified as Parser
import Katari.Typechecker.ConstraintGenerator qualified as CG
import Katari.Typechecker.Identifier qualified as Identifier
import Katari.Typechecker.SemanticType (EffectVarId (..), TypeVarId (..))
import Katari.Typechecker.Solver qualified as Solver
import Katari.Typechecker.Zonker qualified as Zonker
import Test.Hspec

-- ===========================================================================
-- Helpers
-- ===========================================================================

dummySpan :: SourceSpan
dummySpan =
  SrcSpan
    { filePath = "<test>",
      start = Position {line = 1, column = 1},
      end = Position {line = 1, column = 2}
    }

isReservedCode :: Text -> Text -> Text -> Bool
isReservedCode lo hi code =
  T.length code == 5
    && T.head code == 'K'
    && code >= lo
    && code <= hi

-- ===========================================================================
-- Spec
-- ===========================================================================

spec :: Spec
spec = describe "Katari.Diagnostic" $ do
  severitySpec
  perPhaseConverterSpec
  jsonRoundTripSpec

severitySpec :: Spec
severitySpec = describe "Severity" $ do
  it "ordering: Hint < Info < Warning < Error" $ do
    compare Hint Info `shouldBe` LT
    compare Info Warning `shouldBe` LT
    compare Warning Error `shouldBe` LT

  it "hasErrors detects an Error in a mixed list" $ do
    let mixed =
          [ diagnosticWarning "K0001" "warn" dummySpan,
            diagnosticError "K0002" "err" dummySpan
          ]
    hasErrors mixed `shouldBe` True

  it "hasErrors returns False if no Error severity is present" $ do
    let warnings = [diagnosticWarning "K0001" "warn" dummySpan]
    hasErrors warnings `shouldBe` False

perPhaseConverterSpec :: Spec
perPhaseConverterSpec = describe "per-phase toDiagnostic" $ do
  it "Lexer codes fall in K0001-K0099" $ do
    let diags =
          map
            Lexer.toDiagnostic
            [ Lexer.LexerErrorUnterminatedTemplate dummySpan,
              Lexer.LexerErrorUnterminatedString dummySpan,
              Lexer.LexerErrorInvalidUnicodeEscape dummySpan "\\uXYZW",
              Lexer.LexerErrorUnrecognizedCharacter dummySpan '`'
            ]
    mapM_ (\d -> d.severity `shouldBe` Error) diags
    mapM_ (\d -> isReservedCode "K0001" "K0099" d.code `shouldBe` True) diags

  it "Parser codes fall in K0001-K0099" $ do
    let parseReason = Parser.ParseErrorReason {expected = ["foo"], unexpected = Just "bar"}
        diags =
          map
            Parser.toDiagnostic
            [ Parser.ParseErrorAtDeclaration dummySpan parseReason,
              Parser.ParseErrorAtStatement dummySpan parseReason
            ]
    mapM_ (\d -> d.severity `shouldBe` Error) diags
    mapM_ (\d -> isReservedCode "K0001" "K0099" d.code `shouldBe` True) diags

  it "Identifier codes fall in K0100-K0199" $ do
    let diags =
          map
            Identifier.toDiagnostic
            [ Identifier.ErrorDuplicateName dummySpan "x" dummySpan,
              Identifier.ErrorShadowNonVariable dummySpan "x",
              Identifier.ErrorUndefinedName dummySpan "x",
              Identifier.ErrorUndefinedQualified dummySpan "m" "x",
              Identifier.ErrorNotAType dummySpan "x",
              Identifier.ErrorNotAModule dummySpan "x",
              Identifier.ErrorImportNameNotFound dummySpan "m" "x",
              Identifier.ErrorImportModuleNotFound dummySpan "m"
            ]
    mapM_ (\d -> d.severity `shouldBe` Error) diags
    mapM_ (\d -> isReservedCode "K0100" "K0199" d.code `shouldBe` True) diags

  it "ConstraintGenerator codes fall in K0200-K0299" $ do
    let diag = CG.toDiagnostic (CG.ErrorTypeSynonymCycle dummySpan (Identifier.TypeId 0))
    diag.severity `shouldBe` Error
    isReservedCode "K0200" "K0299" diag.code `shouldBe` True

  it "Zonker codes fall in K0200-K0299" $ do
    let diags =
          map
            Zonker.toDiagnostic
            [ Zonker.ZonkErrorMissingTypeVar dummySpan (TypeVarId 0),
              Zonker.ZonkErrorMissingEffectVar dummySpan (EffectVarId 0)
            ]
    mapM_ (\d -> d.severity `shouldBe` Error) diags
    mapM_ (\d -> isReservedCode "K0200" "K0299" d.code `shouldBe` True) diags

  it "Lowering codes fall in K0300-K0399" $ do
    let diags =
          map
            Lowering.toDiagnostic
            [ Lowering.LowerErrorUnresolvedVariable dummySpan "x",
              Lowering.LowerErrorParseSentinel dummySpan,
              Lowering.LowerErrorUnsupported dummySpan "feature"
            ]
    mapM_ (\d -> d.severity `shouldBe` Error) diags
    mapM_ (\d -> isReservedCode "K0300" "K0399" d.code `shouldBe` True) diags

jsonRoundTripSpec :: Spec
jsonRoundTripSpec = describe "JSON round-trip" $ do
  it "Diagnostic with notes/hints round-trips" $ do
    let diag =
          Diagnostic
            { severity = Error,
              code = "K0042",
              message = "test message",
              span = dummySpan,
              notes =
                [ DiagnosticNote
                    { span = dummySpan,
                      message = "see also here"
                    }
                ],
              hints = ["try renaming x"]
            }
        encoded = Aeson.toJSON diag
    case Aeson.fromJSON encoded of
      Aeson.Success decoded -> decoded `shouldBe` diag
      Aeson.Error msg -> expectationFailure ("decode failed: " <> msg)

  it "every Severity round-trips" $ do
    let roundTrip s = case Aeson.fromJSON (Aeson.toJSON s) of
          Aeson.Success s' -> s' `shouldBe` s
          Aeson.Error msg -> expectationFailure ("decode failed: " <> msg)
    mapM_ roundTrip [Hint, Info, Warning, Error]
