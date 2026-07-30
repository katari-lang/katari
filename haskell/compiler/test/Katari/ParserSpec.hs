module Katari.ParserSpec (spec) where

import Data.Foldable (toList)
import Data.Maybe (isJust)
import Data.Text (Text)
import Katari.Data.AST
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Data.SourceSpan (Located (..))
import Katari.Error (compilerErrorCode)
import Katari.Parser (parseModule)
import Test.Hspec

-- | Parse, asserting there were no diagnostics, and hand back the module.
parseClean :: Text -> IO (Module Parsed)
parseClean source = do
  let (module', diagnostics) = parseModule (ModuleName "test") source
  diagnostics `shouldSatisfy` null
  pure module'

shouldFail :: Text -> Expectation
shouldFail source = snd (parseModule (ModuleName "test") source) `shouldNotSatisfy` null

-- | The diagnostic codes emitted while parsing @source@.
codesOf :: Text -> [Text]
codesOf source = [compilerErrorCode located.value | located <- toList (snd (parseModule (ModuleName "test") source))]

-- | The single agent declaration's body block, or a test failure.
soleAgentBody :: Module Parsed -> IO (Block Parsed)
soleAgentBody module' = case module'.declarations of
  [DeclarationAgent agent] -> pure agent.body
  _ -> expectationFailure "expected exactly one agent declaration" >> error "unreachable"

spec :: Spec
spec = do
  describe "declarations" $ do
    it "parses a hello-world agent" $ do
      module' <- parseClean "agent main() -> string { \"hello, world\" }"
      case module'.declarations of
        [DeclarationAgent agent] -> do
          agent.name `shouldBe` "main"
          agent.private `shouldBe` False
        _ -> expectationFailure "expected one agent"

    it "keeps a doc annotation on the declaration" $ do
      module' <- parseClean "@\"greeting\"\nagent main() -> string { \"hi\" }"
      case module'.declarations of
        [DeclarationAgent agent] -> agent.annotation `shouldBe` Just "greeting"
        _ -> expectationFailure "expected one agent"

    it "parses a private agent" $ do
      module' <- parseClean "private agent secret() -> integer { 1 }"
      case module'.declarations of
        [DeclarationAgent agent] -> agent.private `shouldBe` True
        _ -> expectationFailure "expected one agent"

    it "parses parameters, generics, return type and effects" $ do
      module' <- parseClean "agent run[T]() -> integer with tick { 1 }"
      case module'.declarations of
        [DeclarationAgent agent] -> do
          length agent.genericParameters `shouldBe` 1
          agent.effects `shouldSatisfy` (/= Nothing)
        _ -> expectationFailure "expected one agent"

    it "parses an agent parameter written as label => pattern" $ do
      module' <- parseClean "agent coord(p => pt: point) -> integer { 1 }"
      case module'.declarations of
        [DeclarationAgent agent] -> case agent.parameters of
          [binding] -> do
            binding.name `shouldBe` "p"
            case binding.binder of
              BindDestructure (PatternVariable variable) -> variable.name `shouldBe` "pt"
              _ -> expectationFailure "expected a destructure-to-variable binder"
          _ -> expectationFailure "expected one parameter"
        _ -> expectationFailure "expected one agent"

    it "parses a generic parameter with an extends bound" $ do
      module' <- parseClean "agent identity[T extends integer](x: T) -> T { x }"
      case module'.declarations of
        [DeclarationAgent agent] -> case agent.genericParameters of
          [parameter] -> parameter.upperBound `shouldSatisfy` (/= Nothing)
          _ -> expectationFailure "expected one generic parameter"
        _ -> expectationFailure "expected one agent"

    it "parses a request declaration" $ do
      module' <- parseClean "request bump(n: integer) -> integer"
      case module'.declarations of
        [DeclarationRequest request] -> do
          request.name `shouldBe` "bump"
          length request.parameters `shouldBe` 1
        _ -> expectationFailure "expected one request"

    it "parses an external agent with a function-typed parameter" $ do
      module' <- parseClean "external agent cron(callback: agent () -> null with scheduled) -> null"
      case module'.declarations of
        [DeclarationExternalAgent external] -> external.name `shouldBe` "cron"
        _ -> expectationFailure "expected one external agent"

    it "parses a primitive agent" $ do
      module' <- parseClean "primitive agent add(a: integer, b: integer) -> integer"
      case module'.declarations of
        [DeclarationPrimitiveAgent primitive] -> length primitive.parameters `shouldBe` 2
        _ -> expectationFailure "expected one primitive agent"

    it "parses a data declaration" $ do
      module' <- parseClean "data point(x: integer, y: integer)"
      case module'.declarations of
        [DeclarationData dataDeclaration] -> do
          dataDeclaration.name `shouldBe` "point"
          length dataDeclaration.parameters `shouldBe` 2
        _ -> expectationFailure "expected one data"

    -- `()` means NO parameters and `f()` means NO arguments — the parser inserts nothing. The whole
    -- zero-argument story rests on that literal reading (an object type names only what it requires,
    -- so a nullary agent still fits a `(value: null)` slot); a sugar that filled in a `value` here
    -- would silently change what `agent main() -> string` and `record.empty()` mean.
    it "parses an empty parameter list as no parameters, and a bare call as no arguments" $ do
      module' <- parseClean "agent thunk() -> integer { 1 }\nagent caller() -> integer { thunk() }"
      case module'.declarations of
        [DeclarationAgent thunk, DeclarationAgent caller] -> do
          length thunk.parameters `shouldBe` 0
          case caller.body.returnExpression of
            Just (ExpressionCall call) -> length call.arguments `shouldBe` 0
            _ -> expectationFailure "expected a bare call"
        _ -> expectationFailure "expected two agents"

    it "rejects a newline before an agent's body brace (no Allman braces)" $
      shouldFail "agent main() -> integer\n{ 1 }"

    -- A signature is line-scoped so the body brace must be same-line, which used to make the ONE part of
    -- a signature whose length is not the author's to shorten — the effect row — unwrappable: the
    -- examples' rows run past 200 characters. The two break points below are now legal; the rejections
    -- underneath them are the reason it is safe (nothing is consumed when no clause follows).
    it "allows a newline before the `with` row" $ do
      module' <- parseClean "agent main() -> integer\n  with tick { 1 }"
      case module'.declarations of
        [DeclarationAgent agent] -> agent.effects `shouldSatisfy` isJust
        _ -> expectationFailure "expected one agent"

    it "allows a newline after a `|` inside the `with` row" $ do
      module' <- parseClean "agent main() -> integer with tick |\n  tock { 1 }"
      case module'.declarations of
        [DeclarationAgent agent] -> case agent.effects of
          Just (TypeUnion union) -> length union.branches `shouldBe` 2
          _ -> expectationFailure "expected a two-branch effect row"
        _ -> expectationFailure "expected one agent"

    it "allows both breaks at once (the row-heavy signature the examples wanted to wrap)" $ do
      module' <- parseClean "agent main() -> integer\n  with tick |\n    tock |\n    chime { 1 }"
      case module'.declarations of
        [DeclarationAgent agent] -> case agent.effects of
          Just (TypeUnion union) -> length union.branches `shouldBe` 3
          _ -> expectationFailure "expected a three-branch effect row"
        _ -> expectationFailure "expected one agent"

    it "allows a newline after a `|` in a return type" $ do
      module' <- parseClean "agent main() -> integer |\n  string { 1 }"
      case module'.declarations of
        [DeclarationAgent agent] -> case agent.returnType of
          Just (TypeUnion union) -> length union.branches `shouldBe` 2
          _ -> expectationFailure "expected a two-branch return type"
        _ -> expectationFailure "expected one agent"

    -- The Allman rejection above and this one are what 'breakableBefore' has to preserve: it consumes
    -- NOTHING when the clause it speculates on is absent, so the newline is still there to be rejected.
    it "still rejects an Allman body brace when the signature carries a `with` row" $
      shouldFail "agent main() -> integer with tick\n{ 1 }"

    it "still rejects an Allman body brace after a wrapped `with` row" $
      shouldFail "agent main() -> integer\n  with tick | tock\n{ 1 }"

    it "parses a marker effect declaration" $ do
      module' <- parseClean "effect scoped[resource]"
      case module'.declarations of
        [DeclarationMarkerEffect marker] -> do
          marker.name `shouldBe` "scoped"
          length marker.genericParameters `shouldBe` 1
        _ -> expectationFailure "expected one marker effect"

    it "parses a marker effect without generics and keeps its doc annotation" $ do
      module' <- parseClean "@\"a pure capability\"\neffect sandboxed"
      case module'.declarations of
        [DeclarationMarkerEffect marker] -> do
          marker.annotation `shouldBe` Just "a pure capability"
          marker.genericParameters `shouldBe` []
        _ -> expectationFailure "expected one marker effect"

    it "parses a string literal in type position as a singleton type" $ do
      module' <- parseClean "type fast = \"fast\""
      case module'.declarations of
        [DeclarationTypeSynonym synonym] -> case synonym.definition of
          TypeStringLiteral node -> node.value `shouldBe` "fast"
          _ -> expectationFailure "expected a string literal type"
        _ -> expectationFailure "expected one type synonym"

    it "unescapes a string literal type exactly like an expression literal" $ do
      module' <- parseClean "type odd = \"a\\n\\\"b\\\\\""
      case module'.declarations of
        [DeclarationTypeSynonym synonym] -> case synonym.definition of
          TypeStringLiteral node -> node.value `shouldBe` "a\n\"b\\"
          _ -> expectationFailure "expected a string literal type"
        _ -> expectationFailure "expected one type synonym"

    it "parses a `literal` generic parameter as a literal-binding type parameter" $ do
      module' <- parseClean "agent connect[literal url_type](url: url_type) -> url_type { url }"
      case module'.declarations of
        [DeclarationAgent agent] -> case agent.genericParameters of
          [parameter] -> do
            parameter.name `shouldBe` "url_type"
            parameter.bindsLiteral `shouldBe` True
          _ -> expectationFailure "expected one generic parameter"
        _ -> expectationFailure "expected one agent"

    it "keeps a bare `[literal]` a plain parameter named literal (positional word, not reserved)" $ do
      module' <- parseClean "agent f[literal]() -> integer { 1 }"
      case module'.declarations of
        [DeclarationAgent agent] -> case agent.genericParameters of
          [parameter] -> do
            parameter.name `shouldBe` "literal"
            parameter.bindsLiteral `shouldBe` False
          _ -> expectationFailure "expected one generic parameter"
        _ -> expectationFailure "expected one agent"

    it "parses a type synonym with generics" $ do
      module' <- parseClean "type pair[T] = [T, T]"
      case module'.declarations of
        [DeclarationTypeSynonym synonym] -> synonym.name `shouldBe` "pair"
        _ -> expectationFailure "expected one type synonym"

    it "parses several declarations in one module" $ do
      module' <- parseClean "data point(x: integer)\n\nagent main() -> integer { 1 }"
      length module'.declarations `shouldBe` 2

  describe "parameter defaults" $ do
    it "parses container literal trees on signature parameters (arrays, records, nesting, quoted keys)" $ do
      module' <-
        parseClean
          "data config(tags: array[string] ?= [], point: {x: integer} ?= {x = 1, \"Content-Type\" = \"text\"}, rows: array[unknown] ?= [[1], {y = null}])"
      case module'.declarations of
        [DeclarationData dataDeclaration] ->
          [(.value) <$> parameter.defaultValue | parameter <- dataDeclaration.parameters]
            `shouldBe` [ Just (DefaultValueArray []),
                         Just
                           ( DefaultValueRecord
                               [ ("x", DefaultValueLiteral (LiteralValueInteger 1)),
                                 ("Content-Type", DefaultValueLiteral (LiteralValueString "text"))
                               ]
                           ),
                         Just
                           ( DefaultValueArray
                               [ DefaultValueArray [DefaultValueLiteral (LiteralValueInteger 1)],
                                 DefaultValueRecord [("y", DefaultValueLiteral LiteralValueNull)]
                               ]
                           )
                       ]
        _ -> expectationFailure "expected one data"

    it "parses a container default on an agent parameter binder" $ do
      module' <- parseClean "agent f(items: array[string] ?= []) -> integer { 0 }"
      case module'.declarations of
        [DeclarationAgent agent] -> case agent.parameters of
          [parameter] -> case parameter.binder of
            BindVariable _ _ (Just parameterDefault) -> parameterDefault.value `shouldBe` DefaultValueArray []
            _ -> expectationFailure "expected a defaulted variable binder"
          _ -> expectationFailure "expected one parameter"
        _ -> expectationFailure "expected one agent"

    it "still rejects a non-literal expression as a default" $
      shouldFail "agent f(items: array[string] ?= record.empty()) -> integer { 0 }"

    it "rejects a call expression inside a container default" $
      shouldFail "agent f(items: array[string] ?= [make()]) -> integer { 0 }"

    it "rejects duplicate keys in a record default" $
      shouldFail "agent f(point: {x: integer} ?= {x = 1, x = 2}) -> integer { point.x }"

  describe "imports" $ do
    it "parses a prefix module import" $ do
      module' <- parseClean "import list_utils.helpers"
      case module'.declarations of
        [DeclarationImport (ImportDeclaration {kind = ImportModule m})] -> m.moduleName `shouldBe` ModuleName "list_utils.helpers"
        _ -> expectationFailure "expected a module import"

    it "parses an aliased import" $ do
      module' <- parseClean "import foo.bar as baz"
      case module'.declarations of
        [DeclarationImport (ImportDeclaration {kind = ImportModule m})] -> m.alias `shouldBe` Just "baz"
        _ -> expectationFailure "expected a module import"

    it "parses a named import with a type item" $ do
      module' <- parseClean "import { double, type Pair } from list_utils"
      case module'.declarations of
        [DeclarationImport (ImportDeclaration {kind = ImportNames names})] -> length names.items `shouldBe` 2
        _ -> expectationFailure "expected a named import"

  describe "expressions and statements" $ do
    it "parses binary operators with precedence" $ do
      body <- parseClean "agent main() -> integer { 1 + 2 * 3 }" >>= soleAgentBody
      case body.returnExpression of
        Just (ExpressionBinaryOperator node) -> node.operator `shouldBe` BinaryOperatorAdd
        _ -> expectationFailure "expected a top-level addition"

    it "parses a let chain ending in a value" $ do
      body <- parseClean "agent main() -> integer {\n  let a = 1\n  let b = 2\n  a + b\n}" >>= soleAgentBody
      length body.statements `shouldBe` 2
      body.returnExpression `shouldSatisfy` (/= Nothing)

    it "parses calls with keyword arguments" $ do
      body <- parseClean "agent main() -> integer { sum_two(a = 2, b = 3) }" >>= soleAgentBody
      case body.returnExpression of
        Just (ExpressionCall node) -> length node.arguments `shouldBe` 2
        _ -> expectationFailure "expected a call"

    it "parses a `_` argument value as a hole (partial application)" $ do
      body <- parseClean "agent main() -> integer { sum_two(a = _, b = 3) }" >>= soleAgentBody
      case body.returnExpression of
        Just (ExpressionCall node) -> case node.arguments of
          [holeArgument, suppliedArgument] -> do
            case holeArgument.value of
              ArgumentHole _ -> pure ()
              ArgumentExpression _ -> expectationFailure "expected the first argument to be a hole"
            case suppliedArgument.value of
              ArgumentExpression _ -> pure ()
              ArgumentHole _ -> expectationFailure "expected the second argument to be an expression"
          _ -> expectationFailure "expected two arguments"
        _ -> expectationFailure "expected a call"

    it "keeps an underscore-prefixed identifier argument an ordinary expression" $ do
      body <- parseClean "agent main() -> integer { sum_two(a = _x, b = 3) }" >>= soleAgentBody
      case body.returnExpression of
        Just (ExpressionCall node) -> case node.arguments of
          (firstArgument : _) -> case firstArgument.value of
            ArgumentExpression (ExpressionVariable variable) -> variable.name `shouldBe` "_x"
            _ -> expectationFailure "expected a variable expression argument"
          _ -> expectationFailure "expected arguments"
        _ -> expectationFailure "expected a call"

    it "still parses a bare `_` outside an argument value as a variable expression" $ do
      body <- parseClean "agent main() -> integer { _ }" >>= soleAgentBody
      case body.returnExpression of
        Just (ExpressionVariable variable) -> variable.name `shouldBe` "_"
        _ -> expectationFailure "expected a variable expression"

    it "parses a record literal and field access" $ do
      _ <- parseClean "agent main() -> integer { let r = { name = \"a\", age = 30 }\n r.age }"
      pure ()

    it "parses a `...base` spread entry alongside written fields, in source order" $ do
      body <- parseClean "agent main() -> integer { { ...base, a = 1 } }" >>= soleAgentBody
      case body.returnExpression of
        Just (ExpressionRecord record) -> case record.entries of
          [RecordEntrySpread (ExpressionVariable base), RecordEntryField field] -> do
            base.name `shouldBe` "base"
            field.name `shouldBe` "a"
          other -> expectationFailure ("expected a spread then a field, got " <> show other)
        _ -> expectationFailure "expected a record literal"

    it "rejects `...` outside a record literal (it starts no other expression form)" $
      shouldFail "agent main() -> integer { ...x }"

    it "accepts an `else` starting on the line AFTER the then-block's `}`" $ do
      body <- parseClean "agent main() -> integer {\n  if (true) {\n    1\n  }\n  else {\n    2\n  }\n}" >>= soleAgentBody
      case body.returnExpression of
        Just (ExpressionIf ifExpression) -> ifExpression.elseBlock `shouldSatisfy` isJust
        _ -> expectationFailure "expected an if expression"

    it "chains a next-line `else if`" $ do
      body <- parseClean "agent main() -> integer {\n  if (true) {\n    1\n  }\n  else if (false) {\n    2\n  }\n  else {\n    3\n  }\n}" >>= soleAgentBody
      case body.returnExpression of
        Just (ExpressionIf ifExpression) -> ifExpression.elseBlock `shouldSatisfy` isJust
        _ -> expectationFailure "expected an if expression"

    it "still ends an `else`-less `if` at its `}`, so the next line is a separate statement" $ do
      -- The counterpart to the two above: the `else` lookahead backtracks, so eating the newline to
      -- find an `else` must not swallow the statement separator when there is none.
      body <- parseClean "agent main() -> integer {\n  if (true) {\n    1\n  }\n  2\n}" >>= soleAgentBody
      case (body.statements, body.returnExpression) of
        ([StatementExpression (ExpressionIf ifExpression)], Just (ExpressionLiteral literal)) -> do
          ifExpression.elseBlock `shouldBe` Nothing
          literal.value `shouldBe` LiteralValueInteger 2
        other -> expectationFailure ("expected an `if` statement then a trailing literal, got " <> show other)

    it "keeps a doc annotation on a let statement (doc-on-let)" $ do
      body <- parseClean "agent main() -> integer {\n  @\"the herald's window\"\n  let herald_view = 1\n  herald_view\n}" >>= soleAgentBody
      case body.statements of
        [StatementLet letStatement] -> letStatement.annotation `shouldBe` Just "the herald's window"
        _ -> expectationFailure "expected one let statement"

    it "parses a same-line doc annotation on a let statement" $ do
      body <- parseClean "agent main() -> integer {\n  @\"role doc\" let x = 1\n  x\n}" >>= soleAgentBody
      case body.statements of
        [StatementLet letStatement] -> letStatement.annotation `shouldBe` Just "role doc"
        _ -> expectationFailure "expected one let statement"

    it "an undocumented let carries no annotation" $ do
      body <- parseClean "agent main() -> integer {\n  let x = 1\n  x\n}" >>= soleAgentBody
      case body.statements of
        [StatementLet letStatement] -> letStatement.annotation `shouldBe` Nothing
        _ -> expectationFailure "expected one let statement"

    it "keeps a doc annotation on a nested agent declaration" $ do
      body <- parseClean "agent main() -> integer {\n  @\"a documented helper\"\n  agent helper() -> integer { 1 }\n  helper()\n}" >>= soleAgentBody
      case body.statements of
        [StatementAgent helper] -> do
          helper.name `shouldBe` "helper"
          helper.annotation `shouldBe` Just "a documented helper"
        _ -> expectationFailure "expected one local agent statement"

    it "rejects a doc annotation before any other statement kind" $ do
      shouldFail "agent main() -> integer {\n  @\"doc\"\n  return 1\n}"
      shouldFail "agent main() -> integer {\n  @\"doc\"\n  1 + 1\n}"
      shouldFail "agent main() -> integer {\n  @\"doc\"\n  finally { 1 }\n  2\n}"

    it "rejects a doc annotation on a destructuring let (no single name to stamp)" $ do
      shouldFail "agent main() -> integer {\n  @\"doc\"\n  let (a, b) = pair\n  a\n}"

    it "rejects a dangling doc annotation at the end of a block" $ do
      shouldFail "agent main() -> integer {\n  @\"doc\"\n}"

    it "parses an f-string with interpolation" $ do
      body <- parseClean "agent main() -> string { f\"sum = ${total}\" }" >>= soleAgentBody
      case body.returnExpression of
        Just (ExpressionTemplate node) -> length node.elements `shouldBe` 2
        _ -> expectationFailure "expected a template"

    it "parses if / else if / else" $ do
      _ <- parseClean "agent main() -> string { if (n > 0) { \"p\" } else if (n < 0) { \"n\" } else { \"z\" } }"
      pure ()

    it "parses match with constructor, type-filter and record patterns" $ do
      body <-
        parseClean "agent describe(value: unknown) -> string {\n  match (value) {\n    case integer(n) -> \"int\"\n    case point(x => xv, y => yv) -> \"point\"\n    case { name => string(s) } -> \"named\"\n    case _ -> \"other\"\n  }\n}"
          >>= soleAgentBody
      case body.returnExpression of
        Just (ExpressionMatch node) -> length node.cases `shouldBe` 4
        _ -> expectationFailure "expected a match"

    it "parses a bare record-pattern field as a variable bind on the label" $ do
      body <-
        parseClean "agent describe(value: unknown) -> string {\n  match (value) {\n    case { name } -> name\n    case _ -> \"other\"\n  }\n}"
          >>= soleAgentBody
      case body.returnExpression of
        Just (ExpressionMatch node) -> length node.cases `shouldBe` 2
        _ -> expectationFailure "expected a match"

    it "parses a narrowing annotated variable pattern" $ do
      _ <- parseClean "agent main() -> integer { match (v) { case n: integer -> n\n case _ -> 0 } }"
      pure ()

    it "parses a for / then loop with a state variable" $ do
      body <-
        parseClean "agent main() -> integer {\n  for (let x in [1, 2, 3], var acc: integer = 0) {\n    next with { acc = acc + x }\n  } then (ys) { acc }\n}"
          >>= soleAgentBody
      case body.returnExpression of
        Just (ExpressionFor node) -> do
          length node.varBindings `shouldBe` 1
          node.thenClause `shouldSatisfy` (/= Nothing)
        _ -> expectationFailure "expected a for"

    it "parses a parallel for" $ do
      body <- parseClean "agent main() -> integer { parallel for (let x in xs) { next x } }" >>= soleAgentBody
      case body.returnExpression of
        Just (ExpressionFor node) -> node.parallel `shouldBe` True
        _ -> expectationFailure "expected a for"

    it "parses a forever loop" $ do
      body <- parseClean "agent main() -> never { forever { tick() } }" >>= soleAgentBody
      case body.returnExpression of
        Just (ExpressionForever node) -> do
          length node.body.statements `shouldBe` 0
          length node.varBindings `shouldBe` 0
        _ -> expectationFailure "expected a forever loop"

    it "parses a forever loop with a `var` state header" $ do
      body <- parseClean "agent main() -> integer { forever (var n = 0) { break n } }" >>= soleAgentBody
      case body.returnExpression of
        Just (ExpressionForever node) -> length node.varBindings `shouldBe` 1
        _ -> expectationFailure "expected a forever loop with a var header"

    it "keeps `forever` an ordinary identifier away from a loop head (a call, and a declared agent name)" $ do
      -- The word is recognised positionally (only directly before `{`), so the stdlib's `replay.forever`
      -- agent — declared and called by that name — must keep parsing as an identifier.
      body <- parseClean "agent main() -> integer { forever(x = 1) }" >>= soleAgentBody
      case body.returnExpression of
        Just (ExpressionCall _) -> pure ()
        _ -> expectationFailure "expected a call to an agent named forever"
      _ <- parseClean "agent forever(x: integer) -> integer { x }"
      pure ()

    it "parses a parallel tuple" $ do
      body <- parseClean "agent main() -> integer { parallel [a, b, c] }" >>= soleAgentBody
      case body.returnExpression of
        Just (ExpressionTuple node) -> node.parallel `shouldBe` True
        _ -> expectationFailure "expected a tuple"

    it "parses a generic instantiation" $ do
      body <- parseClean "agent main() -> integer { identity[integer](x = 1) }" >>= soleAgentBody
      case body.returnExpression of
        Just (ExpressionCall node) -> case node.callee of
          ExpressionTypeApplication _ -> pure ()
          _ -> expectationFailure "expected a generic instantiation callee"
        _ -> expectationFailure "expected a call"

    it "parses an f-string interpolation with inner padding" $ do
      body <- parseClean "agent main() -> string { f\"x=${ total }\" }" >>= soleAgentBody
      case body.returnExpression of
        Just (ExpressionTemplate _) -> pure ()
        _ -> expectationFailure "expected a template expression"

    it "parses stacked prefix operators (the second applies to the first's operand)" $ do
      body <- parseClean "agent main() -> boolean { !!flag }" >>= soleAgentBody
      case body.returnExpression of
        Just (ExpressionUnaryOperator outer) -> case outer.operand of
          ExpressionUnaryOperator _ -> pure ()
          _ -> expectationFailure "expected a nested unary operator (the inner !)"
        _ -> expectationFailure "expected a unary operator"

    it "parses mixed and spaced prefix-operator stacks" $ do
      _ <- parseClean "agent main() -> integer { - -x }" >>= soleAgentBody
      _ <- parseClean "agent main() -> integer { -!x }" >>= soleAgentBody
      pure ()

  describe "anonymous agent expressions" $ do
    it "parses an anonymous agent as a call argument" $ do
      body <- parseClean "agent main() -> integer { pick(keep = agent (value: integer) -> boolean { value > 3 }) }" >>= soleAgentBody
      case body.returnExpression of
        Just (ExpressionCall call) -> case call.arguments of
          [argument] -> case argument.value of
            ArgumentExpression (ExpressionAgent anonymous) -> do
              anonymous.name `shouldBe` anonymousAgentName
              anonymous.private `shouldBe` False
              anonymous.annotation `shouldBe` Nothing
              length anonymous.parameters `shouldBe` 1
              anonymous.returnType `shouldSatisfy` (/= Nothing)
              anonymous.effects `shouldBe` Nothing
            _ -> expectationFailure "expected an anonymous agent argument"
          _ -> expectationFailure "expected one argument"
        _ -> expectationFailure "expected a call"

    it "parses an anonymous agent bound by a let, with an explicit effect row" $ do
      body <- parseClean "agent main() -> integer {\n  let step = agent (value: integer) -> integer with tick { value }\n  step(value = 1)\n}" >>= soleAgentBody
      case body.statements of
        [StatementLet letStatement] -> case letStatement.value of
          ExpressionAgent anonymous -> anonymous.effects `shouldSatisfy` (/= Nothing)
          _ -> expectationFailure "expected an anonymous agent value"
        _ -> expectationFailure "expected one let statement"

    it "parses an anonymous agent with neither a return type nor an effect row" $ do
      body <- parseClean "agent main() -> integer { run(body = agent () { 1 }) }" >>= soleAgentBody
      case body.returnExpression of
        Just (ExpressionCall call) -> case call.arguments of
          [argument] -> case argument.value of
            ArgumentExpression (ExpressionAgent anonymous) -> do
              anonymous.returnType `shouldBe` Nothing
              anonymous.effects `shouldBe` Nothing
            _ -> expectationFailure "expected an anonymous agent argument"
          _ -> expectationFailure "expected one argument"
        _ -> expectationFailure "expected a call"

    it "parses a private anonymous agent" $ do
      body <- parseClean "agent main() -> integer {\n  let step = private agent (value: integer) -> integer { value }\n  step(value = 1)\n}" >>= soleAgentBody
      case body.statements of
        [StatementLet letStatement] -> case letStatement.value of
          ExpressionAgent anonymous -> anonymous.private `shouldBe` True
          _ -> expectationFailure "expected an anonymous agent value"
        _ -> expectationFailure "expected one let statement"

    it "still parses a named local agent as a declaration statement" $ do
      body <- parseClean "agent main() -> integer {\n  agent helper(value: integer) -> integer { value }\n  helper(value = 1)\n}" >>= soleAgentBody
      case body.statements of
        [StatementAgent helper] -> helper.name `shouldBe` "helper"
        _ -> expectationFailure "expected one local agent statement"

    it "still parses a named private local agent as a declaration statement" $ do
      body <- parseClean "agent main() -> integer {\n  private agent helper(value: integer) -> integer { value }\n  helper(value = 1)\n}" >>= soleAgentBody
      case body.statements of
        [StatementAgent helper] -> do
          helper.name `shouldBe` "helper"
          helper.private `shouldBe` True
        _ -> expectationFailure "expected one local agent statement"

    -- The block dispatcher must not commit to the declaration grammar on the keyword alone: an
    -- anonymous agent at the head of a block element is an expression, and the rest of the expression
    -- grammar (here an immediate application) has to keep parsing after it.
    it "parses an anonymous agent at a block element's head as an expression" $ do
      body <- parseClean "agent main() -> integer { agent (value: integer) -> integer { value }(value = 1) }" >>= soleAgentBody
      case body.returnExpression of
        Just (ExpressionCall call) -> case call.callee of
          ExpressionAgent _ -> pure ()
          _ -> expectationFailure "expected an anonymous agent callee"
        _ -> expectationFailure "expected an immediate application"

    it "parses an anonymous agent as a block's trailing value" $ do
      body <- parseClean "agent main() -> integer {\n  let seed = 1\n  agent (value: integer) -> integer { value + seed }\n}" >>= soleAgentBody
      case body.returnExpression of
        Just (ExpressionAgent _) -> pure ()
        _ -> expectationFailure "expected an anonymous agent trailing value"

    it "keeps `private` usable as an ordinary identifier when no `agent` follows it" $ do
      body <- parseClean "agent main(private: integer) -> integer { private + 1 }" >>= soleAgentBody
      case body.returnExpression of
        Just (ExpressionBinaryOperator _) -> pure ()
        _ -> expectationFailure "expected an addition over the `private` variable"

    it "rejects a name on an agent expression" $
      shouldFail "agent main() -> integer {\n  let step = agent helper(value: integer) -> integer { value }\n  step(value = 1)\n}"

    it "rejects an anonymous agent at the top level (a declaration must bind a name)" $
      shouldFail "agent (value: integer) -> integer { value }"

    -- A doc annotation stamps the value it documents with a NAME, and an anonymous agent has none;
    -- documenting the `let` that binds it is the supported spelling.
    it "rejects a doc annotation on an anonymous agent" $
      shouldFail "agent main() -> integer {\n  @\"doc\"\n  agent (value: integer) -> integer { value }\n}"

    it "rejects a newline before an anonymous agent's body brace (no Allman braces)" $
      shouldFail "agent main() -> integer {\n  let step = agent (value: integer) -> integer\n  { value }\n  1\n}"

  describe "handlers, use, next/break" $ do
    it "parses a use of an inline handler with next/break" $ do
      body <-
        parseClean "agent main() -> integer {\n  use handler (var counter = 1) {\n    request tick() { next counter with { counter = counter + 1 } }\n  }\n  tick()\n}"
          >>= soleAgentBody
      case body.statements of
        (StatementUse useStatement : _) -> length useStatement.body.statements `shouldBe` 0
        _ -> expectationFailure "expected a leading use statement"

    it "parses a first-class handler value with generic arguments" $ do
      _ <- parseClean "agent make() -> integer { handler[R, pure] { request ask() { next 7 } } }"
      pure ()

    it "parses let-bound use" $ do
      body <- parseClean "agent main() -> integer {\n  let x = use provide\n  x * 7\n}" >>= soleAgentBody
      case body.statements of
        (StatementUse useStatement : _) -> useStatement.binder `shouldSatisfy` (/= Nothing)
        _ -> expectationFailure "expected a use statement"

  describe "finally" $ do
    it "parses a finally statement carrying a block" $ do
      body <- parseClean "agent main() -> integer {\n  finally { let cleanup = 1 }\n  7\n}" >>= soleAgentBody
      case body.statements of
        (StatementFinally finallyStatement : _) -> length finallyStatement.body.statements `shouldBe` 1
        _ -> expectationFailure "expected a leading finally statement"

    it "rejects `finally` used as an identifier (it is a reserved keyword)" $
      shouldFail "agent main() -> integer { let finally = 1 }"

  describe "comments and layout" $ do
    it "ignores line and block comments" $ do
      _ <- parseClean "// header\nagent main() -> integer {\n  let a = 1 // trailing\n  /* block */ a\n}"
      pure ()

    it "rejects two statements on one line without a separator" $
      shouldFail "agent main() -> integer { let x = 1 let y = 2 }"

    it "reports a diagnostic on malformed input" $
      shouldFail "agent main( -> string { }"

  describe "integer literals" $ do
    it "warns (K1002) on an integer literal beyond the safe range but still parses it" $ do
      -- 2^53 + 1: not representable exactly by a runtime number.
      let (module', diagnostics) = parseModule (ModuleName "test") "agent main() -> integer { 9007199254740993 }"
      map (compilerErrorCode . (.value)) (toList diagnostics) `shouldBe` ["K1002"]
      module'.declarations `shouldSatisfy` (not . null)
    it "does not warn at the safe-range boundary (2^53 - 1)" $
      codesOf "agent main() -> integer { 9007199254740991 }" `shouldBe` []

  describe "error recovery" $ do
    it "recovers at the next declaration and keeps the good ones" $ do
      let (module', diagnostics) = parseModule (ModuleName "test") "agent broken( -> integer { 1 }\n\nagent good() -> integer { 2 }"
      diagnostics `shouldNotSatisfy` null
      case module'.declarations of
        [DeclarationError _, DeclarationAgent agent] -> agent.name `shouldBe` "good"
        other -> expectationFailure ("expected [error, good agent], got " <> show (length other) <> " declarations")

    it "still parses earlier declarations before a broken one" $ do
      let (module', diagnostics) = parseModule (ModuleName "test") "data point(x: integer)\n\nagent broken() -> { 1 }\n\nagent fine() -> integer { 3 }"
      diagnostics `shouldNotSatisfy` null
      length module'.declarations `shouldBe` 3
