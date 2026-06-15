module Katari.StdlibSpec (spec) where

import Data.Foldable (toList)
import Data.List (nub)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Katari.Data.AST
import Katari.Data.ModuleName (ModuleName (..), covers, lastSegment)
import Katari.Data.SourceSpan (Located (..))
import Katari.Diagnostics (Diagnostics)
import Katari.Error (compilerErrorCode)
import Katari.Identifier (identifyModule, scanExports)
import Katari.Identifier.Monad (ImportContext (..))
import Katari.Parser (parseModule)
import Katari.Primitive
  ( binaryOperatorLeftLabel,
    binaryOperatorName,
    binaryOperatorRightLabel,
    primitiveModuleName,
    unaryOperatorName,
    unaryOperatorOperandLabel,
  )
import Katari.Stdlib (defaultImports, isReservedModuleName, stdlibSources)
import Test.Hspec

spec :: Spec
spec = do
  describe "stdlibSources" $ do
    it "embeds the primitive module" $
      Map.member primitiveModuleName stdlibSources `shouldBe` True

    it "default-imports the primitive root" $
      defaultImports `shouldBe` [primitiveModuleName]

    it "parses and identifies every stdlib module without diagnostics" $
      stdlibDiagnosticCodes `shouldBe` []

  describe "operator desugar table" $ do
    it "maps every binary operator to a primitive export with matching labels" $
      mapMaybe checkBinary [minBound .. maxBound] `shouldBe` []

    it "maps every unary operator to a primitive export with matching labels" $
      mapMaybe checkUnary [minBound .. maxBound] `shouldBe` []

  describe "isReservedModuleName" $ do
    it "reserves the primitive root" $
      isReservedModuleName (ModuleName "primitive") `shouldBe` True

    it "reserves a name under the primitive namespace" $
      isReservedModuleName (ModuleName "primitive.array") `shouldBe` True

    it "does not reserve an unrelated user module" $
      isReservedModuleName (ModuleName "my_module") `shouldBe` False

    it "does not reserve a mere name-prefix sibling of a reserved root" $
      isReservedModuleName (ModuleName "primitivex") `shouldBe` False

  describe "default-import expansion" $
    it "maps the default-import-covered stdlib modules to distinct last-segment qualifiers" $
      -- The invariant 'Katari.Identifier.defaultImportScope' relies on: covered modules are keyed by
      -- last segment, so a collision would silently shadow one. The covered set is compiler-controlled
      -- (the stdlib), so this guards it as the stdlib grows submodules / roots.
      let covered = filter (\moduleName -> any (`covers` moduleName) defaultImports) (Map.keys stdlibSources)
          qualifiers = lastSegment <$> covered
       in qualifiers `shouldBe` nub qualifiers

---------------------------------------------------------------------------------------------------
-- Stdlib parses + identifies cleanly
---------------------------------------------------------------------------------------------------

-- | Every embedded stdlib source parsed once, keyed by module name (parse diagnostics kept). Shared by
-- the import context, the clean-parse check, and the operator-table check, so each source is parsed
-- exactly once however many of those use it.
parsedStdlib :: Map ModuleName (Module Parsed, Diagnostics)
parsedStdlib = Map.mapWithKey parseModule stdlibSources

-- | Every diagnostic code from parsing + identifying every embedded stdlib module against the full
-- stdlib import context. Must be empty: the wired-in sources have to stay clean as the compiler moves.
stdlibDiagnosticCodes :: [Text]
stdlibDiagnosticCodes =
  [ compilerErrorCode diagnostic.value
    | (moduleName, (parsed, parseDiagnostics)) <- Map.toList parsedStdlib,
      let (_, identifyDiagnostics) = identifyModule stdlibContext moduleName parsed,
      diagnostic <- toList (parseDiagnostics <> identifyDiagnostics)
  ]

stdlibContext :: ImportContext
stdlibContext =
  ImportContext
    { moduleInterfaces = Map.mapWithKey (\moduleName (parsed, _) -> scanExports moduleName parsed) parsedStdlib,
      defaultImports = defaultImports
    }

---------------------------------------------------------------------------------------------------
-- Operator table ↔ primitive exports
---------------------------------------------------------------------------------------------------

-- | The parameter names of each @primitive@ agent, keyed by agent name — the source of truth the
-- desugar's emitted argument labels must match.
primitiveParameters :: Map Text [Text]
primitiveParameters = case Map.lookup primitiveModuleName parsedStdlib of
  Nothing -> Map.empty
  Just (parsed, _) ->
    Map.fromList
      [ (declaration.name, (.name) <$> declaration.parameters)
        | DeclarationPrimitiveAgent declaration <- parsed.declarations
      ]

checkBinary :: BinaryOperator -> Maybe Text
checkBinary operator = checkOperator (binaryOperatorName operator) [binaryOperatorLeftLabel, binaryOperatorRightLabel]

checkUnary :: UnaryOperator -> Maybe Text
checkUnary operator = checkOperator (unaryOperatorName operator) [unaryOperatorOperandLabel]

-- | A mismatch message between an operator's desugar target and the @primitive@ module, or 'Nothing'
-- when they agree on both the function name and the argument labels.
checkOperator :: Text -> [Text] -> Maybe Text
checkOperator name expectedLabels = case Map.lookup name primitiveParameters of
  Nothing -> Just (name <> ": not exported by the primitive module")
  Just actualLabels
    | actualLabels == expectedLabels -> Nothing
    | otherwise -> Just (name <> ": parameter labels do not match the desugar labels")
