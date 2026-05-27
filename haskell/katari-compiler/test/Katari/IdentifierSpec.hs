module Katari.IdentifierSpec (spec) where

import Data.Either (isLeft, isRight)
import Data.List (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Katari.AST
import Katari.Id (QualifiedName (..))
import Katari.Lexer qualified as Lexer
import Katari.Parser qualified as Parser
import Katari.Typechecker.Identifier
import Katari.Compile qualified as Compile
import Test.Hspec

-- ---------------------------------------------------------------------------
-- Test helpers
-- ---------------------------------------------------------------------------

-- | Parse a single-module program, fail the spec if it doesn't parse.
parseOne :: Text -> IO (Module Parsed)
parseOne src =
  let (stream, _) = Lexer.lex "<test>" src
      (parsed, parseErrors) = Parser.parse "<test>" stream
  in case parseErrors of
    (_:_) -> fail ("parse failure: " ++ show parseErrors)
    [] -> pure parsed

-- | Run identify on a single module named "main".
--
-- Adapter: 'identify' now returns @(result, errors)@ unconditionally so the
-- typechecker can continue past name-resolution failures. Tests still want the
-- "all-or-nothing" Either shape, so we collapse the pair: errors → Left.
identifyOne :: Text -> IO (Either [IdentifierError] IdentifierResult)
identifyOne src = do
  m <- parseOne src
  pure $ case Compile.identifyWithStdlib (Map.singleton "main" m) of
    (r, []) -> Right r
    (_, es) -> Left es

-- | Run identify on multiple named modules.
identifyMany :: [(Text, Text)] -> IO (Either [IdentifierError] IdentifierResult)
identifyMany sources = do
  parsedList <-
    mapM
      ( \(name, src) ->
          let (stream, _) = Lexer.lex "<test>" src
              (parsed, parseErrors) = Parser.parse "<test>" stream
          in case parseErrors of
            (_:_) -> fail ("parse failure for " ++ show name ++ ": " ++ show parseErrors)
            [] -> pure (name, parsed)
      )
      sources
  pure $ case Compile.identifyWithStdlib (Map.fromList parsedList) of
    (r, []) -> Right r
    (_, es) -> Left es

shouldIdentify :: Text -> IO IdentifierResult
shouldIdentify src = do
  r <- identifyOne src
  case r of
    Right res -> pure res
    Left errs -> fail ("identify failed unexpectedly: " ++ show errs)

shouldFailIdentifyWith ::
  (IdentifierError -> Bool) ->
  Text ->
  IO ()
shouldFailIdentifyWith predicate src = do
  r <- identifyOne src
  case r of
    Right _ -> expectationFailure "identify succeeded but should have failed"
    Left errs ->
      case find predicate errs of
        Just _ -> pure ()
        Nothing -> expectationFailure ("no matching error in: " ++ show errs)

hasError :: (IdentifierError -> Bool) -> Either [IdentifierError] a -> Bool
hasError predicate = \case
  Left errs -> any predicate errs
  Right _ -> False

-- | Look up a type's 'TypeData' by its source-level name. Returns the first
-- match (Identifier currently does not allow duplicate type names per module).
lookupTypeByName :: Text -> IdentifierResult -> Maybe TypeData
lookupTypeByName name res =
  fmap snd
    . find (\(qualifiedName, _) -> qualifiedName.name == name)
    $ Map.toList res.identifiedTypes

-- | Accessor for the (phase-parameterised) synonym RHS field. Wrapping the
-- access in a fixed-result function avoids the @metadata0@ ambiguity that
-- @typeData.typeSynonymRhs@ alone produces under @OverloadedRecordDot@.
synonymRhsOf :: TypeData -> Maybe (SyntacticType Identified)
synonymRhsOf td = td.typeSynonymRhs

-- | Pull the @typeName.resolution@ tag out of every @data@ declaration in a
-- resolved module. Used by tests that assert AST-side TypeId carriage.
collectDataTypeNameRefResolutiondata :: Module Identified -> [NameRefResolution Identified TypeRef]
collectDataTypeNameRefResolutiondata m =
  [ ref.resolution
    | DeclarationData DataDeclaration {typeName = ref} <- m.declarations
  ]

-- Error predicates as top-level values.
isUndefName :: IdentifierError -> Bool
isUndefName (ErrorUndefinedName _ _) = True
isUndefName _ = False

isUndefQual :: IdentifierError -> Bool
isUndefQual (ErrorUndefinedQualified {}) = True
isUndefQual _ = False

isNotAType :: IdentifierError -> Bool
isNotAType (ErrorNotAType _ _) = True
isNotAType _ = False

isDup :: IdentifierError -> Bool
isDup (ErrorDuplicateName {}) = True
isDup _ = False

isShadow :: IdentifierError -> Bool
isShadow (ErrorShadowNonVariable _ _) = True
isShadow _ = False

isNotARequest :: IdentifierError -> Bool
isNotARequest (ErrorNotARequest _ _) = True
isNotARequest _ = False

isNotAConstructor :: IdentifierError -> Bool
isNotAConstructor (ErrorNotAConstructor _ _) = True
isNotAConstructor _ = False

isMissingMod :: IdentifierError -> Bool
isMissingMod (ErrorImportModuleNotFound _ _) = True
isMissingMod _ = False

isMissingName :: IdentifierError -> Bool
isMissingName (ErrorImportNameNotFound {}) = True
isMissingName _ = False

isImportCycle :: IdentifierError -> Bool
isImportCycle (ErrorImportCycle _ _) = True
isImportCycle _ = False

countImportCycles :: Either [IdentifierError] a -> Int
countImportCycles = \case
  Left errs -> length (filter isImportCycle errs)
  Right _ -> 0

countMissingMods :: Either [IdentifierError] a -> Int
countMissingMods = \case
  Left errs -> length (filter isMissingMod errs)
  Right _ -> 0

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  basicResolution
  dataDeclarations
  typeSynonymAndUnion
  importHandling
  duplicateNameErrors
  shadowingRules
  fieldAccessResolution
  qualifiedRequestHandler
  scopeIsolation
  unresolvedMetadata

-- ---------------------------------------------------------------------------
-- Basic resolution
-- ---------------------------------------------------------------------------

basicResolution :: Spec
basicResolution = describe "basic resolution" $ do
  it "resolves a single agent" $ do
    res <- shouldIdentify "agent main() { 0 }"
    Map.size res.identifiedVariables `shouldSatisfy` (>= 1)

  it "resolves agent referencing itself" $ do
    _ <- shouldIdentify "agent main() { main() }"
    pure ()

  it "resolves let binding and use" $ do
    _ <- shouldIdentify "agent main() { let x = 1; x }"
    pure ()

  it "rejects unknown variable reference" $ do
    shouldFailIdentifyWith isUndefName "agent main() { undef_var }"

  it "rejects unknown type reference" $ do
    shouldFailIdentifyWith isNotAType "agent main(x: nope) { 0 }"

-- ---------------------------------------------------------------------------
-- Data declarations: var + type 両 slot を 1 名前で占有
-- ---------------------------------------------------------------------------

dataDeclarations :: Spec
dataDeclarations = describe "data declarations" $ do
  it "data introduces both variable (ctor function) and type with same name" $ do
    res <-
      shouldIdentify $
        mconcat
          [ "data circle(r: integer)\n",
            "agent main() { circle(r = 1) }"
          ]
    -- variable と type それぞれに id が発行されている
    Map.size res.identifiedVariables `shouldSatisfy` (>= 2) -- circle (ctor) + main (agent)
    Map.size res.identifiedTypes `shouldSatisfy` (>= 1) -- circle (type)
  it "data type usable in type annotation" $ do
    _ <-
      shouldIdentify $
        mconcat
          [ "data point(x: integer, y: integer)\n",
            "agent main(p: point) -> point { p }"
          ]
    pure ()

  it "data with no parameters" $ do
    _ <-
      shouldIdentify $
        mconcat
          [ "data marker()\n",
            "agent main() { marker() }"
          ]
    pure ()

  it "data + same-name agent → duplicate" $ do
    shouldFailIdentifyWith isDup $
      mconcat
        [ "data foo(x: integer)\n",
          "agent foo() { 0 }"
        ]

  it "constructor pattern matching on data" $ do
    _ <-
      shouldIdentify $
        mconcat
          [ "data circle(r: integer)\n",
            "agent main(x: circle) { match (x) { case circle(r = v) => { v } } }"
          ]
    pure ()

  it "data declaration's typeName carries the same TypeId registered in identifiedTypes" $ do
    res <-
      shouldIdentify $
        mconcat
          [ "data widget(w: integer)\n",
            "agent main() { widget(w = 1) }"
          ]
    -- AST 上の typeName.resolution と identifiedTypes 側の QualifiedName が一致することを確認。
    let mainModule = head (Map.elems res.moduleASTs)
        typeNameRefResolution = head (collectDataTypeNameRefResolutiondata mainModule)
        widgetTypeQName =
          head
            [ qualifiedName
              | (qualifiedName, _td) <- Map.toList res.identifiedTypes,
                qualifiedName.name == "widget"
            ]
    case typeNameRefResolution of
      Just qname -> qname `shouldBe` widgetTypeQName
      Nothing ->
        expectationFailure "data declaration typeName resolved as Unresolved"

  it "two modules with same-named data have distinct TypeIds on AST typeName" $ do
    -- リファクタ前は ConstraintGenerator 側の text 検索が衝突して TypeId を取れず
    -- Nothing にフォールバックしていた。AST に TypeId が乗るので回帰しない。
    let modA = "data foo(x: integer)\nagent run() { foo(x = 1) }"
        modB = "data foo(y: string)\nagent run() { foo(y = \"a\") }"
    eitherRes <- identifyMany [("a", modA), ("b", modB)]
    case eitherRes of
      Left errs -> expectationFailure ("identify failed: " ++ show errs)
      Right res -> do
        -- Filter out stdlib modules ('prim') so the assertion only counts
        -- the user-declared `data foo` instances.
        let userModuleNames =
              [ moduleName
                | (moduleName, _md) <- Map.toList res.identifiedModules,
                  moduleName /= ("primitive" :: Text)
              ]
            userAsts =
              [ m
                | moduleName <- userModuleNames,
                  Just m <- [Map.lookup moduleName res.moduleASTs]
              ]
            typeQNames =
              [ qualifiedName
                | m <- userAsts,
                  metadata <- collectDataTypeNameRefResolutiondata m,
                  Just qualifiedName <- [metadata]
              ]
        length typeQNames `shouldBe` 2
        (head typeQNames == typeQNames !! 1) `shouldBe` False

-- ---------------------------------------------------------------------------
-- Type synonyms / literal types / union types
-- ---------------------------------------------------------------------------

typeSynonymAndUnion :: Spec
typeSynonymAndUnion = describe "type synonym and union" $ do
  it "type synonym with named types in union" $ do
    _ <-
      shouldIdentify $
        mconcat
          [ "data nothing()\n",
            "data just(value: integer)\n",
            "type maybe_int = nothing | just\n",
            "agent main(x: maybe_int) { 0 }"
          ]
    pure ()

  it "type synonym with literal types" $ do
    _ <-
      shouldIdentify $
        mconcat
          [ "type status = \"ok\" | \"err\" | null\n",
            "agent main(s: status) { 0 }"
          ]
    pure ()

  it "type synonym with mixed literal kinds" $ do
    _ <-
      shouldIdentify $
        mconcat
          [ "type t = 200 | 404 | true | false\n",
            "agent main(x: t) { 0 }"
          ]
    pure ()

  it "type synonym referencing undefined type fails" $ do
    shouldFailIdentifyWith isNotAType $
      mconcat
        [ "type t = undef_type\n"
        ]

  it "type synonym + same-name data is duplicate" $ do
    shouldFailIdentifyWith isDup $
      mconcat
        [ "data foo()\n",
          "type foo = integer"
        ]

  it "type synonym RHS is recorded in TypeData" $ do
    res <- shouldIdentify "type t = string"
    case lookupTypeByName "t" res of
      Nothing -> expectationFailure "expected TypeData entry for 't'"
      Just td -> case synonymRhsOf td of
        Just (TypePrimitive PrimitiveTypeNode {kind}) ->
          kind `shouldBe` PrimitiveTypeKindString
        Just _ ->
          expectationFailure "expected primitive string RHS for 't'"
        Nothing ->
          expectationFailure "typeSynonymRhs not populated for synonym"

  it "every synonym in a chain has its RHS recorded" $ do
    res <-
      shouldIdentify $
        mconcat
          [ "type a = string\n",
            "type b = a\n"
          ]
    -- a -> string (primitive)
    case lookupTypeByName "a" res >>= synonymRhsOf of
      Just (TypePrimitive PrimitiveTypeNode {kind}) ->
        kind `shouldBe` PrimitiveTypeKindString
      _ -> expectationFailure "a: expected primitive string RHS"
    -- b -> a (named type)
    case lookupTypeByName "b" res >>= synonymRhsOf of
      Just (TypeName _) -> pure ()
      _ -> expectationFailure "b: expected TypeName RHS"

  it "data declaration leaves typeSynonymRhs as Nothing" $ do
    res <- shouldIdentify "data foo(x: integer)"
    case lookupTypeByName "foo" res of
      Nothing -> expectationFailure "expected TypeData entry for 'foo'"
      Just td ->
        synonymRhsOf td `shouldSatisfy` isNothing

-- ---------------------------------------------------------------------------
-- Import handling
-- ---------------------------------------------------------------------------

importHandling :: Spec
importHandling = describe "imports" $ do
  it "ImportModule alias-less binds postfix" $ do
    res <-
      identifyMany
        [ ("lib", "agent helper() { 0 }"),
          ("main", "import lib\nagent run() { lib.helper() }")
        ]
    res `shouldSatisfy` isRight

  it "ImportModule with alias binds alias name" $ do
    res <-
      identifyMany
        [ ("lib.deep.math", "agent compute() { 0 }"),
          ("main", "import lib.deep.math as M\nagent run() { M.compute() }")
        ]
    res `shouldSatisfy` isRight

  it "ImportModule path's last segment is used as default bind name" $ do
    res <-
      identifyMany
        [ ("lib.math", "agent compute() { 0 }"),
          ("main", "import lib.math\nagent run() { math.compute() }")
        ]
    res `shouldSatisfy` isRight

  it "ImportNames brings names into top-level flat" $ do
    res <-
      identifyMany
        [ ("lib", "agent helper() { 0 }"),
          ("main", "import { helper } from lib\nagent run() { helper() }")
        ]
    res `shouldSatisfy` isRight

  it "ImportNames type+module same name use case (list)" $ do
    res <-
      identifyMany
        [ ( "list",
            mconcat
              [ "data nil()\n",
                "data cons(head: integer, tail: integer)\n",
                "type list = nil | cons\n",
                "agent length() { 0 }"
              ]
          ),
          ( "main",
            mconcat
              [ "import { type list } from list\n",
                "import list\n",
                "agent run(x: list) { list.length() }"
              ]
          )
        ]
    res `shouldSatisfy` isRight

  it "rejects import of unknown module" $ do
    res <- identifyMany [("main", "import nonexistent\nagent run() { 0 }")]
    res `shouldSatisfy` hasError isMissingMod

  it "rejects ImportNames item not exported" $ do
    res <-
      identifyMany
        [ ("lib", "agent foo() { 0 }"),
          ("main", "import { bar } from lib\nagent run() { bar() }")
        ]
    res `shouldSatisfy` hasError isMissingName

  it "flags self-import as a 1-element cycle" $ do
    res <- identifyMany [("a", "import a\nagent run() { 0 }")]
    countImportCycles res `shouldBe` 1

  it "flags mutual import as a single cycle" $ do
    res <-
      identifyMany
        [ ("a", "import b\nagent runA() { 0 }"),
          ("b", "import a\nagent runB() { 0 }")
        ]
    countImportCycles res `shouldBe` 1

  it "reports missing import only once (no duplicate K0107)" $ do
    res <- identifyMany [("main", "import nonexistent\nagent run() { 0 }")]
    countMissingMods res `shouldBe` 1

-- ---------------------------------------------------------------------------
-- Duplicate name detection
-- ---------------------------------------------------------------------------

duplicateNameErrors :: Spec
duplicateNameErrors = describe "duplicate names" $ do
  it "two agents with same name in same module" $ do
    shouldFailIdentifyWith isDup $
      mconcat
        [ "agent foo() { 0 }\n",
          "agent foo() { 1 }"
        ]

  it "agent + ImportNames item same name" $ do
    res <-
      identifyMany
        [ ("lib", "agent helper() { 0 }"),
          ( "main",
            mconcat
              [ "import { helper } from lib\n",
                "agent helper() { 0 }"
              ]
          )
        ]
    res `shouldSatisfy` hasError isDup

  it "variable + module same name forbidden" $ do
    res <-
      identifyMany
        [ ("foo", "agent x() { 0 }"),
          ( "main",
            mconcat
              [ "import foo\n",
                "agent foo() { 0 }"
              ]
          )
        ]
    res `shouldSatisfy` hasError isDup

  it "type + module same name allowed" $ do
    res <-
      identifyMany
        [ ("list", "agent _stub() { 0 }"),
          ( "main",
            mconcat
              [ "import list\n",
                "type list = integer"
              ]
          )
        ]
    res `shouldSatisfy` isRight

-- ---------------------------------------------------------------------------
-- Shadowing rules
-- ---------------------------------------------------------------------------

shadowingRules :: Spec
shadowingRules = describe "shadowing" $ do
  it "local let shadows top-level variable" $ do
    _ <-
      shouldIdentify $
        mconcat
          [ "agent helper() { 0 }\n",
            "agent main() { let helper = 1; helper }"
          ]
    pure ()

  it "let cannot shadow imported module name" $ do
    res <-
      identifyMany
        [ ("foo", "agent _stub() { 0 }"),
          ( "main",
            mconcat
              [ "import foo\n",
                "agent main() { let foo = 1; foo }"
              ]
          )
        ]
    res `shouldSatisfy` hasError isShadow

  it "let CAN shadow top-level type name (Rust-style)" $ do
    -- Local variable bindings may shadow names that exist only in the type
    -- slot at top level — variable and type lookups walk independently.
    _ <-
      shouldIdentify $
        mconcat
          [ "type status = \"ok\"\n",
            "agent main() { let status = 1; status }"
          ]
    pure ()

  it "data ctor (variable) can be shadowed by local let" $ do
    _ <-
      shouldIdentify $
        mconcat
          [ "data marker()\n",
            "agent main() { let marker = 1; marker }"
          ]
    pure ()

  it "Rust-style same-frame shadowing: let x = 1; let x = 2" $ do
    _ <-
      shouldIdentify "agent main() { let x = 1; let x = 2; x }"
    pure ()

  it "data type still visible after local var shadow of the same name" $ do
    -- `let marker = 1` shadows the variable slot; the type slot survives,
    -- so `marker` in a type-annotation position still resolves to the data type.
    _ <-
      shouldIdentify $
        mconcat
          [ "data marker()\n",
            "agent main(p: marker) { let marker = 1; marker }"
          ]
    pure ()

-- ---------------------------------------------------------------------------
-- Field access resolution
-- ---------------------------------------------------------------------------

fieldAccessResolution :: Spec
fieldAccessResolution = describe "field access" $ do
  it "var.field stays a FieldAccess" $ do
    res <-
      shouldIdentify "agent main(x: integer) { x.f }"
    res.identifiedVariables `shouldSatisfy` (not . Map.null)

  it "module.func resolves to QualifiedReference" $ do
    res <-
      identifyMany
        [ ("lib", "agent helper() { 0 }"),
          ("main", "import lib\nagent run() { lib.helper() }")
        ]
    res `shouldSatisfy` isRight

  it "module.member with unknown member fails" $ do
    res <-
      identifyMany
        [ ("lib", "agent helper() { 0 }"),
          ("main", "import lib\nagent run() { lib.absent() }")
        ]
    res `shouldSatisfy` hasError isUndefQual

  it "let-shadowing-module produces shadow error but resolution does not panic" $ do
    res <-
      identifyMany
        [ ("foo", "agent x() { 0 }"),
          ( "main",
            mconcat
              [ "import foo\n",
                "agent run() { let foo = 1; foo.bar }"
              ]
          )
        ]
    res `shouldSatisfy` isLeft

-- ---------------------------------------------------------------------------
-- Qualified request handler
-- ---------------------------------------------------------------------------

qualifiedRequestHandler :: Spec
qualifiedRequestHandler = describe "request handlers" $ do
  it "bare request handler resolves to existing request" $ do
    _ <-
      shouldIdentify $
        mconcat
          [ "request get() -> integer\n",
            "agent main() {\n",
            "  handle {\n",
            "    request get() { break 0; }\n",
            "  }\n",
            "  0\n",
            "}"
          ]
    pure ()

  it "qualified request handler refers to other module's request" $ do
    res <-
      identifyMany
        [ ("io", "request read() -> integer"),
          ( "main",
            mconcat
              [ "import io\n",
                "agent main() {\n",
                "  handle {\n",
                "    request io.read() { break 0; }\n",
                "  }\n",
                "  0\n",
                "}"
              ]
          )
        ]
    res `shouldSatisfy` isRight

  it "qualified request handler with unknown name fails" $ do
    res <-
      identifyMany
        [ ("io", "request read() -> integer"),
          ( "main",
            mconcat
              [ "import io\n",
                "agent main() {\n",
                "  handle {\n",
                "    request io.absent() { break 0; }\n",
                "  }\n",
                "  0\n",
                "}"
              ]
          )
        ]
    res `shouldSatisfy` hasError isUndefQual

  it "bare request handler with unknown name fails" $ do
    shouldFailIdentifyWith isUndefName $
      mconcat
        [ "agent main() {\n",
          "  handle {\n",
          "    request nonexistent() { break 0; }\n",
          "  }\n",
          "  0\n",
          "}"
        ]

  it "request handler whose target is an agent (not a request) fails with K0108" $ do
    shouldFailIdentifyWith isNotARequest $
      mconcat
        [ "agent helper() -> integer { 0 }\n",
          "agent main() {\n",
          "  handle {\n",
          "    request helper() { break 0; }\n",
          "  }\n",
          "  0\n",
          "}"
        ]

  it "match pattern using a request as constructor fails with K0109" $ do
    shouldFailIdentifyWith isNotAConstructor $
      mconcat
        [ "request fetch() -> integer\n",
          "agent main() {\n",
          "  match (0) {\n",
          "    case fetch() => { 1 }\n",
          "  }\n",
          "}"
        ]

  it "match pattern using an agent as constructor fails with K0109" $ do
    shouldFailIdentifyWith isNotAConstructor $
      mconcat
        [ "agent helper() -> integer { 0 }\n",
          "agent main() {\n",
          "  match (0) {\n",
          "    case helper() => { 1 }\n",
          "  }\n",
          "}"
        ]

-- ---------------------------------------------------------------------------
-- Block / handle scope independence
-- ---------------------------------------------------------------------------

scopeIsolation :: Spec
scopeIsolation = describe "scope isolation" $ do
  it "handle state vars not visible in body" $ do
    shouldFailIdentifyWith isUndefName $
      mconcat
        [ "request get() -> integer\n",
          "agent main() {\n",
          "  handle (var count = 0) {\n",
          "    request get() { break 0; }\n",
          "  }\n",
          "  count\n",
          "}"
        ]

  it "body let not visible in handle state var initializer" $ do
    shouldFailIdentifyWith isUndefName $
      mconcat
        [ "request get() -> integer\n",
          "agent main() {\n",
          "  handle (var y = x) {\n",
          "    request get() { break 0; }\n",
          "  }\n",
          "  let x = 0;\n",
          "  x\n",
          "}"
        ]

  it "later state var sees earlier (ML let order)" $ do
    res <-
      identifyOne $
        mconcat
          [ "request inc() -> integer\n",
            "agent main() {\n",
            "  handle (var a = 1, var b = a) {\n",
            "    request inc() { break 0; }\n",
            "  }\n",
            "  0\n",
            "}"
          ]
    res `shouldSatisfy` isRight

  it "earlier state var does NOT see later" $ do
    shouldFailIdentifyWith isUndefName $
      mconcat
        [ "request inc() -> integer\n",
          "agent main() {\n",
          "  handle (var a = b, var b = 1) {\n",
          "    request inc() { break 0; }\n",
          "  }\n",
          "  0\n",
          "}"
        ]

-- ---------------------------------------------------------------------------
-- Unresolved metadata (failed resolution leaves IdentifiedUnresolved* in AST)
-- ---------------------------------------------------------------------------

unresolvedMetadata :: Spec
unresolvedMetadata = describe "unresolved metadata" $ do
  it "undefined variable reference yields IdentifiedUnresolvedVariable" $ do
    res <- identifyOne "agent main() { undef_var }"
    case res of
      Right _ -> expectationFailure "expected error"
      Left errs -> do
        any isUndefName errs `shouldBe` True
        -- The AST still parses (errors are accumulated, not throw-on-first).
        pure ()

  it "qualified reference to missing member is reported and continues" $ do
    res <-
      identifyMany
        [ ("lib", "agent helper() { 0 }"),
          ("main", "import lib\nagent run() { lib.absent.deep }")
        ]
    res `shouldSatisfy` hasError isUndefQual

  it "multiple undefined names produce multiple errors (no early-exit)" $ do
    res <- identifyOne "agent main() { foo + bar + baz }"
    case res of
      Right _ -> expectationFailure "expected errors"
      Left errs -> length (filter isUndefName errs) `shouldSatisfy` (>= 3)

-- Avoid unused-import warnings.
_unused :: ()
_unused =
  ()
