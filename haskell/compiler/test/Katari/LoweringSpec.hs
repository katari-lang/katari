module Katari.LoweringSpec (spec) where

import Data.Foldable (toList)
import Data.Map qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import GHC.List (List)
import Katari.Compile (CompileInput (..), CompileResult (..), compile)
import Katari.Data.IR
import Katari.Data.JSONSchema (JSONSchema (..), ObjectSchema (..))
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Data.QualifiedName (QualifiedName (..))
import Katari.Data.SourceSpan (Located (..))
import Katari.Diagnostics (hasErrors)
import Katari.Error (compilerErrorCode)
import Test.Hspec

spec :: Spec
spec = describe "lowerModule (via compile)" $ do
  describe "a trivial agent" $ do
    it "compiles without errors and exposes the agent as an entry" $ do
      let irModule = loweredTestModule "agent identity(x: integer) -> integer { x }"
      Map.keys irModule.entries `shouldBe` [testName "identity"]

    it "lowers the entry to a `BlockAgent` whose body is a `BlockSequence`" $ do
      let irModule = loweredTestModule "agent identity(x: integer) -> integer { x }"
      case entryBlock irModule "identity" of
        Just (BlockAgent agent) -> blockKind irModule agent.body `shouldBe` Just "sequence"
        other -> expectationFailure ("expected a BlockAgent entry, got " <> show other)

    it "builds the agent's input/output schema from its type" $ do
      let irModule = loweredTestModule "agent identity(x: integer) -> integer { x }"
      case entryBlock irModule "identity" of
        Just (BlockAgent agent) -> do
          objectFieldNames agent.schema.input `shouldBe` ["x"]
          agent.schema.output `shouldBe` SchemaInteger
        other -> expectationFailure ("expected a BlockAgent entry, got " <> show other)

  describe "data constructors" $
    it "lowers a `data` declaration to a `BlockConstruct` leaf under its agent wrapper" $ do
      let irModule = loweredTestModule "data Pair(left: integer, right: integer)"
      case entryBlock irModule "Pair" of
        Just (BlockAgent agent) -> blockKind irModule agent.body `shouldBe` Just "construct"
        other -> expectationFailure ("expected a BlockAgent entry, got " <> show other)

  describe "calls and references" $ do
    it "lowers a call to a top-level agent to a delegation that names it" $ do
      let irModule =
            loweredTestModule
              "agent helper(x: integer) -> integer { x }\nagent caller(y: integer) -> integer { helper(x = y) }"
      calleeNames irModule `shouldContain` [testName "helper"]

    it "materializes a top-level agent used as a value with `loadAgent`" $ do
      let irModule =
            loweredTestModule
              "agent identity(x: integer) -> integer { x }\nagent useValue() -> agent (x: integer) -> integer { identity }"
      loadedAgentNames irModule `shouldContain` [testName "identity"]

    it "stamps an INFERRED generic instantiation onto the delegate as a runtime schema" $ do
      let irModule =
            loweredTestModule
              "agent pick[T](x: T) -> T { x }\nagent caller() -> integer { pick(x = 1) }"
      case delegateGenericsTo irModule (testName "pick") of
        Just [("T", GenericArgumentType schema)] -> schema `shouldBe` SchemaInteger
        other -> expectationFailure ("expected an inferred [T -> integer] on the delegate, got " <> show other)

    it "leaves a non-generic call's delegate without generics" $ do
      let irModule =
            loweredTestModule
              "agent helper(x: integer) -> integer { x }\nagent caller(y: integer) -> integer { helper(x = y) }"
      delegateGenericsTo irModule (testName "helper") `shouldBe` Just []

  -- The typed error model: `prelude.throw` is an ordinary generic request, so a raise lowers to a
  -- request leaf and a handler to a handle node carrying the qualified name — the runtime matches
  -- handlers by exactly this name (the payload type is erased; the payload value carries its ctor tag).
  describe "the throw error model (prelude.throw)" $ do
    it "lowers a raise of `prelude.throw` to a delegate naming it (the request wrapper lives in the prelude)" $ do
      let irModule =
            loweredTestModule
              "data oops(message: string)\nagent boom() -> integer { prelude.throw(error = oops(message = \"x\")) }"
      calleeNames irModule `shouldContain` [preludeName "throw"]

    it "lowers a `prelude.throw` handler with the qualified name on the handler entry" $ do
      let irModule =
            loweredTestModule
              ( "data oops(message: string)\n"
                  <> "agent f() -> integer {\n"
                  <> "  use handler { request prelude.throw(error: oops) -> never { break 0 } }\n"
                  <> "  prelude.throw(error = oops(message = \"x\"))\n"
                  <> "}"
              )
      handledRequestNames irModule `shouldContain` [preludeName "throw"]

    it "checks a stdlib throw effect end to end: an unhandled `json.parse` propagates its throw" $
      compileErrorCodes "agent f(t: string) -> json.json { json.parse(text = t) }" `shouldBe` []

    it "discharges a stdlib throw with a handler at the domain error type" $
      compileErrorCodes
        ( "agent f(t: string) -> json.json {\n"
            <> "  use handler { request prelude.throw(error: json.parse_error) -> never { break json.json_null() } }\n"
            <> "  json.parse(text = t)\n"
            <> "}"
        )
        `shouldBe` []

  describe "control-flow constructs" $ do
    it "lowers `if` to a match structural node" $
      shouldLowerWithNode "agent pick(b: boolean) -> integer { if (b) { 1 } else { 2 } }" "match"

    it "lowers `match` to a match structural node" $
      shouldLowerWithNode "agent classify(b: boolean) -> integer { match (b) { case true -> 1\ncase false -> 0 } }" "match"

    it "lowers `for` to a for structural node" $
      shouldLowerWithNode "agent doubles(xs: array[integer]) -> array[integer] { for (x in xs) { next x } }" "for"

    it "lowers a handler expression to a handle structural node" $
      shouldLowerWithNode
        "request tick() -> integer\nagent run() -> integer { let h = handler[integer, all] { request tick() -> integer { next 5 } }\n0 }"
        "handle"

  describe "structural soundness" $
    it "every referenced block id exists and every entry resolves to an agent" $ do
      let source =
            "data Pair(left: integer, right: integer)\n"
              <> "request tick() -> integer\n"
              <> "agent classify(b: boolean) -> integer { match (b) { case true -> 1\ncase false -> 0 } }\n"
              <> "agent doubles(xs: array[integer]) -> array[integer] { for (x in xs) { next x } }\n"
              <> "agent withHandler() -> integer { let h = handler[integer, all] { request tick() -> integer { next 5 } }\n0 }\n"
              <> "agent caller() -> integer { classify(b = true) }"
          irModule = loweredTestModule source
      danglingReferences irModule `shouldBe` []
      nonAgentEntries irModule `shouldBe` []

  describe "the env stdlib (primitive.env)" $ do
    it "types `env.get_secret` as a `string of private` (assignable to a private return)" $
      compileErrorCodes "agent f() -> string of private { env.get_secret(key = \"K\") }" `shouldBe` []

    it "rejects leaking a secret into a public `string` return (the secret-flow invariant)" $
      compileErrorCodes "agent f() -> string { env.get_secret(key = \"K\") }" `shouldNotBe` []

    it "types `env.get_all` as a `record[string]`" $
      compileErrorCodes "agent f() -> record[string] { env.get_all() }" `shouldBe` []

  describe "record literals" $ do
    it "accepts a string-literal key an identifier cannot spell" $
      compileErrorCodes "agent f() -> record[string] { { \"Content-Type\" = \"json\" } }" `shouldBe` []

    it "a closed record literal is a subtype of a homogeneous record[V]" $
      compileErrorCodes "agent f() -> record[string] { { a = \"x\", b = \"y\" } }" `shouldBe` []

    it "a literal field's privacy flows into the record[V] element (public <: private)" $
      compileErrorCodes "agent f(s: string of private) -> record[string of private] { { auth = s, accept = \"*\" } }" `shouldBe` []

  describe "the http stdlib (primitive.http)" $ do
    it "types `http.fetch` as an effect returning { status: integer, body: string }" $
      compileErrorCodes "agent f() -> string {\n  http.fetch(url = \"https://x\", method = \"GET\", headers = {}, body = \"\").body\n}\n" `shouldBe` []

    it "allows a secret header and declassifies the response (the call is impure, so no result lift)" $
      compileErrorCodes "agent f(key: string of private) -> integer {\n  http.fetch(url = \"https://x\", method = \"POST\", headers = { Authorization = key }, body = \"\").status\n}\n" `shouldBe` []

    it "rejects a secret in the body (a secret must not be sent outbound)" $
      compileErrorCodes "agent f(s: string of private) -> integer {\n  http.fetch(url = \"https://x\", method = \"POST\", headers = {}, body = s).status\n}\n" `shouldNotBe` []

    it "rejects a secret in the url (only header values may be secret)" $
      compileErrorCodes "agent f(s: string of private) -> integer {\n  http.fetch(url = s, method = \"GET\", headers = {}, body = \"\").status\n}\n" `shouldNotBe` []

  describe "the io effect (external calls are impure)" $ do
    let ext = "external agent fetch(headers: record[string of private], body: string) -> { status: integer, body: string }\n"
    it "declassifies an external call's result (impure → no pure-call lift, so a secret header gives a public result)" $
      compileErrorCodes (ext <> "agent f(key: string of private) -> integer { fetch(headers = { Authorization = key }, body = \"\").status }\n") `shouldBe` []

    it "rejects a secret in a public parameter of an external (a secret must not flow outbound)" $
      compileErrorCodes (ext <> "agent f(s: string of private) -> integer { fetch(headers = {}, body = s).status }\n") `shouldNotBe` []

    it "infers and propagates io — a caller needs no effect annotation" $
      compileErrorCodes (ext <> "agent f() -> integer { fetch(headers = {}, body = \"\").status }\n") `shouldBe` []

------------------------------------------------------------------------------------------------
-- Driver
------------------------------------------------------------------------------------------------

testModuleName :: ModuleName
testModuleName = ModuleName "test"

testName :: Text -> QualifiedName
testName name = QualifiedName {moduleName = testModuleName, name = name}

-- | The error codes of every diagnostic a single-module @test@ program emits through the whole pipeline
-- (stdlib spliced in). @== []@ asserts a clean compile; @shouldNotBe []@ asserts it was rejected.
compileErrorCodes :: Text -> List Text
compileErrorCodes source =
  let result = compile CompileInput {sources = Map.singleton testModuleName source}
   in [compilerErrorCode located.value | located <- toList result.diagnostics]

-- | Compile a single-module @test@ program through the whole pipeline (stdlib spliced in) and return
-- its lowered IR, failing loudly if any phase reported an error.
loweredTestModule :: Text -> IRModule
loweredTestModule source =
  let result = compile CompileInput {sources = Map.singleton testModuleName source}
   in if hasErrors result.diagnostics
        then error ("compile reported errors: " <> show source)
        else fromMaybe (error "no lowered `test` module") (Map.lookup testModuleName result.loweredModules)

shouldLowerWithNode :: Text -> Text -> Expectation
shouldLowerWithNode source nodeKind =
  blockKinds (loweredTestModule source) `shouldContain` [nodeKind]

------------------------------------------------------------------------------------------------
-- IR inspection helpers
------------------------------------------------------------------------------------------------

entryBlock :: IRModule -> Text -> Maybe Block
entryBlock irModule name = do
  blockId <- Map.lookup (testName name) irModule.entries
  information <- Map.lookup blockId irModule.blocks
  pure information.block

blockKind :: IRModule -> BlockId -> Maybe Text
blockKind irModule blockId = blockKindOf . (.block) <$> Map.lookup blockId irModule.blocks

blockKinds :: IRModule -> List Text
blockKinds irModule = [blockKindOf information.block | information <- Map.elems irModule.blocks]

blockKindOf :: Block -> Text
blockKindOf = \case
  BlockAgent _ -> "agent"
  BlockSequence _ -> "sequence"
  BlockPrimitive _ -> "primitive"
  BlockConstruct _ -> "construct"
  BlockRequest _ -> "request"
  BlockExternal _ -> "external"
  BlockMatch _ -> "match"
  BlockFor _ -> "for"
  BlockHandle _ -> "handle"
  BlockParallel _ -> "parallel"

-- | The names every @delegate@ to a 'CalleeName' targets, across the module.
calleeNames :: IRModule -> List QualifiedName
calleeNames irModule =
  [ name
    | information <- Map.elems irModule.blocks,
      BlockSequence sequence' <- [information.block],
      OperationDelegate operation <- sequence'.operations,
      CalleeName name <- [operation.target]
  ]

-- | The generics stamped on the first @delegate@ targeting @name@ (Nothing when no such delegate).
delegateGenericsTo :: IRModule -> QualifiedName -> Maybe (List (Text, GenericArgumentSchema))
delegateGenericsTo irModule name =
  case [ operation.generics
         | information <- Map.elems irModule.blocks,
           BlockSequence sequence' <- [information.block],
           OperationDelegate operation <- sequence'.operations,
           CalleeName target <- [operation.target],
           target == name
       ] of
    (generics : _) -> Just generics
    [] -> Nothing

-- | The request names every handle node's handlers match, across the module.
handledRequestNames :: IRModule -> List QualifiedName
handledRequestNames irModule =
  [ handler.request
    | information <- Map.elems irModule.blocks,
      BlockHandle handle <- [information.block],
      handler <- handle.handlers
  ]

-- | A prelude root member's qualified name (the wired-in stdlib root module).
preludeName :: Text -> QualifiedName
preludeName name = QualifiedName {moduleName = ModuleName "prelude", name = name}

-- | The names every 'OperationLoadAgent' materialises.
loadedAgentNames :: IRModule -> List QualifiedName
loadedAgentNames irModule =
  [ operation.name
    | information <- Map.elems irModule.blocks,
      BlockSequence sequence' <- [information.block],
      OperationLoadAgent operation <- sequence'.operations
  ]

-- | The field names of an object schema (empty for any other schema shape).
objectFieldNames :: JSONSchema -> List Text
objectFieldNames = \case
  SchemaObject objectSchema -> map fst objectSchema.properties
  _ -> []

-- | Every block id referenced anywhere in the module that has no corresponding block.
danglingReferences :: IRModule -> List BlockId
danglingReferences irModule =
  [blockId | blockId <- referencedBlockIds irModule, not (Map.member blockId irModule.blocks)]

-- | The entry names whose target block is not a 'BlockAgent' (every callable must resolve to one).
nonAgentEntries :: IRModule -> List QualifiedName
nonAgentEntries irModule =
  [ name
    | (name, blockId) <- Map.toList irModule.entries,
      maybe True (not . isAgentBlock . (.block)) (Map.lookup blockId irModule.blocks)
  ]
  where
    isAgentBlock = \case
      BlockAgent _ -> True
      _ -> False

-- | Every block id mentioned by an entry or reachable through a block's structure / operations.
referencedBlockIds :: IRModule -> List BlockId
referencedBlockIds irModule =
  Map.elems irModule.entries <> concatMap (blockReferences . (.block)) (Map.elems irModule.blocks)

blockReferences :: Block -> List BlockId
blockReferences = \case
  BlockAgent agent -> [agent.body]
  BlockSequence sequence' -> mapMaybe operationReference sequence'.operations
  BlockPrimitive _ -> []
  BlockConstruct _ -> []
  BlockRequest _ -> []
  BlockExternal _ -> []
  BlockMatch match -> [arm.body | arm <- match.arms] <> maybe [] pure match.fallback
  BlockFor for -> for.body : thenReferences for.thenClause
  BlockHandle handle -> handle.body : ([handler.body | handler <- handle.handlers] <> thenReferences handle.thenClause)
  BlockParallel parallelBlock -> parallelBlock.elements

operationReference :: Operation -> Maybe BlockId
operationReference = \case
  OperationCall operation -> Just operation.target
  OperationMakeClosure operation -> Just operation.agent
  _ -> Nothing

thenReferences :: Maybe ThenClause -> List BlockId
thenReferences = maybe [] (\thenClause -> [thenClause.body])
