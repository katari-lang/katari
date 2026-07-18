module Katari.LoweringSpec (spec) where

import Data.Foldable (toList)
import Data.Map qualified as Map
import Data.Maybe (fromMaybe, mapMaybe, maybeToList)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import GHC.List (List)
import Katari.Compile (CompileInput (..), CompileResult (..), compile)
import Katari.Data.IR
import Katari.Data.JSONSchema (DescribedSchema (..), JSONSchema (..), ObjectSchema (..))
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Data.QualifiedName (QualifiedName (..))
import Katari.Data.SourceSpan (Located (..))
import Katari.Diagnostics (hasErrors)
import Katari.Error (compilerErrorCode)
import Katari.Primitive (recordMergeLeftLabel, recordMergeRightLabel)
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

  describe "entry privacy (the run-start boundary reads it)" $ do
    it "marks a `private agent`'s entry private while keeping it resolvable as an entry" $ do
      let irModule = loweredTestModule "private agent hidden() -> integer { 1 }"
      entryPrivacy irModule "hidden" `shouldBe` Just True

    it "leaves a plain agent's entry public" $ do
      let irModule = loweredTestModule "agent shown() -> integer { 1 }"
      entryPrivacy irModule "shown" `shouldBe` Just False

    it "keeps a signature-determined callable (a `data` constructor) public" $ do
      let irModule = loweredTestModule "data Pair(left: integer, right: integer)"
      entryPrivacy irModule "Pair" `shouldBe` Just False

  describe "data constructors" $
    it "lowers a `data` declaration to a `BlockConstruct` leaf under its agent wrapper" $ do
      let irModule = loweredTestModule "data Pair(left: integer, right: integer)"
      case entryBlock irModule "Pair" of
        Just (BlockAgent agent) -> blockKind irModule agent.body `shouldBe` Just "construct"
        other -> expectationFailure ("expected a BlockAgent entry, got " <> show other)

  describe "parameter annotations" $ do
    it "overlays an agent parameter's @\"...\" annotation as the property's description" $ do
      let irModule = loweredTestModule "agent greet(@\"The user's name.\" name: string, shout: boolean) -> string { name }"
      case entryBlock irModule "greet" of
        Just (BlockAgent agent) ->
          objectProperties agent.schema.input
            `shouldBe` [ ("name", SchemaDescribed DescribedSchema {description = "The user's name.", schema = SchemaString}),
                         ("shout", SchemaBoolean)
                       ]
        other -> expectationFailure ("expected a BlockAgent entry, got " <> show other)

    it "overlays a request parameter's annotation on its callable input schema" $ do
      let irModule = loweredTestModule "request ask(@\"The question to pose.\" question: string) -> string"
      case entryBlock irModule "ask" of
        Just (BlockAgent agent) ->
          objectProperties agent.schema.input
            `shouldBe` [("question", SchemaDescribed DescribedSchema {description = "The question to pose.", schema = SchemaString})]
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

  describe "the use call-provider (one delegate, the continuation joined with the written arguments)" $ do
    let source =
          "agent supply[R, effect E](base: integer, continuation: agent(value: integer) -> R with E) -> R with E { continuation(value = base) }\n"
            <> "agent run() -> string { let x : integer = use supply(base = 1)\n\"result\" }"
    it "delegates the provider BY NAME, its argument record carrying base and the continuation" $
      delegateArgumentEntriesTo (loweredTestModule source) (testName "supply") `shouldBe` Just ["base", "continuation"]
    it "binds the use binder to the continuation argument's `value` field (not the protocol record)" $
      -- The provider calls the continuation with `{value: A}`; the binder must project `value` out,
      -- or `let x = use p(...)` observes the protocol wrapper instead of the provided value.
      continuationFirstFields (loweredTestModule source) `shouldBe` ["value"]

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

    it "lowers an ambient `request panic(msg: string)` handler to the wired-in `prelude.panic` name" $ do
      let irModule =
            loweredTestModule
              ( "agent f() -> integer {\n"
                  <> "  use handler { request panic(msg: string) { break 0 } }\n"
                  <> "  42\n"
                  <> "}"
              )
      handledRequestNames irModule `shouldContain` [preludeName "panic"]

    it "checks a stdlib throw effect end to end: an unhandled `json.parse` propagates its throw" $
      compileErrorCodes "agent f(t: string) -> unknown { json.parse(text = t) }" `shouldBe` []

    it "discharges a stdlib throw with a handler at the domain error type" $
      compileErrorCodes
        ( "agent f(t: string) -> unknown {\n"
            <> "  use handler { request prelude.throw(error: json.parse_error) -> never { break null } }\n"
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

  describe "finally (arming a finalizer)" $ do
    it "emits an OperationDefer arming the finally body as its own sequence block" $ do
      let irModule = loweredTestModule "agent cleanup() -> integer { 0 }\nagent main() -> integer { finally { cleanup() }\n7 }"
          operations = entryBodyOperations irModule "main"
      case [operation.block | OperationDefer operation <- operations] of
        (deferBlock : _) -> do
          blockKind irModule deferBlock `shouldBe` Just "sequence"
          -- The armed block's operations are the lowered finally body: a delegate to `cleanup`.
          [target | OperationDelegate delegateOperation <- blockOperations irModule deferBlock, CalleeName target <- [delegateOperation.target]]
            `shouldContain` [testName "cleanup"]
        [] -> expectationFailure "expected an OperationDefer in the agent body"

    it "places the defer inside the loop body block when a finally is armed in a for-body" $ do
      let irModule = loweredTestModule "agent main(xs: array[integer]) -> array[integer] { for (x in xs) { finally { let c = 1 }\nnext x } }"
      length [() | OperationDefer _ <- forBodyOperations irModule] `shouldBe` 1

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
      compileErrorCodes "agent f() -> string {\n  http.fetch(url = \"https://x\", method = \"GET\", headers = {}, body = http.text(content = \"\")).body\n}\n" `shouldBe` []

    it "allows a secret header and declassifies the response (the call is impure, so no result lift)" $
      compileErrorCodes "agent f(key: string of private) -> integer {\n  http.fetch(url = \"https://x\", method = \"POST\", headers = { Authorization = key }, body = http.text(content = \"\")).status\n}\n" `shouldBe` []

    it "accepts a secret in the body (a private submission surface toward the destination server)" $
      -- The `body` is a sum; its `text` variant's content is `string of private`, so a secret may be
      -- submitted in a form body (e.g. an OAuth `refresh_token`), exactly like a secret header value.
      compileErrorCodes "agent f(s: string of private) -> integer {\n  http.fetch(url = \"https://x\", method = \"POST\", headers = {}, body = http.text(content = s)).status\n}\n" `shouldBe` []

    it "rejects a secret in the url (the url stays public: it leaks into logs, caches, and referrers)" $
      -- The honest negative that keeps the rule from decaying: the `url` is a public sink even though the
      -- body one argument over is private-capable, so a private value reaching it is still a type error.
      compileErrorCodes "agent f(s: string of private) -> integer {\n  http.fetch(url = s, method = \"GET\", headers = {}, body = http.text(content = \"\")).status\n}\n" `shouldNotBe` []

    it "accepts a `json` body of a value tree (the base64 slot: `unknown` takes records / scalars / files)" $
      -- The `json` variant's `value: unknown of private` takes any value tree; a `file` in it becomes base64
      -- at the send boundary (a runtime concern), and here just a plain record tree confirms the constructor.
      compileErrorCodes "agent f() -> integer {\n  http.fetch(url = \"https://x\", method = \"POST\", headers = {}, body = http.json(value = { note = \"hi\" })).status\n}\n" `shouldBe` []

    it "accepts a `multipart` body of RFC 7578 parts (a named text field)" $
      compileErrorCodes "agent f() -> integer {\n  http.fetch(url = \"https://x\", method = \"POST\", headers = {}, body = http.multipart(parts = [http.multipart_text(name = \"a\", content = \"b\")])).status\n}\n" `shouldBe` []

  -- The post-lowering liveness pass (Katari.Lowering.Drop): a temporary written and last mentioned
  -- within one sequence is released by a `drop` right after that mention; anything a nested block (a
  -- match arm, a local agent's body) still reads must stay bound for the scope-level GC instead.
  describe "drop insertion (the post-lowering liveness pass)" $ do
    let letSource =
          "agent helper(x: integer) -> integer { x }\n"
            <> "agent caller(y: integer) -> integer { let x = helper(x = y)\nhelper(x = x) }"

    it "drops the `let x = f(a)` temporaries — the argument record and the delegate output — once spent" $ do
      let operations = entryBodyOperations (loweredTestModule letSource) "caller"
      case [operation | OperationDelegate operation <- operations] of
        (firstDelegate : _) -> do
          droppedVariables operations `shouldContain` [firstDelegate.argument]
          case firstDelegate.output of
            Just output -> droppedVariables operations `shouldContain` [output]
            Nothing -> expectationFailure "the let-bound delegate has no output"
        [] -> expectationFailure "expected a delegate in the caller body"

    it "the delegate output dies at the bindPattern: a drop listing it directly follows the bind" $ do
      let operations = entryBodyOperations (loweredTestModule letSource) "caller"
      case [ (bindOperation.source, followup)
             | (OperationBindPattern bindOperation, followup) <- adjacentPairs operations
           ] of
        ((source, OperationDrop dropOperation) : _) -> dropOperation.variables `shouldContain` [source]
        other -> expectationFailure ("expected a drop right after the bindPattern, got " <> show other)

    it "keeps the let-bound variable until its last use, then releases it too" $ do
      let operations = entryBodyOperations (loweredTestModule letSource) "caller"
          letBound =
            [ variable
              | OperationBindPattern bindOperation <- operations,
                PatternVariable variable <- [bindOperation.pattern]
            ]
      -- The bound variable is dead after the second call's argument record, so it IS dropped —
      -- the mention-after-drop oracle below guarantees never before a remaining use.
      case letBound of
        [variable] -> droppedVariables operations `shouldContain` [variable]
        other -> expectationFailure ("expected exactly one let-bound variable, got " <> show other)

    it "keeps a variable a nested match arm still reads (the arm runs as its own thread)" $ do
      let operations =
            entryBodyOperations
              (loweredTestModule "agent f(b: boolean) -> integer { let x = 1\nif (b) { x } else { 2 } }")
              "f"
      case [variable | OperationBindPattern bindOperation <- operations, PatternVariable variable <- [bindOperation.pattern]] of
        [variable] -> droppedVariables operations `shouldNotContain` [variable]
        other -> expectationFailure ("expected exactly one let-bound variable, got " <> show other)

    it "keeps a variable a local agent's body captures (read through the closure's scope chain)" $ do
      let operations =
            entryBodyOperations
              (loweredTestModule "agent f() -> integer { let x = 1\nagent g() -> integer { x }\ng() }")
              "f"
      case [variable | OperationBindPattern bindOperation <- operations, PatternVariable variable <- [bindOperation.pattern]] of
        [variable] -> droppedVariables operations `shouldNotContain` [variable]
        other -> expectationFailure ("expected exactly one let-bound variable, got " <> show other)

    it "drops an unread output immediately after its write" $ do
      let operations =
            entryBodyOperations
              (loweredTestModule "agent helper(x: integer) -> integer { x }\nagent caller() -> integer { helper(x = 1)\n2 }")
              "caller"
      case [ (delegateOperation.output, followup)
             | (OperationDelegate delegateOperation, followup) <- adjacentPairs operations
           ] of
        ((Just output, OperationDrop dropOperation) : _) -> dropOperation.variables `shouldContain` [output]
        other -> expectationFailure ("expected a drop right after the unread delegate, got " <> show other)

    it "keeps every lowered module sound: no mention after a drop, no dropped result, no empty drop (stdlib included)" $ do
      let source =
            "data Pair(left: integer, right: integer)\n"
              <> "request tick() -> integer\n"
              <> "agent classify(b: boolean) -> integer { match (b) { case true -> 1\ncase false -> 0 } }\n"
              <> "agent doubles(xs: array[integer]) -> array[integer] { for (x in xs) { next x } }\n"
              <> "agent withHandler() -> integer { let h = handler[integer, all] { request tick() -> integer { next 5 } }\n0 }\n"
              <> "agent caller() -> integer { classify(b = true) }"
          result = compile CompileInput {sources = Map.singleton testModuleName source}
      hasErrors result.diagnostics `shouldBe` False
      [ violation
        | irModule <- Map.elems result.loweredModules,
          sequenceBlock <- allSequences irModule,
          violation <- sequenceDropViolations sequenceBlock
        ]
        `shouldBe` []

  describe "partial application (`_` holes) lowers to a closure" $ do
    let scaleDecl = "agent scale(factor: number, value: number) -> number { factor * value }\n"
        partialSource = scaleDecl <> "agent make_double() -> agent (value: number) -> number { scale(factor = 2.0, value = _) }"

    it "the call site makes a closure of a synthesized `partial` agent instead of delegating" $ do
      let operations = entryBodyOperations (loweredTestModule partialSource) "make_double"
      [() | OperationMakeClosure _ <- operations] `shouldBe` [()]
      [target | OperationDelegate delegateOperation <- operations, CalleeName target <- [delegateOperation.target]] `shouldBe` []

    it "the residual's schema input lists exactly the hole labels" $ do
      case namedAgentBlocks (loweredTestModule partialSource) "partial" of
        [agent] -> objectFieldNames agent.schema.input `shouldBe` ["value"]
        other -> expectationFailure ("expected exactly one synthesized partial agent, got " <> show (length other))

    it "evaluates the supplied arguments in the enclosing scope, in written order, into one captured record" $ do
      let source =
            "agent blend(a: integer, b: integer, c: integer) -> integer { a + b + c }\n"
              <> "agent make_partial() -> agent (b: integer) -> integer { blend(c = 1, b = _, a = 2) }"
          operations = entryBodyOperations (loweredTestModule source) "make_partial"
      case [recordOperation.entries | OperationMakeRecord recordOperation <- operations] of
        [entries] -> map fst entries `shouldBe` ["c", "a"]
        other -> expectationFailure ("expected exactly one captured supplied record, got " <> show other)

    it "the residual body merges the incoming record with the captured one, then delegates to the callee by name" $ do
      let bodyOperations = namedBlockOperations (loweredTestModule partialSource) "partial.body"
          delegated = [target | OperationDelegate delegateOperation <- bodyOperations, CalleeName target <- [delegateOperation.target]]
      delegated `shouldBe` [QualifiedName {moduleName = ModuleName "prelude.record", name = "merge"}, testName "scale"]

    it "maps the merge record's `left` to the residual's incoming record and `right` to the captured supplied one" $ do
      -- The captured (supplied) record wins a shared key, so it must be `merge`'s RIGHT and the
      -- residual's own incoming record its LEFT. Swapping them would let a later caller override a
      -- baked-in supplied argument — a silent soundness hole this pins shut.
      let irModule = loweredTestModule partialSource
          incoming = namedBlockParameter irModule "partial.body" "parameter"
          captured = firstRecordOutput (entryBodyOperations irModule "make_double")
          mergeEntries = case [recordOperation.entries | OperationMakeRecord recordOperation <- namedBlockOperations irModule "partial.body"] of
            (entries : _) -> entries
            [] -> []
      map fst mergeEntries `shouldBe` [recordMergeLeftLabel, recordMergeRightLabel]
      lookup recordMergeLeftLabel mergeEntries `shouldBe` incoming
      lookup recordMergeRightLabel mergeEntries `shouldBe` captured

    it "stamps the call site's inferred generics on the inner delegate" $ do
      let source =
            "agent pick[T](value: T, fallback: T) -> T { value }\n"
              <> "agent make_partial() -> agent (fallback: integer) -> integer { pick(value = 1, fallback = _) }"
      case delegateGenericsTo (loweredTestModule source) (testName "pick") of
        Just [("T", GenericArgumentType schema)] -> schema `shouldBe` SchemaInteger
        other -> expectationFailure ("expected an inferred [T -> integer] on the inner delegate, got " <> show other)

    it "a value callee is captured in the enclosing scope and delegated through `CalleeValue`" $ do
      let source = scaleDecl <> "agent make_double() -> agent (value: number) -> number { let f = scale\nf(factor = 2.0, value = _) }"
          irModule = loweredTestModule source
          bodyOperations = namedBlockOperations irModule "partial.body"
      loadedAgentNames irModule `shouldContain` [testName "scale"]
      [() | OperationDelegate delegateOperation <- bodyOperations, CalleeValue _ <- [delegateOperation.target]] `shouldBe` [()]

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
  entry <- Map.lookup (testName name) irModule.entries
  information <- Map.lookup entry.block irModule.blocks
  pure information.block

-- | The privacy flag the module's entry carries for a top-level callable ('Nothing' when absent).
entryPrivacy :: IRModule -> Text -> Maybe Bool
entryPrivacy irModule name = (.private) <$> Map.lookup (testName name) irModule.entries

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

-- | The labels of the argument record built for the first @delegate@ targeting @name@ (Nothing when
-- no such delegate, or its argument is not a record built in the same sequence).
delegateArgumentEntriesTo :: IRModule -> QualifiedName -> Maybe (List Text)
delegateArgumentEntriesTo irModule name =
  case [ (sequence', operation)
         | information <- Map.elems irModule.blocks,
           BlockSequence sequence' <- [information.block],
           OperationDelegate operation <- sequence'.operations,
           CalleeName target <- [operation.target],
           target == name
       ] of
    ((sequence', operation) : _) ->
      Just
        [ label
          | OperationMakeRecord recordOperation <- sequence'.operations,
            recordOperation.output == operation.argument,
            (label, _) <- recordOperation.entries
        ]
    [] -> Nothing

-- | Every 'BlockAgent' carrying the given debug name (e.g. the synthesized @partial@ agents).
namedAgentBlocks :: IRModule -> Text -> List Agent
namedAgentBlocks irModule label =
  [ agent
    | (blockId, name) <- Map.toList irModule.names,
      name == label,
      Just information <- [Map.lookup blockId irModule.blocks],
      BlockAgent agent <- [information.block]
  ]

-- | The operations of every 'BlockSequence' carrying the given debug name, concatenated.
namedBlockOperations :: IRModule -> Text -> List Operation
namedBlockOperations irModule label =
  concat
    [ sequenceBlock.operations
      | (blockId, name) <- Map.toList irModule.names,
        name == label,
        Just information <- [Map.lookup blockId irModule.blocks],
        BlockSequence sequenceBlock <- [information.block]
    ]

-- | The variable a named block binds under the given parameter key (e.g. a @partial.body@ block's
-- @parameter@ — its incoming argument record). 'Nothing' when no such block, or it lacks that key.
namedBlockParameter :: IRModule -> Text -> Text -> Maybe VariableId
namedBlockParameter irModule label parameterKey =
  case [ information.parameters
         | (blockId, name) <- Map.toList irModule.names,
           name == label,
           Just information <- [Map.lookup blockId irModule.blocks]
       ] of
    (parameters : _) -> Map.lookup parameterKey parameters
    [] -> Nothing

-- | The output variable of the first @make record@ in an operation list ('Nothing' when there is none)
-- — e.g. the captured supplied record a partial application builds in its enclosing scope.
firstRecordOutput :: List Operation -> Maybe VariableId
firstRecordOutput operations =
  case [recordOperation.output | OperationMakeRecord recordOperation <- operations] of
    (output : _) -> Just output
    [] -> Nothing

-- | The field each `use.continuation.body` block projects FIRST (the use binder's `value` read).
continuationFirstFields :: IRModule -> List Text
continuationFirstFields irModule =
  [ operation.field
    | (blockId, label) <- Map.toList irModule.names,
      label == "use.continuation.body",
      Just information <- [Map.lookup blockId irModule.blocks],
      BlockSequence sequence' <- [information.block],
      (OperationGetField operation : _) <- [sequence'.operations]
  ]

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

-- | The operations of the body sequence of the named entry agent.
entryBodyOperations :: IRModule -> Text -> List Operation
entryBodyOperations irModule name = fromMaybe [] $ do
  entry <- entryBlock irModule name
  agent <- case entry of
    BlockAgent agent -> Just agent
    _ -> Nothing
  information <- Map.lookup agent.body irModule.blocks
  case information.block of
    BlockSequence sequenceBlock -> Just sequenceBlock.operations
    _ -> Nothing

-- | The operations of a 'BlockSequence' by id (empty for a missing or non-sequence block).
blockOperations :: IRModule -> BlockId -> List Operation
blockOperations irModule blockId = fromMaybe [] $ do
  information <- Map.lookup blockId irModule.blocks
  case information.block of
    BlockSequence sequenceBlock -> Just sequenceBlock.operations
    _ -> Nothing

-- | The operations of every for-loop's body block in the module.
forBodyOperations :: IRModule -> List Operation
forBodyOperations irModule =
  concat
    [ blockOperations irModule for.body
      | information <- Map.elems irModule.blocks,
        BlockFor for <- [information.block]
    ]

-- | Every variable released by any drop in the operation list.
droppedVariables :: List Operation -> List VariableId
droppedVariables operations = concat [dropOperation.variables | OperationDrop dropOperation <- operations]

-- | Consecutive operation pairs, for "the drop directly follows operation X" assertions.
adjacentPairs :: List Operation -> List (Operation, Operation)
adjacentPairs operations = zip operations (drop 1 operations)

-- | Every sequence block in the module.
allSequences :: IRModule -> List Sequence
allSequences irModule =
  [sequenceBlock | information <- Map.elems irModule.blocks, BlockSequence sequenceBlock <- [information.block]]

-- | The drop-soundness oracle over one sequence, restated independently of the pass: an operation may
-- never mention a variable an earlier drop released, a drop may never release the sequence's own
-- result, and a drop is never empty. Returns a description per violation (so a pass shows as @[]@).
sequenceDropViolations :: Sequence -> List String
sequenceDropViolations sequenceBlock = walk mempty sequenceBlock.operations
  where
    walk :: Set VariableId -> List Operation -> List String
    walk released remaining = case remaining of
      [] ->
        [ "the sequence result " <> show variable <> " was dropped"
          | variable <- maybeToList sequenceBlock.result,
            Set.member variable released
        ]
      (operation : rest) ->
        [ "operation mentions dropped " <> show variable
          | variable <- operationMentions operation,
            Set.member variable released
        ]
          <> ["empty drop operation" | OperationDrop dropOperation <- [operation], null dropOperation.variables]
          <> walk (releaseOf operation <> released) rest
    releaseOf operation = case operation of
      OperationDrop dropOperation -> Set.fromList dropOperation.variables
      _ -> mempty

-- | Every variable an operation reads or writes (a drop's own list is a release, not a mention) — the
-- spec's independent mention walker, kept total over the constructors so it cannot drift silently.
operationMentions :: Operation -> List VariableId
operationMentions = \case
  OperationCall operation -> maybeToList operation.output
  OperationDelegate operation -> calleeVariable operation.target <> (operation.argument : maybeToList operation.output)
  OperationLoadLiteral operation -> [operation.output]
  OperationLoadAgent operation -> [operation.output]
  OperationMakeClosure operation -> [operation.output]
  OperationMakeRecord operation -> map snd operation.entries <> [operation.output]
  OperationMakeTuple operation -> operation.elements <> [operation.output]
  OperationGetField operation -> [operation.source, operation.output]
  OperationBindPattern operation -> operation.source : patternVariables operation.pattern
  OperationApplyGenerics operation -> [operation.source, operation.output]
  OperationExit operation -> [operation.value]
  OperationContinue operation ->
    maybeToList operation.value <> concatMap (\(state, value) -> [state, value]) operation.modifiers
  OperationDrop _ -> []
  -- A defer names only the block to arm; it mentions no variable of the enclosing sequence.
  OperationDefer _ -> []
  where
    calleeVariable = \case
      CalleeName _ -> []
      CalleeValue variable -> [variable]

-- | The variables a pattern binds (every 'PatternVariable' position).
patternVariables :: Pattern -> List VariableId
patternVariables = \case
  PatternAny -> []
  PatternVariable variable -> [variable]
  PatternLiteral _ -> []
  PatternConstructor _ fields -> concatMap (patternVariables . snd) fields
  PatternTuple elements -> concatMap patternVariables elements
  PatternRecord fields -> concatMap (patternVariables . snd) fields
  PatternTypeGuard _ inner -> patternVariables inner

-- | The field names of an object schema (empty for any other schema shape).
objectFieldNames :: JSONSchema -> List Text
objectFieldNames = \case
  SchemaObject objectSchema -> map fst objectSchema.properties
  _ -> []

-- | An object schema's labelled properties, for asserting the description overlay per label.
objectProperties :: JSONSchema -> List (Text, JSONSchema)
objectProperties = \case
  SchemaObject objectSchema -> objectSchema.properties
  _ -> []

-- | Every block id referenced anywhere in the module that has no corresponding block.
danglingReferences :: IRModule -> List BlockId
danglingReferences irModule =
  [blockId | blockId <- referencedBlockIds irModule, not (Map.member blockId irModule.blocks)]

-- | The entry names whose target block is not a 'BlockAgent' (every callable must resolve to one).
nonAgentEntries :: IRModule -> List QualifiedName
nonAgentEntries irModule =
  [ name
    | (name, entry) <- Map.toList irModule.entries,
      maybe True (not . isAgentBlock . (.block)) (Map.lookup entry.block irModule.blocks)
  ]
  where
    isAgentBlock = \case
      BlockAgent _ -> True
      _ -> False

-- | Every block id mentioned by an entry or reachable through a block's structure / operations.
referencedBlockIds :: IRModule -> List BlockId
referencedBlockIds irModule =
  map (.block) (Map.elems irModule.entries) <> concatMap (blockReferences . (.block)) (Map.elems irModule.blocks)

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
  -- A defer arms its block, so that block is reachable through this operation.
  OperationDefer operation -> Just operation.block
  _ -> Nothing

thenReferences :: Maybe ThenClause -> List BlockId
thenReferences = maybe [] (\thenClause -> [thenClause.body])
