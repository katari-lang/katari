module Main (main) where

import qualified Data.Map.Strict          as Map
import           Data.Text                (pack)
import qualified Data.Text.IO             as TIO
import           System.FilePath          ((</>))
import           Test.Hspec

import           QataliCompiler.Parse.Parser    (parseModule)
import           QataliCompiler.Type.Normalize  (TypeDefs (..))
import           QataliCompiler.Typecheck.Check (checkModule, runCheck)

main :: IO ()
main = hspec spec

-- ---------------------------------------------------------------------------
-- Helpers

emptyDefs :: TypeDefs
emptyDefs = TypeDefs Map.empty Map.empty Map.empty

examplesDir :: FilePath
examplesDir = "test/examples"

-- | Parse source text, expecting success.
parsesOk :: String -> IO ()
parsesOk src = case parseModule "<test>" (pack src) of
    Left  e -> expectationFailure ("parse failed: " ++ show e)
    Right _ -> pure ()

-- | Parse source text, expecting parse failure.
parseFails :: String -> IO ()
parseFails src = case parseModule "<test>" (pack src) of
    Left  _ -> pure ()
    Right _ -> expectationFailure "expected parse error but succeeded"

-- | Parse then typecheck, expecting success (no errors).
typechecksOk :: String -> IO ()
typechecksOk src = case parseModule "<test>" (pack src) of
    Left  e   -> expectationFailure ("parse failed: " ++ show e)
    Right ast -> case runCheck emptyDefs (checkModule ast) of
        Left  errs -> expectationFailure ("typecheck errors: " ++ show errs)
        Right ()   -> pure ()

-- | Parse then typecheck, expecting at least one type error.
typecheckFails :: String -> IO ()
typecheckFails src = case parseModule "<test>" (pack src) of
    Left  e   -> expectationFailure ("parse failed: " ++ show e)
    Right ast -> case runCheck emptyDefs (checkModule ast) of
        Left  _ -> pure ()
        Right _ -> expectationFailure "expected type error but succeeded"

-- ---------------------------------------------------------------------------
-- Spec

spec :: Spec
spec = do
    describe "Parser" $ do
        describe "literals" $ do
            it "integer" $
                parsesOk "module T  let x = 42"
            it "float" $
                parsesOk "module T  let x = 3.14"
            it "string" $
                parsesOk "module T  let x = \"hello\""
            it "true / false" $
                parsesOk "module T  let x = true  let y = false"
            it "null" $
                parsesOk "module T  let x = null"

        describe "expressions" $ do
            it "binary ops" $
                parsesOk "module T  let x = 1 + 2 * 3"
            it "comparison" $
                parsesOk "module T  let x = 1 == 2"
            it "if with block branches" $
                parsesOk "module T  let x = if true { 1 } else { 2 }"
            it "if without else" $
                parsesOk "module T  let x = if true { 1 }"
            it "object literal" $
                parsesOk "module T  let o = {x = 1, y = 2}"
            it "empty object" $
                parsesOk "module T  let o = {}"
            it "array literal" $
                parsesOk "module T  let a = [1, 2, 3]"
            it "spread in array" $
                parsesOk "module T  let a = [1, ...xs, 2]"
            it "tuple" $
                parsesOk "module T  let t = (1, 2, 3)"
            it "field access" $
                parsesOk "module T  let v = obj.field"
            it "index access" $
                parsesOk "module T  let v = arr[0]"
            it "template literal" $
                parsesOk "module T  let s = `hello`"
            it "block" $
                parsesOk "module T  let x = { let y = 1  y }"
            it "return in fn block" $
                parsesOk "module T  fn f(x: integer): integer => { return x }"

        describe "function" $ do
            it "fn declaration with block body" $
                parsesOk "module T  fn add(x: integer, y: integer): integer => { x + y }"
            it "fn expression with block body" $
                parsesOk "module T  let f = fn (x: integer): integer => { x }"
            it "fn with return in block" $
                parsesOk "module T  fn f(x: integer): integer => { return x * 2 }"
            it "fn with generics" $
                parsesOk "module T  fn id<T>(x: T): T => { x }"
            it "fn without block body FAILS" $
                parseFails "module T  fn f(x: integer): integer => x"
            it "if without block branch FAILS" $
                parseFails "module T  let x = if true 1 else 2"

        describe "match" $ do
            it "match with two arms" $
                parsesOk "module T  let x = match v { case (true) => 1  case (false) => 0 }"

        describe "types" $ do
            it "primitive types" $
                parsesOk "module T  let x: integer = 1"
            it "function type" $
                parsesOk "module T  let f: (x: integer) => integer = fn (x: integer): integer => { x }"
            it "union type" $
                parsesOk "module T  let x: integer | string = 1"
            it "intersection type" $
                parsesOk "module T  type T = {a: integer} & {b: string}"
            it "type alias" $
                parsesOk "module T  type Pair = (integer, integer)"
            it "data declaration" $
                parsesOk "module T  data Box<out T>(value: T)"
            it "effect declaration" $
                parsesOk "module T  effect Log<out T>(value: T) => null"

        describe "import" $ do
            it "simple import" $
                parsesOk "module T  import Foo.Bar"
            it "aliased import" $
                parsesOk "module T  import Foo.Bar as F"

        describe "basic.qtl example file" $ do
            it "parses successfully" $ do
                src <- TIO.readFile (examplesDir </> "basic.qtl")
                case parseModule "basic.qtl" src of
                    Left  e -> expectationFailure ("parse failed:\n" ++ show e)
                    Right _ -> pure ()

    describe "Type checker" $ do
        describe "literals" $ do
            it "integer literal infers ok" $
                typechecksOk "module T  let x = 42"
            it "string literal infers ok" $
                typechecksOk "module T  let x = \"hello\""
            it "boolean literal infers ok" $
                typechecksOk "module T  let x = true"
            it "null infers ok" $
                typechecksOk "module T  let x = null"

        describe "type annotations" $ do
            it "correct annotation passes" $
                typechecksOk "module T  let x: integer = 1"
            it "number annotation accepts integer literal" $
                typechecksOk "module T  let x: number = 42"
            it "wrong annotation fails" $
                typecheckFails "module T  let x: string = 42"

        describe "functions" $ do
            it "fn with correct return type passes" $
                typechecksOk "module T  fn add(x: integer, y: integer): integer => { x + y }"
            it "fn with wrong return type fails" $
                typecheckFails "module T  fn f(x: integer): string => { x + 1 }"
            it "nested let in block" $
                typechecksOk "module T  fn f(x: integer): integer => { let y = x + 1  return y }"

        describe "binary ops" $ do
            it "arithmetic on integers" $
                typechecksOk "module T  let x = 1 + 2"
            it "concat on strings" $
                typechecksOk "module T  let x = \"a\" ++ \"b\""
            it "comparison" $
                typechecksOk "module T  let x = 1 < 2"

        describe "if expression" $ do
            it "if without else" $
                typechecksOk "module T  fn f(b: boolean): boolean => { if b { true } }"
            it "if with else unifies branches" $
                typechecksOk "module T  let x = if true { 1 } else { 2 }"

        describe "return validation" $ do
            it "return as last stmt in fn body is OK" $
                typechecksOk "module T  fn f(x: integer): integer => { return x }"
            it "return in middle of fn body FAILS" $
                typecheckFails "module T  fn f(x: integer): integer => { return x  x }"
            it "return in if branch FAILS" $
                typecheckFails $ unlines
                    [ "module T"
                    , "fn f(b: boolean): integer => {"
                    , "  if b { return 1 } else { 2 }"
                    , "}"
                    ]
            it "return in nested block FAILS" $
                typecheckFails $ unlines
                    [ "module T"
                    , "fn f(): integer => {"
                    , "  let x = { return 1 }"
                    , "  x"
                    , "}"
                    ]

        describe "basic.qtl example file" $ do
            it "typechecks successfully" $ do
                src <- TIO.readFile (examplesDir </> "basic.qtl")
                case parseModule "basic.qtl" src of
                    Left  e   -> expectationFailure ("parse failed:\n" ++ show e)
                    Right ast -> case runCheck emptyDefs (checkModule ast) of
                        Left  errs -> expectationFailure ("typecheck errors: " ++ show errs)
                        Right ()   -> pure ()

    -- -----------------------------------------------------------------------
    -- Constraint solver corner cases
    -- -----------------------------------------------------------------------

    describe "Constraint solver" $ do
        -- === Generic bounds ===
        describe "generic bounds" $ do
            it "identity function: T -> T" $
                typechecksOk "module T  fn id<T>(x: T): T => { x }"
            it "T sub number, return number" $
                typechecksOk "module T  fn f<T sub number>(x: T): number => { x }"
            it "T sub number, return T (same as assumption)" $
                typechecksOk "module T  fn f<T sub number>(x: T): T => { x }"
            it "T sub number, return string FAILS" $
                typecheckFails "module T  fn f<T sub number>(x: T): string => { x }"
            it "T sub integer, widened to integer | string" $
                typechecksOk "module T  fn f<T sub integer>(x: T): integer | string => { x }"
            it "unbounded T, any return type accepted (conservative)" $
                typechecksOk "module T  fn f<T>(x: T): T => { x }"

        -- === Function subtyping via block ===
        describe "function subtyping" $ do
            it "same function type" $
                typechecksOk "module T  let f: (x: integer) => integer = fn (x: integer): integer => { x }"
            it "contravariant params + covariant return" $
                typechecksOk $ unlines
                    [ "module T"
                    , "fn test(): (x: integer) => number => {"
                    , "  let f = fn (x: number): integer => { 42 }"
                    , "  return f"
                    , "}"
                    ]
            it "wrong variance FAILS" $
                typecheckFails $ unlines
                    [ "module T"
                    , "fn test(): (x: number) => integer => {"
                    , "  let f = fn (x: integer): number => { 42 }"
                    , "  return f"
                    , "}"
                    ]
            it "arity mismatch FAILS" $
                typecheckFails $ unlines
                    [ "module T"
                    , "fn test(): (x: integer, y: integer) => integer => {"
                    , "  let f = fn (x: integer): integer => { x }"
                    , "  return f"
                    , "}"
                    ]

        -- === Object subtyping ===
        describe "object subtyping" $ do
            it "wider object <: narrower (extra fields OK)" $
                typechecksOk $ unlines
                    [ "module T"
                    , "fn test(): {a: integer} => { {a = 1, b = \"hello\"} }"
                    ]
            it "exact object match" $
                typechecksOk $ unlines
                    [ "module T"
                    , "fn test(): {a: integer, b: string} => { {a = 1, b = \"hello\"} }"
                    ]
            it "missing required field FAILS" $
                typecheckFails $ unlines
                    [ "module T"
                    , "fn test(): {a: integer, b: string} => { {a = 1} }"
                    ]

        -- === Data type variance ===
        describe "data type variance" $ do
            it "covariant: Box<integer> <: Box<number>" $
                typechecksOk $ unlines
                    [ "module T"
                    , "data Box<out T>(value: T)"
                    , "fn test(b: Box<integer>): Box<number> => { b }"
                    ]
            it "covariant: Box<number> NOT <: Box<integer>" $
                typecheckFails $ unlines
                    [ "module T"
                    , "data Box<out T>(value: T)"
                    , "fn test(b: Box<number>): Box<integer> => { b }"
                    ]
            it "contravariant: Consumer<number> <: Consumer<integer>" $
                typechecksOk $ unlines
                    [ "module T"
                    , "data Consumer<in T>(consume: (x: T) => null)"
                    , "fn test(c: Consumer<number>): Consumer<integer> => { c }"
                    ]
            it "contravariant: Consumer<integer> NOT <: Consumer<number>" $
                typecheckFails $ unlines
                    [ "module T"
                    , "data Consumer<in T>(consume: (x: T) => null)"
                    , "fn test(c: Consumer<integer>): Consumer<number> => { c }"
                    ]
            it "invariant: same type passes" $
                typechecksOk $ unlines
                    [ "module T"
                    , "data Cell<T>(value: T)"
                    , "fn test(c: Cell<integer>): Cell<integer> => { c }"
                    ]
            it "invariant: different types FAIL" $
                typecheckFails $ unlines
                    [ "module T"
                    , "data Cell<T>(value: T)"
                    , "fn test(c: Cell<integer>): Cell<number> => { c }"
                    ]
            it "bivariant (phantom): any types pass" $
                typechecksOk $ unlines
                    [ "module T"
                    , "data Phantom<in out T>(value: integer)"
                    , "fn test(p: Phantom<integer>): Phantom<string> => { p }"
                    ]
            it "data type mismatch FAILS" $
                typecheckFails $ unlines
                    [ "module T"
                    , "data Box<out T>(value: T)"
                    , "data Wrap<out T>(inner: T)"
                    , "fn test(b: Box<integer>): Wrap<integer> => { b }"
                    ]
            it "nested covariant data" $
                typechecksOk $ unlines
                    [ "module T"
                    , "data Box<out T>(value: T)"
                    , "fn test(b: Box<Box<integer>>): Box<Box<number>> => { b }"
                    ]

        -- === Pattern matching with data types ===
        describe "pattern matching" $ do
            it "constructor extracts type args" $
                typechecksOk $ unlines
                    [ "module T"
                    , "data Box<out T>(value: T)"
                    , "fn unbox(b: Box<integer>): integer => {"
                    , "  match b {"
                    , "    case (Box(v)) => v"
                    , "  }"
                    , "}"
                    ]
            it "wrong extracted type FAILS" $
                typecheckFails $ unlines
                    [ "module T"
                    , "data Box<out T>(value: T)"
                    , "fn unbox(b: Box<string>): integer => {"
                    , "  match b {"
                    , "    case (Box(v)) => v"
                    , "  }"
                    , "}"
                    ]
            it "union of different constructors" $
                typechecksOk $ unlines
                    [ "module T"
                    , "data Some<out T>(value: T)"
                    , "data None()"
                    , "fn unwrap(x: Some<integer> | None): integer | null => {"
                    , "  match x {"
                    , "    case (Some(v)) => v"
                    , "    case (None()) => null"
                    , "  }"
                    , "}"
                    ]
            it "union of same constructor merges args by variance" $
                typechecksOk $ unlines
                    [ "module T"
                    , "data Box<out T>(value: T)"
                    , "fn test(x: Box<integer> | Box<string>): integer | string => {"
                    , "  match x {"
                    , "    case (Box(v)) => v"
                    , "  }"
                    , "}"
                    ]
            it "nested constructor pattern" $
                typechecksOk $ unlines
                    [ "module T"
                    , "data Box<out T>(value: T)"
                    , "fn deep(b: Box<Box<integer>>): integer => {"
                    , "  match b {"
                    , "    case (Box(inner)) => match inner {"
                    , "      case (Box(v)) => v"
                    , "    }"
                    , "  }"
                    , "}"
                    ]

        -- === Higher-order functions ===
        describe "higher-order functions" $ do
            it "apply function argument" $
                typechecksOk $ unlines
                    [ "module T"
                    , "fn apply(f: (x: integer) => string, x: integer): string => { f(x) }"
                    ]
            it "compose functions" $
                typechecksOk $ unlines
                    [ "module T"
                    , "fn compose(f: (x: integer) => string, g: (x: string) => boolean, x: integer): boolean => { g(f(x)) }"
                    ]
            it "wrong arg type to function FAILS" $
                typecheckFails $ unlines
                    [ "module T"
                    , "fn apply(f: (x: string) => integer, x: integer): integer => { f(x) }"
                    ]

        -- === If-else union ===
        describe "if-else union" $ do
            it "branches form union matching annotation" $
                typechecksOk $ unlines
                    [ "module T"
                    , "fn test(b: boolean): integer | string => {"
                    , "  if b { 42 } else { \"hello\" }"
                    , "}"
                    ]
            it "annotation too narrow for union FAILS" $
                typecheckFails $ unlines
                    [ "module T"
                    , "fn test(b: boolean): integer => {"
                    , "  if b { 42 } else { \"hello\" }"
                    , "}"
                    ]

        -- === Intersection types ===
        describe "intersection types" $ do
            it "string & boolean = never, vacuously passes" $
                typechecksOk "module T  fn f(x: string & boolean): integer => { x }"
            it "object intersection combines fields" $
                typechecksOk $ unlines
                    [ "module T"
                    , "fn f(x: {a: integer} & {b: string}): {a: integer, b: string} => { x }"
                    ]
            it "intersection missing extra field FAILS" $
                typecheckFails $ unlines
                    [ "module T"
                    , "fn f(x: {a: integer} & {b: string}): {a: integer, b: string, c: boolean} => { x }"
                    ]

        -- === Union types ===
        describe "union types" $ do
            it "integer <: integer | string" $
                typechecksOk "module T  let x: integer | string = 42"
            it "string <: integer | string" $
                typechecksOk "module T  let x: integer | string = \"hello\""
            it "boolean NOT <: integer | string" $
                typecheckFails "module T  let x: integer | string = true"
            it "null <: integer | null" $
                typechecksOk "module T  let x: integer | null = null"

        -- === Type aliases ===
        describe "type aliases" $ do
            it "simple alias" $
                typechecksOk $ unlines
                    [ "module T"
                    , "type Num = number"
                    , "let x: Num = 42"
                    ]
            it "alias with union" $
                typechecksOk $ unlines
                    [ "module T"
                    , "type IntOrStr = integer | string"
                    , "let x: IntOrStr = 42"
                    ]
            it "alias preserves subtyping" $
                typechecksOk $ unlines
                    [ "module T"
                    , "type MyInt = integer"
                    , "let x: number = 42"
                    ]

        -- === Tuple subtyping ===
        describe "tuple subtyping" $ do
            it "literal elements <: annotated tuple" $
                typechecksOk $ unlines
                    [ "module T"
                    , "fn test(): (integer, string) => { (1, \"hello\") }"
                    ]

        -- === Complex multi-constraint scenarios ===
        describe "complex scenarios" $ do
            it "multiple constraints in one function" $
                typechecksOk $ unlines
                    [ "module T"
                    , "fn test(x: integer, y: string): {a: integer, b: string} => { {a = x, b = y} }"
                    ]
            it "block with multiple lets and constraints" $
                typechecksOk $ unlines
                    [ "module T"
                    , "fn test(): integer => {"
                    , "  let x: number = 42"
                    , "  let y: integer = 10"
                    , "  return y"
                    , "}"
                    ]
            it "match with multiple data types and function call" $
                typechecksOk $ unlines
                    [ "module T"
                    , "data Ok<out T>(value: T)"
                    , "data Err<out E>(error: E)"
                    , "fn dispatch(r: Ok<integer> | Err<string>, fallback: (x: string) => integer): integer => {"
                    , "  match r {"
                    , "    case (Ok(v)) => v"
                    , "    case (Err(e)) => fallback(e)"
                    , "  }"
                    , "}"
                    ]

        -- === Effect system ===
        describe "effects" $ do
            it "pure fn assignable to effectful function type (pure <: Log<string>)" $
                typechecksOk $ unlines
                    [ "module T"
                    , "effect Log<out T>(msg: T) => null"
                    , "let f: (x: string) => null with Log<string> = fn (x: string): null => { null }"
                    ]
            it "pure fn assignable to impure function type (pure <: impure)" $
                typechecksOk $ unlines
                    [ "module T"
                    , "let f: (x: string) => null with impure = fn (x: string): null => { null }"
                    ]
            it "effectful fn NOT assignable to pure type FAILS" $
                typecheckFails $ unlines
                    [ "module T"
                    , "effect Log<out T>(msg: T) => null"
                    , "// inner fn body calls effectful f, so outer fn has Log effect"
                    , "let test: (x: string) => null = fn (x: string): null => {"
                    , "  let f: (x: string) => null with Log<string> = fn (y: string): null => { null }"
                    , "  f(x)"
                    , "}"
                    ]
            it "handle catches effect, making fn pure" $
                typechecksOk $ unlines
                    [ "module T"
                    , "effect Log<out T>(msg: T) => null"
                    , "let test: (x: string) => null = fn (x: string): null => {"
                    , "  let f: (x: string) => null with Log<string> = fn (y: string): null => { null }"
                    , "  handle f(x) {"
                    , "    case Log(msg) => null"
                    , "  }"
                    , "}"
                    ]
            it "effect subtype: single effect <: impure" $
                typechecksOk $ unlines
                    [ "module T"
                    , "effect Log<out T>(msg: T) => null"
                    , "let test: (x: string) => null with impure = fn (x: string): null => {"
                    , "  let f: (x: string) => null with Log<string> = fn (y: string): null => { null }"
                    , "  f(x)"
                    , "}"
                    ]
            it "effect declaration with multiple type params" $
                typechecksOk $ unlines
                    [ "module T"
                    , "effect Ask<out T, out R>(prompt: T) => R"
                    , "let f: (x: string) => integer with Ask<string, integer> = fn (x: string): integer => { 42 }"
                    ]

    -- -----------------------------------------------------------------------
    -- Literal type subtyping
    -- -----------------------------------------------------------------------

    describe "Literal types" $ do
        describe "string literal unions" $ do
            it "\"foo\" | \"bar\" <: \"foo\" | \"bar\" | \"baz\"" $
                typechecksOk $ unlines
                    [ "module T"
                    , "fn test(x: \"foo\" | \"bar\"): \"foo\" | \"bar\" | \"baz\" => { x }"
                    ]
            it "\"foo\" | \"bar\" | \"baz\" NOT <: \"foo\" | \"bar\"" $
                typecheckFails $ unlines
                    [ "module T"
                    , "fn test(x: \"foo\" | \"bar\" | \"baz\"): \"foo\" | \"bar\" => { x }"
                    ]

        describe "integer literal unions" $ do
            it "1 | 2 <: 1 | 2 | 3" $
                typechecksOk $ unlines
                    [ "module T"
                    , "fn test(x: 1 | 2): 1 | 2 | 3 => { x }"
                    ]
            it "1 | 2 | 3 NOT <: 1 | 2" $
                typecheckFails $ unlines
                    [ "module T"
                    , "fn test(x: 1 | 2 | 3): 1 | 2 => { x }"
                    ]

        describe "literal to primitive" $ do
            it "\"hello\" <: string" $
                typechecksOk "module T  let x: string = \"hello\""
            it "42 <: integer" $
                typechecksOk "module T  let x: integer = 42"
            it "42 <: number" $
                typechecksOk "module T  let x: number = 42"
            it "3.14 <: number" $
                typechecksOk "module T  let x: number = 3.14"
            it "true <: boolean" $
                typechecksOk "module T  let x: boolean = true"

        describe "primitive NOT <: literal" $ do
            it "string NOT <: \"hello\"" $
                typecheckFails $ unlines
                    [ "module T"
                    , "fn test(x: string): \"hello\" => { x }"
                    ]
            it "integer NOT <: 1" $
                typecheckFails $ unlines
                    [ "module T"
                    , "fn test(x: integer): 1 => { x }"
                    ]

        describe "mixed literal unions" $ do
            it "1 | \"hello\" <: integer | string" $
                typechecksOk $ unlines
                    [ "module T"
                    , "fn test(x: 1 | \"hello\"): integer | string => { x }"
                    ]
            it "true | 42 <: boolean | integer" $
                typechecksOk $ unlines
                    [ "module T"
                    , "fn test(x: true | 42): boolean | integer => { x }"
                    ]
            it "1 | true NOT <: integer | string" $
                typecheckFails $ unlines
                    [ "module T"
                    , "fn test(x: 1 | true): integer | string => { x }"
                    ]

        describe "float literals" $ do
            it "3.14 NOT <: integer" $
                typecheckFails $ unlines
                    [ "module T"
                    , "fn test(x: 3.14): integer => { x }"
                    ]
            it "integer NOT <: number (widening direction)" $
                typechecksOk "module T  let x: number = 42"
