module Katari.ParserSpec (spec) where

import Data.List (isInfixOf)
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Katari.AST
import Katari.Common (LiteralValue (..))
import Katari.Diagnostic (Diagnostic (..))
import Katari.Lexer qualified as Lexer
import Katari.Parser qualified as Parser
import Katari.SourceSpan (HasSourceSpan (..), Position (..), SourceSpan (..))
import Test.Hspec

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Extract the textual content of a @NameRef Parsed symbol@. Defined as a
-- top-level helper to avoid DuplicateRecordFields ambiguity in test chains
-- such as @v.name.text `shouldBe` "x"@.
nameText :: NameRef Parsed symbol -> Text
nameText ref = ref.text

parse :: Text -> Either [Diagnostic] (Module Parsed)
parse src =
  let (stream, lexErrors) = Lexer.lex "<test>" src
      (parsed, parseErrors) = Parser.parse "<test>" stream
      allDiags = map Lexer.toDiagnostic lexErrors <> map Parser.toDiagnostic parseErrors
   in case allDiags of
        [] -> Right parsed
        errs -> Left errs

-- | Flatten diagnostics into a string for substring matching.
-- Only used inside 'shouldFailWith'; do not use this for new tests.
renderParseErrors :: [Diagnostic] -> String
renderParseErrors = T.unpack . T.unlines . map (.message)

shouldSucceed :: Text -> IO (Module Parsed)
shouldSucceed src = case parse src of
  Right m -> pure m
  Left errors ->
    expectationFailure ("Parse failed:\n" <> renderParseErrors errors)
      >> error "unreachable: expectationFailure escaped"

shouldFail :: Text -> IO ()
shouldFail src = case parse src of
  Left _ -> pure ()
  Right _ -> expectationFailure "Expected parse failure but succeeded"

-- | Assert that parsing fails and the error message contains a given
-- substring. Helpful for nailing down *why* a case fails.
shouldFailWith :: Text -> String -> IO ()
shouldFailWith src needle = case parse src of
  Right _ -> expectationFailure "Expected parse failure but succeeded"
  Left errors ->
    let rendered = renderParseErrors errors
     in if needle `isInfixOf` rendered
          then pure ()
          else expectationFailure ("Expected error to contain " <> show needle <> " but got:\n" <> rendered)

-- | Parse an expression from the body of an agent.
parseExpr :: Text -> IO (Expression Parsed)
parseExpr src = do
  m <- shouldSucceed (T.concat ["agent main() { ", src, " }"])
  case head m.declarations of
    DeclarationAgent a -> case a.body.returnExpression of
      Just e -> pure e
      Nothing -> expectationFailure "expected trailing expression" >> error "unreachable"
    _ -> expectationFailure "expected agent" >> error "unreachable"

-- | Extract declarations from a successfully parsed module
decls :: Module Parsed -> [Declaration Parsed]
decls m = m.declarations

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "Katari.Parser" $ do
    literals
    variables
    operators
    callExpression
    ifExpression
    matchExpression
    forExpression
    templateLiteral
    tupleAndArray
    blockExpression
    fieldAndIndex
    letStatement
    returnStatement
    nextAndBreak
    declarations
    handleExpression
    patterns
    types
    arrayAndTupleTypes
    parenthesesGrouping
    autoSemicolon
    escapeSequences
    surrogatePairEscape
    sourceSpans
    spanBoundaries
    sameLineBlockKeyword
    declarationsNegative
    numberLiterals
    edgeCases
    multilineTokenSpans
    crlfHandling
    qualifiedConstructorPatterns
    multilineStringRecovery

-- ---------------------------------------------------------------------------
-- Literals
-- ---------------------------------------------------------------------------

literals :: Spec
literals = describe "literals" $ do
  it "parses integer" $ do
    _ <- shouldSucceed "agent main() { 42 }"
    pure ()

  it "LiteralValueInteger value is preserved" $ do
    m <- shouldSucceed "agent main() { 42 }"
    case head (decls m) of
      DeclarationAgent a ->
        case (a.body.returnExpression :: Maybe (Expression Parsed)) of
          Just (ExpressionLiteral e) -> e.value `shouldBe` LiteralValueInteger 42
          _ -> expectationFailure "expected literal expression"
      _ -> expectationFailure "expected agent"

  it "parses negative integer via unary minus" $ do
    _ <- shouldSucceed "agent main() { -1 }"
    pure ()

  it "parses float" $ do
    _ <- shouldSucceed "agent main() { 3.14 }"
    pure ()

  it "parses true" $ do
    _ <- shouldSucceed "agent main() { true }"
    pure ()

  it "parses false" $ do
    _ <- shouldSucceed "agent main() { false }"
    pure ()

  it "parses null" $ do
    _ <- shouldSucceed "agent main() { null }"
    pure ()

  it "parses string" $ do
    _ <- shouldSucceed "agent main() { \"hello\" }"
    pure ()

  it "parses string with escape sequences" $ do
    _ <- shouldSucceed "agent main() { \"line1\\nline2\\ttab\" }"
    pure ()

  it "rejects single-line string with literal newline" $ do
    shouldFail "agent main() { \"hello\nworld\" }"

  it "parses multiline string literal" $ do
    _ <- shouldSucceed "agent main() { \"\"\"\nhello\n\"\"\" }"
    pure ()

  it "parses multiline string with multiple lines" $ do
    _ <- shouldSucceed "agent main() { \"\"\"\nline1\nline2\n\"\"\" }"
    pure ()

  it "rejects multiline string without opening newline" $ do
    shouldFail "agent main() { \"\"\"hello\n\"\"\" }"

  it "rejects multiline string without closing newline" $ do
    shouldFail "agent main() { \"\"\"\nhello\"\"\" }"

-- ---------------------------------------------------------------------------
-- Variables
-- ---------------------------------------------------------------------------

variables :: Spec
variables = describe "variables" $ do
  it "parses simple variable" $ do
    _ <- shouldSucceed "agent main() { x }"
    pure ()

  it "parses underscore-prefixed variable" $ do
    _ <- shouldSucceed "agent main() { _unused }"
    pure ()

  it "rejects keyword as variable" $ do
    shouldFail "agent main() { let }"

  it "rejects bare underscore as expression" $ do
    shouldFail "agent main() { _ }"

  it "rejects digit-starting identifier" $ do
    shouldFail "agent main() { 1abc }"

  it "rejects 'for' used as variable" $ do
    shouldFail "agent main() { for }"

  it "rejects 'match' used as variable" $ do
    shouldFail "agent main() { match }"

-- ---------------------------------------------------------------------------
-- Operators
-- ---------------------------------------------------------------------------

operators :: Spec
operators = describe "operators" $ do
  it "parses addition" $ do
    _ <- shouldSucceed "agent main() { 1 + 2 }"
    pure ()

  it "parses arithmetic with precedence" $ do
    _ <- shouldSucceed "agent main() { 1 + 2 * 3 }"
    pure ()

  it "parses arithmetic precedence correctly (* binds tighter than +)" $ do
    e <- parseExpr "1 + 2 * 3"
    case e of
      ExpressionBinaryOperator b -> do
        b.operator `shouldBe` BinaryOperatorAdd
        case b.right of
          ExpressionBinaryOperator br -> br.operator `shouldBe` BinaryOperatorMultiply
          _ -> expectationFailure "right side should be *"
      _ -> expectationFailure "expected binop"

  it "parses comparison" $ do
    _ <- shouldSucceed "agent main() { x == y }"
    pure ()

  it "parses logical and/or" $ do
    _ <- shouldSucceed "agent main() { a && b || c }"
    pure ()

  it "parses string concat" $ do
    _ <- shouldSucceed "agent main() { \"a\" ++ \"b\" }"
    pure ()

  it "parses unary not" $ do
    _ <- shouldSucceed "agent main() { !true }"
    pure ()

  it "parses unary minus" $ do
    _ <- shouldSucceed "agent main() { -x }"
    pure ()

  it "rejects chained comparison (non-assoc)" $ do
    shouldFail "agent main() { 1 < 2 < 3 }"

  it "rejects chained equality (non-assoc)" $ do
    shouldFail "agent main() { a == b == c }"

-- ---------------------------------------------------------------------------
-- Call expressions
-- ---------------------------------------------------------------------------

callExpression :: Spec
callExpression = describe "call expressions" $ do
  it "parses named-arg call" $ do
    _ <- shouldSucceed "agent main() { foo(x = 1, y = 2) }"
    pure ()

  it "parses sugar call (ident)" $ do
    _ <- shouldSucceed "agent main() { foo(x, y) }"
    pure ()

  it "parses mixed named and sugar" $ do
    _ <- shouldSucceed "agent main() { foo(x, y = 2) }"
    pure ()

  it "parses zero-arg call" $ do
    _ <- shouldSucceed "agent main() { foo() }"
    pure ()

  it "parses chained field access then call" $ do
    _ <- shouldSucceed "agent main() { obj.method(x = 1) }"
    pure ()

  it "parses constructor call sugar" $ do
    _ <- shouldSucceed "agent main() { circle(r) }"
    pure ()

  it "accepts trailing comma in call (multi-line convention)" $ do
    _ <- shouldSucceed "agent main() { foo(x, y,) }"
    pure ()

-- ---------------------------------------------------------------------------
-- If expression
-- ---------------------------------------------------------------------------

ifExpression :: Spec
ifExpression = describe "if expression" $ do
  it "parses if-else" $ do
    _ <- shouldSucceed "agent main() { if (x) { 1 } else { 2 } }"
    pure ()

  it "parses if without else" $ do
    _ <- shouldSucceed "agent main() { if (x) { 1 } }"
    pure ()

  it "parses if-else if-else chain" $ do
    _ <-
      shouldSucceed
        "agent main() { if (a) { 1 } else { if (b) { 2 } else { 3 } } }"
    pure ()

  it "parses deeply nested if" $ do
    _ <- shouldSucceed "agent main() { if (a) { if (b) { if (c) { 1 } } } }"
    pure ()

-- ---------------------------------------------------------------------------
-- Match expression
-- ---------------------------------------------------------------------------

matchExpression :: Spec
matchExpression = describe "match expression" $ do
  it "parses single case" $ do
    _ <- shouldSucceed "agent main() { match (x) { case 1 => { true } } }"
    pure ()

  it "parses multiple cases" $ do
    _ <-
      shouldSucceed $
        mconcat
          [ "agent main() {",
            "  match (x) {",
            "    case 1 => { \"one\" }",
            "    case 2 => { \"two\" }",
            "    case _ => { \"other\" }",
            "  }",
            "}"
          ]
    pure ()

  it "parses empty match" $ do
    _ <- shouldSucceed "agent main() { match (x) {} }"
    pure ()

  it "parses match with constructor pattern" $ do
    _ <-
      shouldSucceed $
        mconcat
          [ "agent main() {",
            "  match (s) {",
            "    case circle(r = r) => { r }",
            "    case rect(w = w, h = h) => { w }",
            "  }",
            "}"
          ]
    pure ()

-- ---------------------------------------------------------------------------
-- For expression
-- ---------------------------------------------------------------------------

forExpression :: Spec
forExpression = describe "for expression" $ do
  it "parses basic for with in binding" $ do
    _ <- shouldSucceed "agent main() { for (let x in xs) { x } }"
    pure ()

  it "parses for with state var" $ do
    _ <- shouldSucceed "agent main() { for (let x in xs, var acc = 0) { acc } }"
    pure ()

  it "parses for with typed state var" $ do
    _ <- shouldSucceed "agent main() { for (let x in xs, var acc: integer = 0) { acc } }"
    pure ()

  it "parses for with then block" $ do
    _ <- shouldSucceed "agent main() { for (let x in xs) { x } then { null } }"
    pure ()

  it "parses for with multiple in bindings then vars" $ do
    _ <- shouldSucceed "agent main() { for (let x in xs, let y in ys, var acc = 0, var b = 0) { acc } }"
    pure ()

  it "rejects in-binding after var binding" $ do
    shouldFailWith
      "agent main() { for (var a = 0, let x in xs) { a } }"
      "'let' binding cannot follow 'var' binding"

  it "rejects interleaved in/var bindings" $ do
    shouldFailWith
      "agent main() { for (let x in xs, var a = 0, let y in ys) { a } }"
      "'let' binding cannot follow 'var' binding"

  it "for AST has ins first, vars second" $ do
    e <- parseExpr "for (let x in xs, let y in ys, var a = 0, var b = 1) { a }"
    case e of
      ExpressionFor fe -> do
        length fe.inBindings `shouldBe` 2
        length fe.varBindings `shouldBe` 2
        let firstVar = head fe.varBindings
        case firstVar.name of
          NameRef {text = t} -> t `shouldBe` ("a" :: Text)
      _ -> expectationFailure "expected for expression"

-- ---------------------------------------------------------------------------
-- Template literal
-- ---------------------------------------------------------------------------

templateLiteral :: Spec
templateLiteral = describe "template literal" $ do
  it "parses simple template" $ do
    _ <- shouldSucceed "agent main() { f\"hello\" }"
    pure ()

  it "parses template with interpolation" $ do
    _ <- shouldSucceed "agent main() { f\"hello ${name}\" }"
    pure ()

  it "parses template with expression interpolation" $ do
    _ <- shouldSucceed "agent main() { f\"result is ${1 + 2}\" }"
    pure ()

  it "rejects single-line template with literal newline" $ do
    shouldFail "agent main() { f\"hello\nworld\" }"

  it "parses multiline template literal" $ do
    _ <- shouldSucceed "agent main() { f\"\"\"\nhello\n\"\"\" }"
    pure ()

  it "parses multiline template with interpolation" $ do
    _ <- shouldSucceed "agent main() { f\"\"\"\nhello ${name}\n\"\"\" }"
    pure ()

  it "parses multiline template with multiple lines" $ do
    _ <- shouldSucceed "agent main() { f\"\"\"\nline1\nline2 ${x}\nline3\n\"\"\" }"
    pure ()

  it "rejects multiline template without opening newline" $ do
    shouldFail "agent main() { f\"\"\"hello\n\"\"\" }"

  it "rejects multiline template without closing newline" $ do
    shouldFail "agent main() { f\"\"\"\nhello\"\"\" }"

  it "preserves leading space in single-line template" $ do
    m <- shouldSucceed "agent main() { f\" hello\" }"
    case head (decls m) of
      DeclarationAgent a ->
        case (a.body.returnExpression :: Maybe (Expression Parsed)) of
          Just (ExpressionTemplate te) ->
            case te.elements of
              [TemplateElementString s] -> s.value `shouldBe` " hello"
              _ -> expectationFailure "expected single string element"
          _ -> expectationFailure "expected template"
      _ -> expectationFailure "expected agent"

  it "parses nested template literal inside interpolation" $ do
    _ <- shouldSucceed "agent main() { f\"outer ${f\"inner\"}\" }"
    pure ()

  it "template element has sourceSpan" $ do
    e <- parseExpr "f\"hello ${name}\""
    case e of
      ExpressionTemplate te -> case te.elements of
        [TemplateElementString s, TemplateElementExpression x] -> do
          s.value `shouldBe` "hello "
          (sourceSpanOf x).start.line `shouldBe` 1
        _ -> expectationFailure "expected two template elements"
      _ -> expectationFailure "expected template"

-- ---------------------------------------------------------------------------
-- Tuple and array
-- ---------------------------------------------------------------------------

tupleAndArray :: Spec
tupleAndArray = describe "tuple and array" $ do
  it "parses empty array" $ do
    _ <- shouldSucceed "agent main() { [] }"
    pure ()

  it "parses array literal" $ do
    _ <- shouldSucceed "agent main() { [1, 2, 3] }"
    pure ()

  it "parses grouped expression" $ do
    _ <- shouldSucceed "agent main() { (1 + 2) }"
    pure ()

  it "parses tuple" $ do
    _ <- shouldSucceed "agent main() { (1, 2, 3) }"
    pure ()

  it "parses record literal" $ do
    _ <- shouldSucceed "agent main() { { name = \"a\", age = 30 } }"
    pure ()

  it "parses record literal with trailing comma" $ do
    _ <- shouldSucceed "agent main() { { name = \"a\", } }"
    pure ()

  it "record literal AST carries entries with the right keys" $ do
    m <- shouldSucceed "agent main() { { x = 1, y = 2 } }"
    case head (decls m) of
      DeclarationAgent a -> case a.body.returnExpression of
        Just (ExpressionRecord r) -> map fst r.entries `shouldBe` ["x", "y"]
        _ -> expectationFailure "expected record literal"
      _ -> expectationFailure "expected agent"

  it "distinguishes record literal from empty block" $ do
    -- A block-shaped @{}@ stays a block; record literals require the
    -- `ident =` lookahead. (The trailing expression here is the block's
    -- value; a record literal would have parsed as ExpressionRecord.)
    m <- shouldSucceed "agent main() { {} }"
    case head (decls m) of
      DeclarationAgent a -> case a.body.returnExpression of
        Just (ExpressionBlock _) -> pure ()
        _ -> expectationFailure "expected block expression, not record literal"
      _ -> expectationFailure "expected agent"

-- ---------------------------------------------------------------------------
-- Block expression
-- ---------------------------------------------------------------------------

blockExpression :: Spec
blockExpression = describe "block expression" $ do
  it "parses empty block" $ do
    _ <- shouldSucceed "agent main() { {} }"
    pure ()

  it "parses block with statements" $ do
    _ <- shouldSucceed "agent main() { { let x = 1; x } }"
    pure ()

  it "parses trailing expression without semicolon (Rust-style return)" $ do
    _ <- shouldSucceed "agent main() { 42 }"
    pure ()

  it "parses statements followed by trailing expression" $ do
    _ <- shouldSucceed "agent main() { let x = 1; x }"
    pure ()

  it "trailing expression becomes returnExpr" $ do
    m <- shouldSucceed "agent main() { 42 }"
    case head (decls m) of
      DeclarationAgent a -> do
        isJust a.body.returnExpression `shouldBe` True
        length a.body.statements `shouldBe` 0
      _ -> expectationFailure "expected agent declaration"

  it "expression with semicolon is a statement, not returnExpr" $ do
    m <- shouldSucceed "agent main() { 42; }"
    case head (decls m) of
      DeclarationAgent a -> do
        isNothing a.body.returnExpression `shouldBe` True
        length a.body.statements `shouldBe` 1
      _ -> expectationFailure "expected agent declaration"

  it "trailing expression in nested block expression" $ do
    _ <- shouldSucceed "agent main() { let x = { 42 }; x }"
    pure ()

  it "parses deeply nested block expression" $ do
    _ <- shouldSucceed "agent main() { let x = { let y = { 1 }; y }; x }"
    pure ()

-- ---------------------------------------------------------------------------
-- Field access and index
-- ---------------------------------------------------------------------------

fieldAndIndex :: Spec
fieldAndIndex = describe "field access and index" $ do
  it "parses field access" $ do
    _ <- shouldSucceed "agent main() { obj.field }"
    pure ()

  it "parses chained field access" $ do
    _ <- shouldSucceed "agent main() { a.b.c }"
    pure ()

  it "parses index access" $ do
    _ <- shouldSucceed "agent main() { arr[0] }"
    pure ()

  it "parses chained field then index" $ do
    _ <- shouldSucceed "agent main() { obj.items[0] }"
    pure ()

-- ---------------------------------------------------------------------------
-- Statements
-- ---------------------------------------------------------------------------

letStatement :: Spec
letStatement = describe "let statement" $ do
  it "parses simple let" $ do
    _ <- shouldSucceed "agent main() { let x = 42; }"
    pure ()

  it "parses let with type annotation" $ do
    _ <- shouldSucceed "agent main() { let x: integer = 42; }"
    pure ()

  it "parses let with wildcard pattern" $ do
    _ <- shouldSucceed "agent main() { let _ = foo(); }"
    pure ()

  it "requires semicolon" $ do
    shouldFail "agent main() { let x = 1 }"

  it "let statement binds correct name" $ do
    m <- shouldSucceed "agent main() { let x = 1; }"
    case head (decls m) of
      DeclarationAgent a ->
        case a.body.statements of
          [StatementLet s] ->
            case s.pattern of
              PatternVariable v -> nameText v.name `shouldBe` "x"
              _ -> expectationFailure "expected var pattern"
          _ -> expectationFailure "expected one let statement"
      _ -> expectationFailure "expected agent"

  it "distinguishes `_` (wildcard) from `_x` (var pattern)" $ do
    m1 <- shouldSucceed "agent main() { let _ = x; }"
    m2 <- shouldSucceed "agent main() { let _x = x; }"
    case (head (decls m1), head (decls m2)) of
      (DeclarationAgent a1, DeclarationAgent a2) ->
        case (a1.body.statements, a2.body.statements) of
          ([StatementLet s1], [StatementLet s2]) ->
            case (s1.pattern, s2.pattern) of
              (PatternWildcard _, PatternVariable v) -> nameText v.name `shouldBe` "_x"
              _ -> expectationFailure "expected wildcard then var"
          _ -> expectationFailure "expected one let each"
      _ -> expectationFailure "expected agents"

returnStatement :: Spec
returnStatement = describe "return statement" $ do
  it "parses return" $ do
    _ <- shouldSucceed "agent main() { return 42; }"
    pure ()

nextAndBreak :: Spec
nextAndBreak = describe "next and break" $ do
  -- ForCtx (inside for body)
  it "parses for-next (bare)" $ do
    _ <- shouldSucceed "agent main() { for (let x in xs) { next; } }"
    pure ()

  it "parses for-next with modifiers" $ do
    _ <- shouldSucceed "agent main() { for (let x in xs) { next with { acc = acc + 1 }; } }"
    pure ()

  it "parses for-break" $ do
    _ <- shouldSucceed "agent main() { for (let x in xs) { break 0; } }"
    pure ()

  -- HandleCtx (inside request handler body)
  it "parses next with value (handle context)" $ do
    _ <-
      shouldSucceed $
        mconcat
          [ "agent main() {\n",
            "  handle {\n",
            "    request get() { next 42; }\n",
            "  }\n",
            "  result\n",
            "}"
          ]
    pure ()

  it "parses next with value and modifiers" $ do
    _ <-
      shouldSucceed $
        mconcat
          [ "agent main() {\n",
            "  handle {\n",
            "    request get() { next 42 with { count = count + 1 }; }\n",
            "  }\n",
            "  result\n",
            "}"
          ]
    pure ()

  it "parses handle-break" $ do
    _ <-
      shouldSucceed $
        mconcat
          [ "agent main() {\n",
            "  handle {\n",
            "    request get() { break 0; }\n",
            "  }\n",
            "  result\n",
            "}"
          ]
    pure ()

  -- TopCtx errors: should fail with a specific message
  it "rejects next in agent body (TopCtx) with clear error" $ do
    shouldFailWith
      "agent main() { next; }"
      "'next' is only allowed inside"

  it "rejects next-with-value in agent body (TopCtx)" $ do
    shouldFailWith
      "agent main() { next 42; }"
      "'next' is only allowed inside"

  it "rejects break in agent body (TopCtx) with clear error" $ do
    shouldFailWith
      "agent main() { break 0; }"
      "'break' is only allowed inside"

  -- ForCtx / HandleCtx cross-errors
  it "rejects next-with-value inside for (ForCtx)" $ do
    shouldFail "agent main() { for (let x in xs) { next 42; } }"

  it "accepts bare next inside request handler (defaults to next null)" $ do
    -- Bare `next` is shorthand for `next null` (the requestor is resumed
    -- with null). Same convention as bare `break` / bare `return`.
    _ <-
      shouldSucceed $
        mconcat
          [ "agent main() {\n",
            "  handle {\n",
            "    request get() { next; }\n",
            "  }\n",
            "  result\n",
            "}"
          ]
    pure ()

  it "accepts bare break inside request handler (defaults to break null)" $ do
    _ <-
      shouldSucceed $
        mconcat
          [ "agent main() {\n",
            "  handle {\n",
            "    request get() { break; }\n",
            "  }\n",
            "  result\n",
            "}"
          ]
    pure ()

  it "accepts bare break inside for (defaults to break null)" $ do
    _ <- shouldSucceed "agent main() { for (let x in xs) { break; } }"
    pure ()

  it "accepts bare return inside agent body (defaults to return null)" $ do
    _ <- shouldSucceed "agent main() { return; }"
    pure ()

  -- Context-aware AST checks
  it "for-next inside for is StatementForNext" $ do
    m <- shouldSucceed "agent main() { for (let x in xs) { next; } }"
    case head (decls m) of
      DeclarationAgent a ->
        case a.body.returnExpression of
          Just (ExpressionFor fe) ->
            case fe.body.statements of
              [StatementForNext _] -> pure ()
              _ -> expectationFailure "expected StatementForNext"
          _ -> expectationFailure "expected for expr"
      _ -> expectationFailure "expected agent"

  it "for-break inside for is StatementForBreak" $ do
    m <- shouldSucceed "agent main() { for (let x in xs) { break 0; } }"
    case head (decls m) of
      DeclarationAgent a ->
        case a.body.returnExpression of
          Just (ExpressionFor fe) ->
            case fe.body.statements of
              [StatementForBreak _] -> pure ()
              _ -> expectationFailure "expected StatementForBreak"
          _ -> expectationFailure "expected for expr"
      _ -> expectationFailure "expected agent"

  it "next-with-value in request handler is StatementNext" $ do
    m <-
      shouldSucceed $
        mconcat
          [ "agent main() {\n",
            "  handle {\n",
            "    request get() { next 42; }\n",
            "  }\n",
            "  result\n",
            "}"
          ]
    case head (decls m) of
      DeclarationAgent a ->
        case a.body.returnExpression of
          Just (ExpressionHandle he) ->
            case he.handlers of
              [rh] ->
                case rh.body.statements of
                  [StatementNext _] -> pure ()
                  _ -> expectationFailure "expected StatementNext"
              _ -> expectationFailure "expected one handler"
          _ -> expectationFailure "expected handle expression"
      _ -> expectationFailure "expected agent"

  it "break in request handler is StatementBreak" $ do
    m <-
      shouldSucceed $
        mconcat
          [ "agent main() {\n",
            "  handle {\n",
            "    request get() { break 0; }\n",
            "  }\n",
            "  result\n",
            "}"
          ]
    case head (decls m) of
      DeclarationAgent a ->
        case a.body.returnExpression of
          Just (ExpressionHandle he) ->
            case he.handlers of
              [rh] ->
                case rh.body.statements of
                  [StatementBreak _] -> pure ()
                  _ -> expectationFailure "expected StatementBreak"
              _ -> expectationFailure "expected one handler"
          _ -> expectationFailure "expected handle expression"
      _ -> expectationFailure "expected agent"

-- ---------------------------------------------------------------------------
-- Declarations
-- ---------------------------------------------------------------------------

declarations :: Spec
declarations = describe "declarations" $ do
  it "parses minimal agent" $ do
    _ <- shouldSucceed "agent foo() { 1 }"
    pure ()

  it "parses agent with return type" $ do
    _ <- shouldSucceed "agent foo() -> integer { 1 }"
    pure ()

  it "parses agent with params" $ do
    _ <- shouldSucceed "agent foo(x: integer, y: integer) -> integer { x }"
    pure ()

  it "parses agent with label=pattern param" $ do
    _ <- shouldSucceed "agent foo(input = x: integer) -> integer { x }"
    pure ()

  it "parses agent with requests" $ do
    _ <- shouldSucceed "agent foo() with req1, req2 { 1 }"
    pure ()

  it "parses agent with annotation" $ do
    _ <- shouldSucceed "@\"does something\" agent foo() { 1 }"
    pure ()

  it "parses agent with multiline annotation" $ do
    _ <-
      shouldSucceed
        "@\"\"\"\ndoes something\n\"\"\" agent foo() { 1 }"
    pure ()

  it "parses agent with annotation on separate line from declaration" $ do
    _ <-
      shouldSucceed
        "@\"does something\"\nagent foo() { 1 }"
    pure ()

  it "parses agent with multiline annotation on separate lines from declaration" $ do
    _ <-
      shouldSucceed
        "@\"\"\"\ndoes something\n\"\"\"\nagent foo() { 1 }"
    pure ()

  it "parses agent param with annotation" $ do
    _ <-
      shouldSucceed
        "agent foo(@\"x param\" x: integer, @\"y param\" y: integer) -> integer { x }"
    pure ()

  it "parses agent labeled param with annotation" $ do
    _ <- shouldSucceed "agent foo(@\"input\" input = x: integer) -> integer { x }"
    pure ()

  it "parses request declaration" $ do
    _ <- shouldSucceed "request get(prompt: string) -> string"
    pure ()

  it "parses request param with annotation" $ do
    _ <- shouldSucceed "request get(@\"prompt\" prompt: string) -> string"
    pure ()

  it "parses external" $ do
    _ <- shouldSucceed "external ask(prompt: string) -> string with ai_req from \"FFI:lib.ask\""
    pure ()

  it "parses external with multiple requests" $ do
    _ <- shouldSucceed "external ask(prompt: string) -> string with ai_req, log_req from \"FFI:lib.ask\""
    pure ()

  it "parses external with annotation" $ do
    _ <- shouldSucceed "@\"external ai\" external ask(prompt: string) -> string with ai_req from \"FFI:lib.ask\""
    pure ()

  it "parses data with no parameters" $ do
    _ <- shouldSucceed "data foo()"
    pure ()

  it "parses data with one parameter" $ do
    _ <- shouldSucceed "data circle(radius: number)"
    pure ()

  it "parses data with multiple parameters" $ do
    _ <- shouldSucceed "data rect(w: number, h: number)"
    pure ()

  it "parses data with trailing comma" $ do
    _ <- shouldSucceed "data foo(x: integer,)"
    pure ()

  it "parses data with annotation" $ do
    _ <- shouldSucceed "@\"json doc\" data circle(radius: number)"
    pure ()

  it "rejects data without parens" $ do
    shouldFail "data foo"

  it "parses type synonym (single type)" $ do
    _ <- shouldSucceed "type t = integer"
    pure ()

  it "parses type synonym union" $ do
    m <- shouldSucceed "type maybe_int = nothing | just"
    case head (decls m) of
      DeclarationTypeSynonym ts -> do
        nameText ts.name `shouldBe` "maybe_int"
        case ts.rhs of
          TypeUnion u -> length u.branches `shouldBe` 2
          _ -> expectationFailure "expected union rhs"
      _ -> expectationFailure "expected type synonym"

  it "parses type synonym with literal types" $ do
    m <- shouldSucceed "type status = \"ok\" | \"err\" | null"
    case head (decls m) of
      DeclarationTypeSynonym ts -> case ts.rhs of
        TypeUnion u -> length u.branches `shouldBe` 3
        _ -> expectationFailure "expected union rhs"
      _ -> expectationFailure "expected type synonym"

  it "parses type synonym with integer/boolean literals" $ do
    _ <- shouldSucceed "type t = 200 | 404 | true | false"
    pure ()

  it "type synonym allows trailing pipe" $ do
    _ <- shouldSucceed "type t = a | b |"
    pure ()

  it "rejects type synonym with leading pipe" $ do
    shouldFail "type t = | a | b"

  it "union has lower precedence than function (parses as (a|b) -> c)" $ do
    -- agent 構文は `agent (...) -> ret` の形。
    -- ここでは function を含む union が外側で union として括れることを確認する。
    m <- shouldSucceed "type t = integer | agent (x: integer) -> integer"
    case head (decls m) of
      DeclarationTypeSynonym ts -> case ts.rhs of
        TypeUnion u -> length u.branches `shouldBe` 2
        _ -> expectationFailure "expected union rhs"
      _ -> expectationFailure "expected type synonym"

  it "union inside array (array of union, not union of arrays)" $ do
    m <- shouldSucceed "type t = array[integer | string]"
    case head (decls m) of
      DeclarationTypeSynonym ts -> case ts.rhs of
        TypeArray a -> case a.elementType of
          TypeUnion _ -> pure ()
          _ -> expectationFailure "expected union as array element"
        _ -> expectationFailure "expected array type"
      _ -> expectationFailure "expected type synonym"

  it "parses import" $ do
    m <- shouldSucceed "import lib.math"
    case head (decls m) of
      DeclarationImport i -> case i.kind of
        ImportModule mn al -> do
          mn `shouldBe` "lib.math"
          isNothing al `shouldBe` True
        _ -> expectationFailure "expected ImportModule"
      _ -> expectationFailure "expected import"

  it "parses import with alias" $ do
    m <- shouldSucceed "import lib.math as math"
    case head (decls m) of
      DeclarationImport i -> case i.kind of
        ImportModule mn (Just al) -> do
          mn `shouldBe` "lib.math"
          al `shouldBe` "math"
        _ -> expectationFailure "expected ImportModule with alias"
      _ -> expectationFailure "expected import"

  it "parses import with names" $ do
    m <- shouldSucceed "import { sqrt, abs } from lib.math"
    case head (decls m) of
      DeclarationImport i -> case i.kind of
        ImportNames its mn -> do
          fmap (.name) its `shouldBe` ["sqrt", "abs"]
          fmap (.kind) its `shouldBe` [ImportItemValue, ImportItemValue]
          mn `shouldBe` "lib.math"
        _ -> expectationFailure "expected ImportNames"
      _ -> expectationFailure "expected import"

  it "parses import with type-prefixed names" $ do
    m <- shouldSucceed "import { type Foo, bar, type Baz } from lib.math"
    case head (decls m) of
      DeclarationImport i -> case i.kind of
        ImportNames its mn -> do
          fmap (.name) its `shouldBe` ["Foo", "bar", "Baz"]
          fmap (.kind) its `shouldBe` [ImportItemType, ImportItemValue, ImportItemType]
          mn `shouldBe` "lib.math"
        _ -> expectationFailure "expected ImportNames"
      _ -> expectationFailure "expected import"

  it "agent body has correct name and returnExpr" $ do
    m <- shouldSucceed "agent foo(x: integer) -> integer { x }"
    case head (decls m) of
      DeclarationAgent a -> do
        nameText a.name `shouldBe` "foo"
        isJust a.body.returnExpression `shouldBe` True
      _ -> expectationFailure "expected agent"

  it "rejects missing -> in request declaration" $ do
    shouldFail "request foo(x: integer) integer"

  it "rejects agent without body" $ do
    shouldFail "agent foo()"

  it "parses agent statement in block" $ do
    _ <- shouldSucceed "agent main() {\n  agent inner() { 1 }\n  inner()\n}"
    pure ()

  it "parses agent statement with return type" $ do
    _ <- shouldSucceed "agent main() {\n  agent inner() -> integer { 1 }\n  inner()\n}"
    pure ()

  it "parses multiline agent with auto-inserted semis" $ do
    _ <- shouldSucceed "agent main() {\n  let x = 1\n  let y = 2\n  x + y\n}"
    pure ()

  it "parses multiline call with trailing comma" $ do
    _ <- shouldSucceed "agent main() {\n  foo(\n    x = 1,\n    y = 2,\n  )\n}"
    pure ()

  it "parses multiline declarations separated by newlines" $ do
    m <-
      shouldSucceed $
        mconcat
          [ "request greet(name: string) -> string\n",
            "agent foo() { 1 }\n",
            "agent bar() { 2 }"
          ]
    length (decls m) `shouldBe` 3

  it "parses multiple declarations" $ do
    m <-
      shouldSucceed $
        mconcat
          [ "request greet(name: string) -> string\n",
            "agent main(name: string) -> string { greet(name) }"
          ]
    length (decls m) `shouldBe` 2

-- ---------------------------------------------------------------------------
-- Handle expression
-- ---------------------------------------------------------------------------

handleExpression :: Spec
handleExpression = describe "handle expression" $ do
  it "parses basic handle with handler" $ do
    _ <-
      shouldSucceed $
        mconcat
          [ "agent main() {\n",
            "  handle {\n",
            "    request get() { break 1; }\n",
            "  }\n",
            "  result\n",
            "}"
          ]
    pure ()

  it "parses handle with qualified handler (request module.name)" $ do
    m <-
      shouldSucceed $
        mconcat
          [ "agent main() {\n",
            "  handle {\n",
            "    request io.read() { break 42; }\n",
            "  }\n",
            "  result\n",
            "}"
          ]
    case head (decls m) of
      DeclarationAgent a -> case a.body.returnExpression of
        Just (ExpressionHandle he) -> case he.handlers of
          [h] -> do
            fmap nameText h.moduleQualifier `shouldBe` Just "io"
            nameText h.name `shouldBe` "read"
          _ -> expectationFailure "expected one handler"
        _ -> expectationFailure "expected handle expression"
      _ -> expectationFailure "expected agent"

  it "parses handle with bare handler keeps moduleQualifier as Nothing" $ do
    m <-
      shouldSucceed $
        mconcat
          [ "agent main() {\n",
            "  handle {\n",
            "    request get() { break 42; }\n",
            "  }\n",
            "  result\n",
            "}"
          ]
    case head (decls m) of
      DeclarationAgent a -> case a.body.returnExpression of
        Just (ExpressionHandle he) -> case he.handlers of
          [h] -> do
            isNothing h.moduleQualifier `shouldBe` True
            nameText h.name `shouldBe` "get"
          _ -> expectationFailure "expected one handler"
        _ -> expectationFailure "expected handle expression"
      _ -> expectationFailure "expected agent"

  it "parses handle with state variables" $ do
    _ <-
      shouldSucceed $
        mconcat
          [ "agent main() {\n",
            "  handle (var count: integer = 0) {\n",
            "    request inc() { next null with { count = count + 1 }; }\n",
            "  }\n",
            "  result\n",
            "}"
          ]
    pure ()

  it "parses handle with multiple state variables" $ do
    _ <-
      shouldSucceed $
        mconcat
          [ "agent main() {\n",
            "  handle (var x = 0, var y = 0) {\n",
            "    request addX() { next null with { x = x + 1 }; }\n",
            "    request addY() { next null with { y = y + 1 }; }\n",
            "  }\n",
            "  result\n",
            "}"
          ]
    pure ()

  it "parses handle with then clause (no pattern)" $ do
    m <-
      shouldSucceed $
        mconcat
          [ "agent main() {\n",
            "  handle {\n",
            "    request get() { break 1; }\n",
            "  } then { 0 }\n",
            "  result\n",
            "}"
          ]
    case head (decls m) of
      DeclarationAgent a ->
        case a.body.returnExpression of
          Just (ExpressionHandle he) ->
            case he.thenClause of
              Just (Nothing, _) -> pure ()
              Just (Just _, _) -> expectationFailure "expected pattern absent"
              Nothing -> expectationFailure "expected then clause"
          _ -> expectationFailure "expected handle expression"
      _ -> expectationFailure "expected agent"

  it "parses handle with then clause (with pattern)" $ do
    m <-
      shouldSucceed $
        mconcat
          [ "agent main() {\n",
            "  handle {\n",
            "    request get() { break 1; }\n",
            "  } then(p) { p }\n",
            "  result\n",
            "}"
          ]
    case head (decls m) of
      DeclarationAgent a ->
        case a.body.returnExpression of
          Just (ExpressionHandle he) ->
            case he.thenClause of
              Just (Just _, _) -> pure ()
              Just (Nothing, _) -> expectationFailure "expected pattern present"
              Nothing -> expectationFailure "expected then clause"
          _ -> expectationFailure "expected handle expression"
      _ -> expectationFailure "expected agent"

  it "rejects then on different line from preceding `}`" $ do
    shouldFail $
      mconcat
        [ "agent main() {\n",
          "  handle {\n",
          "    request get() { break 1; }\n",
          "  }\n",
          "  then(p) { p }\n",
          "  result\n",
          "}"
        ]

  it "parses handle handler with return type" $ do
    _ <-
      shouldSucceed $
        mconcat
          [ "agent main() {\n",
            "  handle {\n",
            "    request get() -> string { break \"hello\"; }\n",
            "  }\n",
            "  result\n",
            "}"
          ]
    pure ()

  it "parses parallel handle" $ do
    _ <-
      shouldSucceed $
        mconcat
          [ "agent main() {\n",
            "  parallel handle {\n",
            "    request get() { break 1; }\n",
            "  }\n",
            "  result\n",
            "}"
          ]
    pure ()

-- ---------------------------------------------------------------------------
-- Patterns
-- ---------------------------------------------------------------------------

patterns :: Spec
patterns = describe "patterns" $ do
  it "parses wildcard" $ do
    _ <- shouldSucceed "agent main() { let _ = x; }"
    pure ()

  it "parses var pattern without annotation" $ do
    _ <- shouldSucceed "agent main() { let x = 1; }"
    pure ()

  it "parses var pattern with annotation" $ do
    _ <- shouldSucceed "agent main() { let x: integer = 1; }"
    pure ()

  it "parses constructor pattern" $ do
    _ <-
      shouldSucceed $
        mconcat
          [ "agent main() {",
            "  match (s) { case circle(r = r) => { r } }",
            "}"
          ]
    pure ()

  it "parses tuple pattern" $ do
    _ <-
      shouldSucceed $
        mconcat
          [ "agent main() {",
            "  match (p) { case (x, y) => { x } }",
            "}"
          ]
    pure ()

  it "tuple pattern has sourceSpan" $ do
    m <-
      shouldSucceed $
        mconcat
          [ "agent main() {",
            "  match (p) { case (x, y) => { x } }",
            "}"
          ]
    case head (decls m) of
      DeclarationAgent a -> case a.body.returnExpression of
        Just (ExpressionMatch me) -> case me.cases of
          [arm] -> case arm.pattern of
            PatternTuple tp -> do
              length tp.elements `shouldBe` 2
              tp.sourceSpan.start.line `shouldBe` 1
            _ -> expectationFailure "expected tuple pattern"
          _ -> expectationFailure "expected one case"
        _ -> expectationFailure "expected match"
      _ -> expectationFailure "expected agent"

  it "parses literal pattern" $ do
    _ <- shouldSucceed "agent main() { match (x) { case 0 => { true } } }"
    pure ()

  it "parses nested constructor pattern" $ do
    _ <-
      shouldSucceed $
        mconcat
          [ "agent main() {",
            "  match (s) { case outer(field = inner(x)) => { x } }",
            "}"
          ]
    pure ()

  it "parses constructor pattern sugar (no labels)" $ do
    _ <-
      shouldSucceed $
        mconcat
          [ "agent main() {",
            "  match (s) { case circle(r) => { r } }",
            "}"
          ]
    pure ()

  it "parses typed wildcard in agent param" $ do
    _ <- shouldSucceed "agent foo(input = _: integer) -> integer { 0 }"
    pure ()

  it "parses type-guard pattern integer(x)" $ do
    _ <-
      shouldSucceed
        "agent main(v: unknown) { match (v) { case integer(n) => { n } case _ => { 0 } } }"
    pure ()

  it "parses type-guard pattern agent(f)" $ do
    _ <-
      shouldSucceed
        "agent main(v: unknown) { match (v) { case agent(f) => { 1 } case _ => { 0 } } }"
    pure ()

  it "parses record pattern with single label" $ do
    _ <-
      shouldSucceed
        "agent main(v: unknown) { match (v) { case { name = n } => { n } case _ => { 0 } } }"
    pure ()

  it "parses record pattern with multiple labels" $ do
    _ <-
      shouldSucceed $
        mconcat
          [ "agent main(v: unknown) {",
            "  match (v) {",
            "    case { name = string(s), age = integer(a) } => { s }",
            "    case _ => { \"none\" }",
            "  }",
            "}"
          ]
    pure ()

  it "record pattern AST carries entries with the right keys" $ do
    m <-
      shouldSucceed
        "agent main(v: unknown) { match (v) { case { name = n, age = a } => { n } case _ => { \"x\" } } }"
    case head (decls m) of
      DeclarationAgent a -> case a.body.returnExpression of
        Just (ExpressionMatch me) -> case me.cases of
          (arm : _) -> case arm.pattern of
            PatternRecord rp -> map fst rp.entries `shouldBe` ["name", "age"]
            _ -> expectationFailure "expected record pattern"
          _ -> expectationFailure "expected at least one case"
        _ -> expectationFailure "expected match"
      _ -> expectationFailure "expected agent"

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

types :: Spec
types = describe "types" $ do
  it "parses primitive types" $ do
    _ <-
      shouldSucceed
        "agent main(x: integer, y: number, z: string, b: boolean) { x }"
    pure ()

  it "parses null type" $ do
    _ <- shouldSucceed "agent main() -> null { null }"
    pure ()

  it "parses named type" $ do
    _ <- shouldSucceed "agent main() -> mytype { null }"
    pure ()

  it "parses bare agent (function-any) type" $ do
    _ <- shouldSucceed "agent main(f: agent) { 1 }"
    pure ()

  it "bare agent yields TypeFunctionAny, not parameterised TypeFunction" $ do
    m <- shouldSucceed "agent main(f: agent) { 1 }"
    case head (decls m) of
      DeclarationAgent a -> case a.parameters of
        [pr] -> case pr.pattern of
          PatternVariable v -> case v.typeAnnotation of
            Just (TypeFunctionAny _) -> pure ()
            _ -> expectationFailure "expected TypeFunctionAny"
          _ -> expectationFailure "expected variable pattern"
        _ -> expectationFailure "expected exactly one parameter"
      _ -> expectationFailure "expected agent"

  it "parses zero-arg agent type" $ do
    _ <- shouldSucceed "agent main(f: agent () -> integer) { f() }"
    pure ()

  it "parses agent type" $ do
    _ <- shouldSucceed "agent main(f: agent (x: integer) -> integer) { f(x = 1) }"
    pure ()

  it "agent type AST captures parameter list and return type" $ do
    m <- shouldSucceed "agent main(f: agent (x: integer) -> string) { 1 }"
    case head (decls m) of
      DeclarationAgent a -> case a.parameters of
        [pr] -> case pr.pattern of
          PatternVariable v -> case v.typeAnnotation of
            Just (TypeFunction ft) -> do
              length ft.parameterTypes `shouldBe` 1
              case ft.parameterTypes of
                [(label, _)] -> label `shouldBe` "x"
                _ -> expectationFailure "expected one named parameter"
              case ft.returnType of
                TypePrimitive _ -> pure ()
                _ -> expectationFailure "expected primitive return type"
            _ -> expectationFailure "expected TypeFunction"
          _ -> expectationFailure "expected variable pattern"
        _ -> expectationFailure "expected exactly one parameter"
      _ -> expectationFailure "expected agent"

  it "parses agent type with requests" $ do
    _ <-
      shouldSucceed
        "agent main(f: agent (x: integer) -> integer with myreq) { f(x = 1) }"
    pure ()

  it "parses agent type with multiple requests" $ do
    _ <-
      shouldSucceed
        "agent main(f: agent (x: integer) -> integer with req1, req2) { f(x = 1) }"
    pure ()

  it "parses never type as return type" $ do
    _ <- shouldSucceed "agent main() -> never { main() }"
    pure ()

  it "parses unknown type as parameter type" $ do
    _ <- shouldSucceed "agent main(x: unknown) { null }"
    pure ()

  it "parses never inside union" $ do
    _ <- shouldSucceed "agent main(x: string | never) { null }"
    pure ()

  it "parses unknown inside union" $ do
    _ <- shouldSucceed "agent main(x: integer | unknown) { null }"
    pure ()

  it "parses never as function-parameter type in function-type position" $ do
    _ <- shouldSucceed "agent main(f: agent (x: never) -> integer) { null }"
    pure ()

  it "parses unknown as array element" $ do
    _ <- shouldSucceed "agent main(xs: array[unknown]) { null }"
    pure ()

-- ---------------------------------------------------------------------------
-- Auto-inserted semicolons (Go-style rule)
-- ---------------------------------------------------------------------------

autoSemicolon :: Spec
autoSemicolon = describe "auto-inserted semicolons" $ do
  it "inserts semi after identifier at EOL" $ do
    _ <- shouldSucceed "agent main() {\n  let x = 1\n  x\n}"
    pure ()

  it "inserts semi after integer literal at EOL" $ do
    _ <- shouldSucceed "agent main() {\n  let x = 42\n  x\n}"
    pure ()

  it "inserts semi after float literal at EOL" $ do
    _ <- shouldSucceed "agent main() {\n  let x = 3.14\n  x\n}"
    pure ()

  it "inserts semi after string literal at EOL" $ do
    _ <- shouldSucceed "agent main() {\n  let x = \"hello\"\n  x\n}"
    pure ()

  it "inserts semi after template literal at EOL" $ do
    _ <- shouldSucceed "agent main() {\n  let x = f\"hi\"\n  x\n}"
    pure ()

  it "inserts semi after closing paren at EOL" $ do
    _ <- shouldSucceed "agent main() {\n  foo()\n  bar()\n}"
    pure ()

  it "inserts semi after closing brace at EOL" $ do
    _ <- shouldSucceed "agent main() {\n  if (a) { 1 }\n  2\n}"
    pure ()

  it "inserts semi after closing bracket at EOL" $ do
    _ <- shouldSucceed "agent main() {\n  let xs = [1, 2, 3]\n  xs\n}"
    pure ()

  it "inserts semi after return keyword expression at EOL" $ do
    _ <- shouldSucceed "agent main() {\n  return 1\n}"
    pure ()

  it "inserts semi after null/true/false at EOL" $ do
    _ <- shouldSucceed "agent main() {\n  let a = null\n  let b = true\n  let c = false\n  a\n}"
    pure ()

  it "inserts semi after type keyword at EOL (return type on next block line)" $ do
    _ <-
      shouldSucceed $
        mconcat
          [ "request greet(name: string) -> string\n",
            "agent main() { 1 }"
          ]
    pure ()

  -- NO insertion in continuation contexts
  it "no semi after comma (continuation)" $ do
    _ <- shouldSucceed "agent main() {\n  foo(\n    x = 1,\n    y = 2,\n  )\n}"
    pure ()

  it "no semi after opening bracket (continuation)" $ do
    _ <- shouldSucceed "agent main() {\n  let xs = [\n    1,\n    2,\n    3,\n  ]\n  xs\n}"
    pure ()

  it "no semi after binary operator at EOL (continuation)" $ do
    _ <- shouldSucceed "agent main() {\n  let x = 1 +\n    2\n  x\n}"
    pure ()

  it "no semi after = (continuation)" $ do
    _ <- shouldSucceed "agent main() {\n  let x =\n    1\n  x\n}"
    pure ()

  -- Language conventions
  it "else on same line as closing brace" $ do
    _ <- shouldSucceed "agent main() {\n  if (a) {\n    1\n  } else {\n    2\n  }\n}"
    pure ()

  it "then on same line as closing brace (for)" $ do
    _ <- shouldSucceed "agent main() {\n  for (let x in xs) {\n    x\n  } then {\n    null\n  }\n}"
    pure ()

  it "then on same line as closing brace (handle)" $ do
    _ <-
      shouldSucceed $
        mconcat
          [ "agent main() {\n",
            "  handle {\n",
            "    request get() { next 1; }\n",
            "  } then (x) {\n",
            "    x\n",
            "  }\n",
            "  result\n",
            "}"
          ]
    pure ()

  -- Multiple blank lines between statements
  it "allows blank lines between statements" $ do
    _ <- shouldSucceed "agent main() {\n  let x = 1\n\n  let y = 2\n\n  x + y\n}"
    pure ()

  -- Comments don't confuse insertion
  it "line comment at EOL does not break insertion" $ do
    _ <- shouldSucceed "agent main() {\n  let x = 1 // first\n  let y = 2 // second\n  x + y\n}"
    pure ()

  it "block comment mid-line works" $ do
    _ <- shouldSucceed "agent main() {\n  let x = /* inline */ 1\n  x\n}"
    pure ()

  it "nested block comments work" $ do
    _ <- shouldSucceed "agent main() {\n  let x = /* outer /* inner */ more */ 1\n  x\n}"
    pure ()

  -- Multiline strings don't trigger insertion inside content
  it "multiline string content with newlines does not get extra semis" $ do
    _ <- shouldSucceed "agent main() {\n  let s = \"\"\"\nline1\nline2\n\"\"\"\n  s\n}"
    pure ()

  -- Multiple declarations at top level
  it "multiple top-level declarations separated by newlines" $ do
    m <-
      shouldSucceed $
        mconcat
          [ "request greet(name: string) -> string\n",
            "agent foo() { 1 }\n",
            "agent bar() { 2 }\n"
          ]
    length (decls m) `shouldBe` 3

  -- Explicit semicolons still work and can mix with auto
  it "explicit semi on same line" $ do
    _ <- shouldSucceed "agent main() { let x = 1; x }"
    pure ()

  it "mixes explicit semi and auto-inserted" $ do
    _ <- shouldSucceed "agent main() {\n  let x = 1;\n  let y = 2\n  x + y\n}"
    pure ()

  -- Nested agent statement
  it "nested agent statement with auto-inserted semi after body" $ do
    _ <- shouldSucceed "agent main() {\n  agent inner() { 1 }\n  inner()\n}"
    pure ()

-- ---------------------------------------------------------------------------
-- Escape sequences (JSON-compatible + \$)
-- ---------------------------------------------------------------------------

escapeSequences :: Spec
escapeSequences = describe "escape sequences" $ do
  it "accepts \\n" $ do
    _ <- shouldSucceed "agent main() { \"a\\nb\" }"
    pure ()

  it "accepts \\t" $ do
    _ <- shouldSucceed "agent main() { \"a\\tb\" }"
    pure ()

  it "accepts \\r" $ do
    _ <- shouldSucceed "agent main() { \"a\\rb\" }"
    pure ()

  it "accepts \\b (backspace)" $ do
    _ <- shouldSucceed "agent main() { \"a\\bb\" }"
    pure ()

  it "accepts \\f (form feed)" $ do
    _ <- shouldSucceed "agent main() { \"a\\fb\" }"
    pure ()

  it "accepts \\\\" $ do
    _ <- shouldSucceed "agent main() { \"a\\\\b\" }"
    pure ()

  it "accepts \\\"" $ do
    _ <- shouldSucceed "agent main() { \"a\\\"b\" }"
    pure ()

  it "accepts \\/ (forward slash)" $ do
    _ <- shouldSucceed "agent main() { \"a\\/b\" }"
    pure ()

  it "accepts \\$" $ do
    _ <- shouldSucceed "agent main() { f\"price: \\$42\" }"
    pure ()

  it "accepts \\uXXXX" $ do
    _ <- shouldSucceed "agent main() { \"unicode: \\u3042\" }"
    pure ()

  it "rejects unknown escape \\q" $ do
    shouldFail "agent main() { \"oops: \\q\" }"

  it "rejects short \\u escape" $ do
    shouldFail "agent main() { \"oops: \\u12\" }"

  it "raw non-ASCII characters pass through" $ do
    _ <- shouldSucceed "agent main() { \"hello あ world\" }"
    pure ()

-- ---------------------------------------------------------------------------
-- Source spans
-- ---------------------------------------------------------------------------

sourceSpans :: Spec
sourceSpans = describe "source spans" $ do
  it "literal expression has a non-degenerate span" $ do
    e <- parseExpr "42"
    let s = sourceSpanOf e
    s.start.line `shouldBe` 1
    s.end.column `shouldSatisfy` (> s.start.column)

  it "var expression has a non-degenerate span" $ do
    e <- parseExpr "someVariable"
    let s = sourceSpanOf e
    s.end.column - s.start.column `shouldBe` T.length "someVariable"

  it "call expression span covers the entire call" $ do
    e <- parseExpr "foo(x, y)"
    let s = sourceSpanOf e
    s.start.column `shouldSatisfy` (< s.end.column)

  it "for expression span covers for-then" $ do
    e <- parseExpr "for (let x in xs) { x } then { null }"
    let s = sourceSpanOf e
    s.start.line `shouldBe` 1

  it "ForInBinding has a non-degenerate span" $ do
    e <- parseExpr "for (let x in xs) { x }"
    case e of
      ExpressionFor fe -> case fe.inBindings of
        [b] -> b.sourceSpan.start.column `shouldSatisfy` (< b.sourceSpan.end.column)
        _ -> expectationFailure "expected one in binding"
      _ -> expectationFailure "expected for"

-- ---------------------------------------------------------------------------
-- `} newline else/then` is a syntax error
-- ---------------------------------------------------------------------------

sameLineBlockKeyword :: Spec
sameLineBlockKeyword = describe "same-line block keyword rule" $ do
  it "rejects else on the line after }" $ do
    shouldFailWith
      "agent main() { if (a) { 1 }\nelse { 2 } }"
      "must be on the same line as the preceding '}'"

  it "rejects then on the line after }" $ do
    shouldFailWith
      "agent main() { for (let x in xs) { x }\nthen { null } }"
      "must be on the same line as the preceding '}'"

  it "rejects then (handle) on the line after }" $ do
    shouldFailWith
      ( mconcat
          [ "agent main() {\n",
            "  handle {\n",
            "    request get() { next 1; }\n",
            "  }\n",
            "  then (x) {\n",
            "    x\n",
            "  }\n",
            "  result\n",
            "}"
          ]
      )
      "must be on the same line as the preceding '}'"

  it "accepts else on the same line as }" $ do
    _ <- shouldSucceed "agent main() { if (a) { 1 } else { 2 } }"
    pure ()

  it "accepts then on the same line as }" $ do
    _ <- shouldSucceed "agent main() { for (let x in xs) { x } then { null } }"
    pure ()

  it "accepts then (handle) on the same line as }" $ do
    _ <-
      shouldSucceed $
        mconcat
          [ "agent main() {\n",
            "  handle {\n",
            "    request get() { next 1; }\n",
            "  } then (x) {\n",
            "    x\n",
            "  }\n",
            "  result\n",
            "}"
          ]
    pure ()

-- ---------------------------------------------------------------------------
-- Array and tuple types
-- ---------------------------------------------------------------------------

arrayAndTupleTypes :: Spec
arrayAndTupleTypes = describe "array and tuple types" $ do
  it "parses array[integer] in param type" $ do
    _ <- shouldSucceed "agent main(xs: array[integer]) { 1 }"
    pure ()

  it "array[T] yields TypeArray node" $ do
    m <- shouldSucceed "agent main(xs: array[integer]) { 1 }"
    case head (decls m) of
      DeclarationAgent a -> case a.parameters of
        [p] -> case p.pattern of
          PatternVariable v -> case v.typeAnnotation of
            Just (TypeArray n) -> case n.elementType of
              TypePrimitive prim -> prim.kind `shouldBe` PrimitiveTypeKindInteger
              _ -> expectationFailure "expected primitive element type"
            _ -> expectationFailure "expected TypeArray"
          _ -> expectationFailure "expected variable pattern"
        _ -> expectationFailure "expected one parameter"
      _ -> expectationFailure "expected agent"

  it "parses nested array[array[string]]" $ do
    _ <- shouldSucceed "agent main(xss: array[array[string]]) { 1 }"
    pure ()

  it "parses tuple type (integer, string)" $ do
    _ <- shouldSucceed "agent main(p: (integer, string)) { 1 }"
    pure ()

  it "tuple type yields TypeTuple node" $ do
    m <- shouldSucceed "agent main(p: (integer, string)) { 1 }"
    case head (decls m) of
      DeclarationAgent a -> case a.parameters of
        [pr] -> case pr.pattern of
          PatternVariable v -> case v.typeAnnotation of
            Just (TypeTuple n) -> length n.elementTypes `shouldBe` 2
            _ -> expectationFailure "expected TypeTuple"
          _ -> expectationFailure "expected variable pattern"
        _ -> expectationFailure "expected one parameter"
      _ -> expectationFailure "expected agent"

  it "parses tuple type with trailing comma" $ do
    _ <- shouldSucceed "agent main(p: (integer, string,)) { 1 }"
    pure ()

  it "parses grouped type (integer) as integer" $ do
    m <- shouldSucceed "agent main(x: (integer)) { 1 }"
    case head (decls m) of
      DeclarationAgent a -> case a.parameters of
        [pr] -> case pr.pattern of
          PatternVariable v -> case v.typeAnnotation of
            Just (TypePrimitive prim) -> prim.kind `shouldBe` PrimitiveTypeKindInteger
            _ -> expectationFailure "expected grouped type to collapse to primitive"
          _ -> expectationFailure "expected variable pattern"
        _ -> expectationFailure "expected one parameter"
      _ -> expectationFailure "expected agent"

  it "parses nested grouped type ((integer))" $ do
    _ <- shouldSucceed "agent main(x: ((integer))) { 1 }"
    pure ()

  it "parses agent type with tuple parameter type" $ do
    _ <- shouldSucceed "agent main(f: agent (p: (integer, string)) -> integer) { 1 }"
    pure ()

  it "parses empty tuple type ()" $ do
    _ <- shouldSucceed "agent main(x: ()) { 1 }"
    pure ()

  it "parses qualified type module.TypeName" $ do
    _ <- shouldSucceed "agent main(x: math.Vector) { 1 }"
    pure ()

  it "qualified type yields TypeQualified node with module and target" $ do
    m <- shouldSucceed "agent main(x: math.Vector) { 1 }"
    case head (decls m) of
      DeclarationAgent a -> case a.parameters of
        [pr] -> case pr.pattern of
          PatternVariable v -> case v.typeAnnotation of
            Just (TypeQualified qn) -> do
              nameText qn.qualifier `shouldBe` "math"
              nameText qn.target `shouldBe` "Vector"
            _ -> expectationFailure "expected TypeQualified"
          _ -> expectationFailure "expected variable pattern"
        _ -> expectationFailure "expected one parameter"
      _ -> expectationFailure "expected agent"

  it "parses qualified type inside array[module.TypeName]" $ do
    _ <- shouldSucceed "agent main(xs: array[lib.Point]) { 1 }"
    pure ()

  it "bare type name still parses as TypeName" $ do
    m <- shouldSucceed "agent main(x: Foo) { 1 }"
    case head (decls m) of
      DeclarationAgent a -> case a.parameters of
        [pr] -> case pr.pattern of
          PatternVariable v -> case v.typeAnnotation of
            Just (TypeName tn) -> nameText tn.name `shouldBe` "Foo"
            _ -> expectationFailure "expected TypeName"
          _ -> expectationFailure "expected variable pattern"
        _ -> expectationFailure "expected one parameter"
      _ -> expectationFailure "expected agent"

-- ---------------------------------------------------------------------------
-- Parentheses grouping across contexts
-- ---------------------------------------------------------------------------

parenthesesGrouping :: Spec
parenthesesGrouping = describe "parentheses grouping" $ do
  it "parses grouped expression (1 + 2)" $ do
    _ <- shouldSucceed "agent main() { (1 + 2) }"
    pure ()

  it "parses grouped pattern (x) as variable pattern" $ do
    m <- shouldSucceed "agent main() { match (s) { case (x) => { x } } }"
    case head (decls m) of
      DeclarationAgent a -> case a.body.returnExpression of
        Just (ExpressionMatch me) -> case me.cases of
          [arm] -> case arm.pattern of
            PatternVariable v -> nameText v.name `shouldBe` "x"
            _ -> expectationFailure "expected grouped to collapse to variable pattern"
          _ -> expectationFailure "expected one case"
        _ -> expectationFailure "expected match"
      _ -> expectationFailure "expected agent"

  it "parses nested grouped pattern ((x, y))" $ do
    m <- shouldSucceed "agent main() { match (s) { case ((x, y)) => { x } } }"
    case head (decls m) of
      DeclarationAgent a -> case a.body.returnExpression of
        Just (ExpressionMatch me) -> case me.cases of
          [arm] -> case arm.pattern of
            PatternTuple tp -> length tp.elements `shouldBe` 2
            _ -> expectationFailure "expected tuple pattern inside grouping"
          _ -> expectationFailure "expected one case"
        _ -> expectationFailure "expected match"
      _ -> expectationFailure "expected agent"

  it "parses doubly grouped pattern (((x)))" $ do
    _ <- shouldSucceed "agent main() { match (s) { case (((x))) => { x } } }"
    pure ()

-- ---------------------------------------------------------------------------
-- Surrogate-pair escape sequences
-- ---------------------------------------------------------------------------

surrogatePairEscape :: Spec
surrogatePairEscape = describe "surrogate pair escape" $ do
  it "accepts surrogate pair \\uD83D\\uDCA9" $ do
    m <- shouldSucceed "agent main() { \"\\uD83D\\uDCA9\" }"
    case head (decls m) of
      DeclarationAgent a ->
        case a.body.returnExpression of
          Just (ExpressionLiteral e) -> e.value `shouldBe` LiteralValueString "\x1F4A9"
          _ -> expectationFailure "expected literal"
      _ -> expectationFailure "expected agent"

  it "rejects unpaired high surrogate" $ do
    shouldFail "agent main() { \"\\uD83D\" }"

  it "rejects unpaired low surrogate" $ do
    shouldFail "agent main() { \"\\uDCA9\" }"

  it "rejects high surrogate followed by non-\\u escape" $ do
    shouldFail "agent main() { \"\\uD83Dx\" }"

-- ---------------------------------------------------------------------------
-- Source span boundaries (strict column checks)
-- ---------------------------------------------------------------------------

spanBoundaries :: Spec
spanBoundaries = describe "source span boundaries" $ do
  it "call expression span end is closing paren + 1" $ do
    -- parseExpr wraps the expression in `agent main() { ... }`, so the body
    -- starts at column 16 (`foo` at 16, `(` at 19, `x` at 20, `)` at 21).
    -- Exclusive end column is one past `)`, i.e. 22.
    e <- parseExpr "foo(x)"
    let s = sourceSpanOf e
    s.start.column `shouldBe` 16
    s.end.column `shouldBe` 22

  it "binary operator span covers left.start to right.end" $ do
    e <- parseExpr "aa + bb"
    case e of
      ExpressionBinaryOperator b -> do
        let s = sourceSpanOf e
        s.start.column `shouldBe` (sourceSpanOf b.left).start.column
        s.end.column `shouldBe` (sourceSpanOf b.right).end.column
      _ -> expectationFailure "expected binop"

  it "multi-line agent span covers first to last line" $ do
    m <- shouldSucceed "agent main() {\n  let x = 1\n  x\n}"
    case head (decls m) of
      DeclarationAgent a -> do
        a.sourceSpan.start.line `shouldBe` 1
        a.sourceSpan.end.line `shouldBe` 4
      _ -> expectationFailure "expected agent"

  it "variable expression end.column - start.column equals name length" $ do
    e <- parseExpr "someVariable"
    let s = sourceSpanOf e
    (s.end.column - s.start.column) `shouldBe` T.length "someVariable"

-- ---------------------------------------------------------------------------
-- Negative declaration cases
-- ---------------------------------------------------------------------------

declarationsNegative :: Spec
declarationsNegative = describe "declaration negative cases" $ do
  it "parses external without 'with' (from clause still required)" $ do
    _ <- shouldSucceed "external ask(prompt: string) -> string from \"FFI:lib.ask\""
    pure ()

  it "rejects external missing the required 'from' clause" $ do
    shouldFail "external ask(prompt: string) -> string"

  it "rejects external whose 'from' spec lacks a colon" $ do
    shouldFail "external ask(prompt: string) -> string from \"lib.ask\""

  it "rejects external whose 'from' spec has an empty endpoint" $ do
    shouldFail "external ask(prompt: string) -> string from \":lib.ask\""

  it "rejects external whose 'from' spec has an empty dispatch name" $ do
    shouldFail "external ask(prompt: string) -> string from \"FFI:\""

-- ---------------------------------------------------------------------------
-- Number literal edge cases
-- ---------------------------------------------------------------------------

numberLiterals :: Spec
numberLiterals = describe "number literals" $ do
  it "parses integer 0" $ do
    _ <- shouldSucceed "agent main() { 0 }"
    pure ()

  it "parses float 3.14" $ do
    _ <- shouldSucceed "agent main() { 3.14 }"
    pure ()

  it "documents current 1. behaviour (parses as 1 then '.')" $ do
    -- `1.` is spec-invalid as a float literal, but the current lexer falls back
    -- to integer `1` + punctuation `.`. `1.x` therefore parses as a field
    -- access expression. This test pins that behaviour.
    _ <- shouldSucceed "agent main() { let x = 1.toString; x }"
    pure ()

-- ---------------------------------------------------------------------------
-- Edge cases
-- ---------------------------------------------------------------------------

edgeCases :: Spec
edgeCases = describe "edge cases" $ do
  it "parses empty module" $ do
    m <- shouldSucceed ""
    length (decls m) `shouldBe` 0

  it "parses module with only whitespace" $ do
    m <- shouldSucceed "\n\n  \n"
    length (decls m) `shouldBe` 0

  it "parses module with only comments" $ do
    m <- shouldSucceed "// just a comment\n/* another */\n"
    length (decls m) `shouldBe` 0

  it "parses template with nested braces (if/else) on one line" $ do
    _ <- shouldSucceed "agent main() { f\"result ${if (a) { 1 } else { 2 }}\" }"
    pure ()

-- ---------------------------------------------------------------------------
-- Multi-line token source spans
-- ---------------------------------------------------------------------------

multilineTokenSpans :: Spec
multilineTokenSpans = describe "multi-line token source spans" $ do
  it "multiline string literal span covers multiple lines" $ do
    e <- parseExpr "\"\"\"\nhello\nworld\n\"\"\""
    case e of
      ExpressionLiteral le -> do
        let s = sourceSpanOf le
        s.end.line `shouldSatisfy` (> s.start.line)
      _ -> expectationFailure "expected literal"

  it "multiline template literal span covers multiple lines" $ do
    e <- parseExpr "f\"\"\"\nhello\nworld\n\"\"\""
    case e of
      ExpressionTemplate te -> do
        let s = sourceSpanOf te
        s.end.line `shouldSatisfy` (> s.start.line)
      _ -> expectationFailure "expected template"

-- ---------------------------------------------------------------------------
-- CRLF handling
-- ---------------------------------------------------------------------------

crlfHandling :: Spec
crlfHandling = describe "CRLF line endings" $ do
  it "parses a CRLF source identical to LF source" $ do
    _ <- shouldSucceed "agent main() {\r\n  let x = 1\r\n  x\r\n}"
    pure ()

  it "auto-inserts semicolons across CRLF newlines" $ do
    -- LF \302\247 CRLF \343\201\247 \345\220\214\343\201\230 AST \343\201\253\343\201\252\343\202\213\343\201\223\343\201\250\343\202\222確認。`x + y\\n` の末尾に仮想 semi が入るため、
    -- statements = [let x; let y; x+y] (3 個)、returnExpression = Nothingとなる。
    m <- shouldSucceed "agent main() {\r\n  let x = 1\r\n  let y = 2\r\n  x + y\r\n}"
    mLf <- shouldSucceed "agent main() {\n  let x = 1\n  let y = 2\n  x + y\n}"
    case (head (decls m), head (decls mLf)) of
      (DeclarationAgent a, DeclarationAgent aLf) -> do
        length a.body.statements `shouldBe` length aLf.body.statements
      _ -> expectationFailure "expected agent"

-- ---------------------------------------------------------------------------
-- Qualified constructor patterns (#9)
-- ---------------------------------------------------------------------------

qualifiedConstructorPatterns :: Spec
qualifiedConstructorPatterns = describe "qualified constructor patterns" $ do
  it "bare ctor(field = pat) parses as constructor pattern" $ do
    m <-
      shouldSucceed $
        mconcat
          [ "agent main() {",
            "  match (s) { case circle(r = r) => { r } }",
            "}"
          ]
    case head (decls m) of
      DeclarationAgent a -> case a.body.returnExpression of
        Just (ExpressionMatch me) -> case me.cases of
          [arm] -> case arm.pattern of
            PatternQualifiedConstructor qc -> do
              isNothing qc.moduleQualifier `shouldBe` True
              nameText qc.constructorName `shouldBe` "circle"
              length qc.parameters `shouldBe` 1
            _ -> expectationFailure "expected qualified constructor pattern"
          _ -> expectationFailure "expected one case"
        _ -> expectationFailure "expected match"
      _ -> expectationFailure "expected agent"

  it "module.ctor(...) parses with module qualifier" $ do
    m <-
      shouldSucceed $
        mconcat
          [ "agent main() {",
            "  match (s) { case lib.circle(r) => { r } }",
            "}"
          ]
    case head (decls m) of
      DeclarationAgent a -> case a.body.returnExpression of
        Just (ExpressionMatch me) -> case me.cases of
          [arm] -> case arm.pattern of
            PatternQualifiedConstructor qc -> do
              fmap nameText qc.moduleQualifier `shouldBe` Just "lib"
              nameText qc.constructorName `shouldBe` "circle"
            _ -> expectationFailure "expected qualified constructor pattern"
          _ -> expectationFailure "expected one case"
        _ -> expectationFailure "expected match"
      _ -> expectationFailure "expected agent"

  it "bare variable pattern (no parens) still works" $ do
    m <-
      shouldSucceed $
        mconcat
          [ "agent main() {",
            "  match (s) { case x => { x } }",
            "}"
          ]
    case head (decls m) of
      DeclarationAgent a -> case a.body.returnExpression of
        Just (ExpressionMatch me) -> case me.cases of
          [arm] -> case arm.pattern of
            PatternVariable v -> nameText v.name `shouldBe` "x"
            _ -> expectationFailure "expected variable pattern"
          _ -> expectationFailure "expected one case"
        _ -> expectationFailure "expected match"
      _ -> expectationFailure "expected agent"

-- ---------------------------------------------------------------------------
-- Multi-line string recovery
-- ---------------------------------------------------------------------------

multilineStringRecovery :: Spec
multilineStringRecovery = describe "multiline string recovery" $ do
  it "unterminated multiline string surfaces LexerErrorUnterminatedString without hard-failing the lexer" $ do
    -- @"""\nabc@ followed by EOF (no closing @"""@). Pre-refactor this
    -- caused 'lexMultilineStringLiteral' to hard-fail because @manyTill@
    -- propagated the EOF failure. With recovery added the lexer
    -- synthesises an empty body and records 'LexerErrorUnterminatedString'.
    let src = "agent main() { \"\"\"\nabc }"
    case parse src of
      Right _ ->
        expectationFailure "expected lexer recovery error to surface, but parse succeeded"
      Left errors ->
        any isUnterminated errors `shouldBe` True
  where
    isUnterminated d = d.code == "K0002"
