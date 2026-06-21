module Katari.IdentifierSpec (spec) where

import Data.Foldable (toList)
import Data.Map qualified as Map
import Data.Maybe (listToMaybe)
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Katari.Data.AST
import Katari.Data.Id (GenericId (..), LocalVariableId (..), TypeResolution, VariableResolution (..))
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Data.QualifiedName (QualifiedName (..))
import Katari.Data.SourceSpan (Located (..), Position (..), SourceSpan (..))
import Katari.Diagnostics (Diagnostics, reportAt)
import Katari.Error (CompilerError (..), IdentifierError (..), UndefinedNameErrorInfo (..), compilerErrorCode)
import Katari.Identifier (identifyModule, scanExports)
import Katari.Identifier.Monad
import Katari.Parser (parseModule)
import Test.Hspec

spec :: Spec
spec = do
  monadSpec
  scanExportsSpec
  identifySpec
  symbolTableSpec

---------------------------------------------------------------------------------------------------
-- Monad unit tests
---------------------------------------------------------------------------------------------------

monadSpec :: Spec
monadSpec = do
  describe "fresh-id supply" $
    it "hands out increasing generic ids" $
      fst (runIdentifier environment (sequence [freshGenericId, freshGenericId, freshGenericId]))
        `shouldBe` [GenericId (ModuleName "test") 0, GenericId (ModuleName "test") 1, GenericId (ModuleName "test") 2]

  describe "scope" $ do
    it "finds a binding added with bindInScope" $
      fst (runIdentifier environment (bindInScope someSpan [variableBinding "x" someSpan boundX] (lookupVariable "x")))
        `shouldBe` Just boundX
    it "restores the scope on exit" $
      fst (runIdentifier environment (bindInScope someSpan [variableBinding "x" someSpan boundX] (pure ()) >> lookupVariable "x"))
        `shouldBe` Nothing

  describe "diagnostics" $
    it "accumulates reported errors" $
      snd (runIdentifier environment (reportAt someSpan someError))
        `shouldBe` Seq.singleton Located {value = someError, sourceSpan = someSpan}

---------------------------------------------------------------------------------------------------
-- scanExports
---------------------------------------------------------------------------------------------------

scanExportsSpec :: Spec
scanExportsSpec =
  describe "scanExports" $ do
    it "exports each top-level declaration in the right namespaces" $ do
      let interface = interfaceOf "m" "agent foo() -> integer { 1 }\ndata point(x: integer)\nrequest tick() -> integer"
      Map.keys interface.exports `shouldBe` ["foo", "point", "tick"]
      memberVariableOf "foo" interface `shouldBe` Just (VariableResolutionQualifiedName (QualifiedName (ModuleName "m") "foo"))
      memberTypeOf "foo" interface `shouldBe` Nothing
      memberVariableOf "point" interface `shouldSatisfy` (/= Nothing)
      memberTypeOf "point" interface `shouldSatisfy` (/= Nothing)
      memberVariableOf "tick" interface `shouldSatisfy` (/= Nothing)
      memberTypeOf "tick" interface `shouldSatisfy` (/= Nothing)

    it "keeps a value and a type that share a name (distinct namespaces)" $ do
      let interface = interfaceOf "m" "type Foo = integer\nagent Foo() -> integer { 1 }"
      memberVariableOf "Foo" interface `shouldSatisfy` (/= Nothing)
      memberTypeOf "Foo" interface `shouldSatisfy` (/= Nothing)

---------------------------------------------------------------------------------------------------
-- identifyModule
---------------------------------------------------------------------------------------------------

identifySpec :: Spec
identifySpec = do
  describe "identifyModule (scope and references)" $ do
    it "resolves a valid program with no diagnostics" $
      diagnosticsOf (identify emptyContext "agent main() -> integer { let x = 1\n x + 1 }") `shouldSatisfy` null

    it "reports an undefined name (K2001)" $
      codesOf (identify emptyContext "agent main() -> integer { y }") `shouldBe` ["K2001"]

    it "allows forward / mutual reference among top-level declarations" $
      diagnosticsOf (identify emptyContext "agent a() -> integer { b() }\nagent b() -> integer { 1 }") `shouldSatisfy` null

    it "treats let as non-recursive (the value cannot see the bound name)" $
      codesOf (identify emptyContext "agent main() -> integer { let x = x\n 1 }") `shouldBe` ["K2001"]

    it "treats a local agent as self-recursive" $
      diagnosticsOf (identify emptyContext "agent main() -> integer { agent loop() -> integer { loop() }\n loop() }") `shouldSatisfy` null

    it "allows shadowing without a diagnostic" $
      diagnosticsOf (identify emptyContext "agent main(x: integer) -> integer { let x = 2\n x }") `shouldSatisfy` null

    it "resolves a generic parameter used in the signature and body" $
      diagnosticsOf (identify emptyContext "agent identity[T](value: T) -> T { value }") `shouldSatisfy` null

    it "resolves a handler with state, a request handler, and a modifier" $
      diagnosticsOf (identify emptyContext handlerProgram) `shouldSatisfy` null

  describe "identifyModule (duplicate names)" $ do
    it "reports a duplicate agent once (K2003)" $
      codesOf (identify emptyContext "agent foo() -> integer { 1 }\nagent foo() -> integer { 2 }") `shouldBe` ["K2003"]

    it "reports a request declared twice once, not once per namespace (K2003)" $
      codesOf (identify emptyContext "request tick() -> integer\nrequest tick() -> integer") `shouldBe` ["K2003"]

    it "does not treat a value and a type sharing a name as a duplicate" $
      diagnosticsOf (identify emptyContext "type Foo = integer\nagent Foo() -> integer { 1 }\nagent bar() -> Foo { Foo() }") `shouldSatisfy` null

    it "reports a duplicate parameter label (K2003)" $
      codesOf (identify emptyContext "agent foo(x: integer, x: integer) -> integer { x }") `shouldBe` ["K2003"]

    it "reports a duplicate call-argument label (K2003)" $
      codesOf (identify emptyContext "agent target(value: integer) -> integer { value }\nagent caller() -> integer { target(value = 1, value = 2) }") `shouldBe` ["K2003"]

    it "reports a request handled twice in one handler (K2003)" $
      codesOf (identify emptyContext duplicateHandlerProgram) `shouldBe` ["K2003"]

  describe "identifyModule (with modifiers)" $ do
    it "reports a with-modifier targeting a non-state variable (K2007)" $
      codesOf (identify emptyContext modifierNonStateProgram) `shouldBe` ["K2007"]

  describe "identifyModule (then clauses)" $ do
    -- A `then` clause's `next`/`break` targets the *enclosing* for/handler (the parser routes the
    -- keyword by the lexically-innermost loop context, which the `then` clause sits outside of), so a
    -- `with` modifier there resolves against that enclosing state — not the just-finished loop's own.
    it "resolves a then-clause `next ... with` against the enclosing handler state" $
      diagnosticsOf (identify emptyContext thenTargetsHandlerProgram) `shouldSatisfy` null

    it "resolves a then-clause `next ... with` against the enclosing outer loop state" $
      diagnosticsOf
        ( identify
            emptyContext
            "agent main() -> integer {\n\
            \  for (let x in [1], var a = 0) {\n\
            \    for (let y in [2]) { next y } then (z) { next z with { a = a + 1 } }\n\
            \    next a\n\
            \  }\n\
            \}\n"
        )
        `shouldSatisfy` null

    it "reads the loop's own state as a value in its then clause" $
      diagnosticsOf
        (identify emptyContext "agent main() -> integer {\n  for (let x in [1], var a = 0) {\n    next a + x\n  } then (y) {\n    a + y\n  }\n}\n")
        `shouldSatisfy` null

  describe "identifyModule (field access vs module qualification)" $ do
    it "synthesises a qualified reference for module.member" $ do
      let result = identify contextWithLib "import lib\nagent main() -> integer { lib.double(x = 6) }"
      diagnosticsOf result `shouldSatisfy` null
      mainCallCallee (moduleOf result) `shouldSatisfy` maybe False isQualifiedReference

    it "keeps a field access on a value with no diagnostic (a value shadows a like-named module)" $ do
      let result = identify contextWithLib "import lib\nagent main(lib: integer) -> integer { lib.field }"
      diagnosticsOf result `shouldSatisfy` null
      mainReturn (moduleOf result) `shouldSatisfy` maybe False isFieldAccess

    it "points a qualified type member reference at the member name, not the whole module.Name" $
      case agentNamed "main" (moduleOf (identify contextWithLib "import lib\nagent main() -> lib.pair { main() }")) >>= (.returnType) of
        Just (TypeName node) -> spanWidth node.typeReference.sourceSpan `shouldSatisfy` (< spanWidth node.sourceSpan)
        _ -> expectationFailure "expected a qualified type-name return type"

  describe "identifyModule (imports)" $ do
    it "imports a name unqualified" $
      diagnosticsOf (identify contextWithLib "import { double } from lib\nagent main() -> integer { double(x = 6) }") `shouldSatisfy` null

    it "resolves a submodule member of a default-import module via its qualifier" $
      diagnosticsOf (identify contextWithDefaultImport "agent main() -> integer { array.range(n = 3) }") `shouldSatisfy` null

    it "resolves a root member of a default-import module via the root qualifier" $
      diagnosticsOf (identify contextWithDefaultImport "agent main() -> integer { std.helper(x = 3) }") `shouldSatisfy` null

    it "does not bring a default-import module's names into scope unqualified" $
      codesOf (identify contextWithDefaultImport "agent main() -> integer { helper(x = 3) }") `shouldBe` ["K2001"]

    it "imports a module under an alias" $
      diagnosticsOf (identify contextWithLib "import lib as l\nagent main() -> integer { l.double(x = 6) }") `shouldSatisfy` null

    it "resolves a qualified type member" $
      diagnosticsOf (identify contextWithLib "import lib\nagent main(p: lib.pair) -> integer { 1 }") `shouldSatisfy` null

    it "reports an undefined module member (K2002)" $
      codesOf (identify contextWithLib "import lib\nagent main() -> integer { lib.missing(x = 6) }") `shouldBe` ["K2002"]

    it "reports an unknown imported module (K2005)" $
      codesOf (identify emptyContext "import nonexistent\nagent main() -> integer { 1 }") `shouldBe` ["K2005"]

    it "reports an unknown imported name (K2006)" $
      codesOf (identify contextWithLib "import { missing } from lib\nagent main() -> integer { 1 }") `shouldBe` ["K2006"]

    it "reports a non-module qualifier (K2004)" $
      codesOf (identify emptyContext "data point(x: integer)\nagent main() -> point.field { 1 }") `shouldBe` ["K2004"]

  describe "identifyModule (operator desugar)" $ do
    it "desugars a binary operator to a qualified primitive call (no primitive context needed)" $
      case operatorCall "agent main() -> integer { 1 + 2 }" of
        Just (callee, _) -> calleeQualifiedName callee `shouldBe` Just (ModuleName "primitive", "add")
        Nothing -> expectationFailure "binary operator did not desugar to a call"

    it "passes the operands as left / right arguments" $
      case operatorCall "agent main() -> integer { 1 + 2 }" of
        Just (_, arguments) -> ((.name) <$> arguments) `shouldBe` ["left", "right"]
        Nothing -> expectationFailure "binary operator did not desugar to a call"

    it "desugars a unary operator to a qualified primitive call" $
      case operatorCall "agent main() -> integer { -x }" of
        Just (callee, arguments) -> do
          calleeQualifiedName callee `shouldBe` Just (ModuleName "primitive", "negate")
          ((.name) <$> arguments) `shouldBe` ["value"]
        Nothing -> expectationFailure "unary operator did not desugar to a call"

    it "resolves operators without any import context (self-contained desugar)" $
      diagnosticsOf (identify emptyContext "agent main() -> boolean { (1 + 2) == 3 }") `shouldSatisfy` null

    it "is immune to a user binding that shadows the operator's name" $
      case operatorCall "agent main() -> integer { let add = 5\n 1 + 2 }" of
        Just (callee, _) -> calleeQualifiedName callee `shouldBe` Just (ModuleName "primitive", "add")
        Nothing -> expectationFailure "binary operator did not desugar to a call"

---------------------------------------------------------------------------------------------------
-- Symbol table (LSP visibility + go-to-definition)
---------------------------------------------------------------------------------------------------

symbolTableSpec :: Spec
symbolTableSpec =
  describe "identifyModule (symbol table)" $ do
    it "sees an agent parameter inside its body" $
      namesVisibleAt "agent foo(name: string) -> string {\n  name\n}\n" (Position {line = 2, column = 3})
        `shouldContain` ["name"]

    it "sees a let-binding from later in the same block" $
      namesVisibleAt "agent foo() -> integer {\n  let x = 1\n  x\n}\n" (Position {line = 3, column = 3})
        `shouldContain` ["x"]

    it "does not see a let-binding before its declaration in the same block" $
      namesVisibleAt "agent foo() -> integer {\n  let a = 1\n  let b = 2\n  b\n}\n" (Position {line = 2, column = 3})
        `shouldNotContain` ["a", "b"]

    it "does not see a block-local binding from the top level" $
      namesVisibleAt "agent foo() -> integer {\n  let x = 1\n  x\n}\n" (Position {line = 1, column = 1})
        `shouldNotContain` ["x"]

    it "sees the top-level declarations at the top level" $
      namesVisibleAt "agent foo() -> integer { 1 }\nagent bar() -> integer { 2 }\n" (Position {line = 1, column = 1})
        `shouldSatisfy` (\names -> all (`elem` names) ["foo", "bar"])

    it "sees a generic parameter as a type in its body" $
      typesVisibleAt "agent identity[T](value: T) -> T {\n  value\n}\n" (Position {line = 2, column = 3})
        `shouldContain` ["T"]

    it "returns nothing for a position in no region" $
      namesVisibleAt "agent foo() -> integer { 1 }\n" (Position {line = 99, column = 1})
        `shouldBe` []

    it "records a top-level definition for go-to-definition" $
      definitionSpanOf
        (identifyFull emptyContext "agent foo() -> integer { 1 }\n").symbolTable
        (SymbolVariable (VariableResolutionQualifiedName (QualifiedName (ModuleName "test") "foo")))
        `shouldSatisfy` (/= Nothing)

namesVisibleAt :: Text -> Position -> [Text]
namesVisibleAt source position =
  let visible = scopeAt (identifyFull emptyContext source).symbolTable position
   in Map.keys visible.variableBindings

typesVisibleAt :: Text -> Position -> [Text]
typesVisibleAt source position =
  let visible = scopeAt (identifyFull emptyContext source).symbolTable position
   in Map.keys visible.typeBindings

identifyFull :: ImportContext -> Text -> IdentifiedModule
identifyFull importContext source = fst (identifyModule importContext (ModuleName "test") (fst (parseModule (ModuleName "test") source)))

---------------------------------------------------------------------------------------------------
-- Fixtures and helpers
---------------------------------------------------------------------------------------------------

handlerProgram :: Text
handlerProgram =
  "request tick() -> integer\n\
  \agent main() -> integer {\n\
  \  use handler (var counter = 1) {\n\
  \    request tick() { next counter with { counter = counter + 1 } }\n\
  \  }\n\
  \  tick()\n\
  \}\n"

-- | One @handler@ that handles the same request twice: the second @request tick@ is K2003, the same
-- duplicate-name rule object fields and parameters follow.
duplicateHandlerProgram :: Text
duplicateHandlerProgram =
  "request tick() -> integer\n\
  \agent main() -> integer {\n\
  \  use handler (var counter = 1) {\n\
  \    request tick() { next counter }\n\
  \    request tick() { next counter }\n\
  \  }\n\
  \  tick()\n\
  \}\n"

modifierNonStateProgram :: Text
modifierNonStateProgram =
  "request tick() -> integer\n\
  \agent main() -> integer {\n\
  \  use handler (var counter = 1) {\n\
  \    request tick() { next counter with { bogus = counter } }\n\
  \  }\n\
  \  tick()\n\
  \}\n"

-- | A @for@ nested in a request handler: the @for@'s @then@ clause does @next ... with@ targeting the
-- handler state (the @then@ clause's @next@ binds to the enclosing handler, not the just-finished for).
thenTargetsHandlerProgram :: Text
thenTargetsHandlerProgram =
  "request tick() -> integer\n\
  \agent main() -> integer {\n\
  \  use handler (var counter = 1) {\n\
  \    request tick() {\n\
  \      for (let x in [1]) {\n\
  \        next x\n\
  \      } then (z) {\n\
  \        next counter with { counter = counter + 1 }\n\
  \      }\n\
  \    }\n\
  \  }\n\
  \  tick()\n\
  \}\n"

emptyContext :: ImportContext
emptyContext =
  ImportContext {moduleInterfaces = Map.empty, defaultImports = []}

contextWithLib :: ImportContext
contextWithLib = emptyContext {moduleInterfaces = Map.singleton (ModuleName "lib") (interfaceOf "lib" "agent double(x: integer) -> integer { x }\ndata pair(a: integer)")}

-- | A default-import root @std@ (with a submodule @std.array@) used to exercise the default-import
-- expansion: @std@ and @std.array@ are reachable as the qualifiers @std@ and @array@, while nothing is
-- brought into scope unqualified. (The real default root is @primitive@, but that is a reserved word
-- and so cannot be written as a qualifier in source — see 'Katari.Stdlib'; operators reach it by a
-- directly-constructed reference, not through scope.)
contextWithDefaultImport :: ImportContext
contextWithDefaultImport =
  emptyContext
    { moduleInterfaces =
        Map.fromList
          [ (ModuleName "std", interfaceOf "std" "agent helper(x: integer) -> integer { x }"),
            (ModuleName "std.array", interfaceOf "std.array" "agent range(n: integer) -> integer { n }")
          ],
      defaultImports = [ModuleName "std"]
    }

spanWidth :: SourceSpan -> Int
spanWidth sourceSpan = sourceSpan.end.column - sourceSpan.start.column

interfaceOf :: Text -> Text -> ModuleInterface
interfaceOf moduleName source = scanExports (ModuleName moduleName) (fst (parseModule (ModuleName moduleName) source))

memberVariableOf :: Text -> ModuleInterface -> Maybe VariableResolution
memberVariableOf name interface = Map.lookup name interface.exports >>= (.variable)

memberTypeOf :: Text -> ModuleInterface -> Maybe TypeResolution
memberTypeOf name interface = Map.lookup name interface.exports >>= (.typeLevel)

-- | Parse and identify, returning the identified module with every diagnostic (parse + identify).
identify :: ImportContext -> Text -> (Module Identified, Diagnostics)
identify importContext source =
  let (parsed, parseDiagnostics) = parseModule (ModuleName "test") source
      (identified, identifyDiagnostics) = identifyModule importContext (ModuleName "test") parsed
   in (identified.identifiedAst, parseDiagnostics <> identifyDiagnostics)

moduleOf :: (Module Identified, Diagnostics) -> Module Identified
moduleOf = fst

diagnosticsOf :: (Module Identified, Diagnostics) -> Diagnostics
diagnosticsOf = snd

codesOf :: (Module Identified, Diagnostics) -> [Text]
codesOf = map (compilerErrorCode . (.value)) . toList . snd

agentNamed :: Text -> Module Identified -> Maybe (AgentDeclaration Identified)
agentNamed name module' = listToMaybe [declaration | DeclarationAgent declaration <- module'.declarations, declaration.name == name]

mainReturn :: Module Identified -> Maybe (Expression Identified)
mainReturn module' = agentNamed "main" module' >>= (.body.returnExpression)

mainCallCallee :: Module Identified -> Maybe (Expression Identified)
mainCallCallee module' = case mainReturn module' of
  Just (ExpressionCall call) -> Just call.callee
  _ -> Nothing

-- | Identify @source@ (no import context) and return @main@'s body call: its callee and arguments.
-- Used to inspect what an operator desugared to.
operatorCall :: Text -> Maybe (Expression Identified, [CallArgument Identified])
operatorCall source = case mainReturn (moduleOf (identify emptyContext source)) of
  Just (ExpressionCall call) -> Just (call.callee, call.arguments)
  _ -> Nothing

-- | The @(module, name)@ a qualified-reference callee resolves to, if it is one.
calleeQualifiedName :: Expression Identified -> Maybe (ModuleName, Text)
calleeQualifiedName = \case
  ExpressionQualifiedReference reference -> case reference.variableReference.resolution of
    Just (VariableResolutionQualifiedName qualifiedName) -> Just (qualifiedName.moduleName, qualifiedName.name)
    _ -> Nothing
  _ -> Nothing

isQualifiedReference :: Expression Identified -> Bool
isQualifiedReference = \case
  ExpressionQualifiedReference _ -> True
  _ -> False

isFieldAccess :: Expression Identified -> Bool
isFieldAccess = \case
  ExpressionFieldAccess _ -> True
  _ -> False

environment :: IdentifierEnvironment
environment = IdentifierEnvironment {moduleName = ModuleName "test", moduleInterfaces = Map.empty, scope = emptyScope, stateVariables = Map.empty}

boundX :: VariableResolution
boundX = VariableResolutionLocalVariable (LocalVariableId 7)

someSpan :: SourceSpan
someSpan = SourceSpan {filePath = "m.ktr", start = position, end = position}
  where
    position = Position {line = 1, column = 1}

someError :: CompilerError
someError = CompilerErrorIdentifier (IdentifierErrorUndefinedName UndefinedNameErrorInfo {name = "x"})
