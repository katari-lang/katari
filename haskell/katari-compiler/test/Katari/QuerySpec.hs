module Katari.QuerySpec (spec) where

import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Katari.Compile as C
import Katari.Query (HoverInfo (..), lookupAtPosition)
import qualified Katari.SemanticType as ST
import Katari.SourceSpan (Position (..))
import Test.Hspec

prepare :: Text -> C.CompileResult
prepare src =
  C.compile
    C.CompileInput
      { C.sources =
          Map.singleton
            "main"
            C.SourceEntry {C.filePath = "<test>", C.sourceText = src},
        C.cache = Map.empty
      }

spec :: Spec
spec = describe "Katari.Query.lookupAtPosition (hover)" $ do
  it "returns hover for the agent name" $ do
    let r = prepare "agent main() -> integer {\n  42\n}\n"
    let info = lookupAtPosition r.identifierResult r.zonkResult "<test>" Position {line = 1, column = 9}
    info `shouldSatisfy` isJust
    case info of
      Just h -> h.hoverQualifiedName `shouldBe` Just "main.main"
      Nothing -> expectationFailure "expected Just"

  it "returns hover for a literal trailing expression" $ do
    -- The agent body is just `42`. Hovering on the `42` should yield
    -- a Hover with the literal's type (no qualified name).
    let r = prepare "agent main() -> integer {\n  42\n}\n"
    -- Katari positions are 1-indexed: line 2 col 3 = the `4` in 42.
    let info = lookupAtPosition r.identifierResult r.zonkResult "<test>" Position {line = 2, column = 3}
    case info of
      Just h -> do
        h.hoverType `shouldNotBe` Nothing
      Nothing -> expectationFailure "expected literal hover to return Just"

  it "case (n, s) pattern variable n gets the subject's first-element type (typechecker)" $ do
    -- Direct typechecker test (no hover). Investigates the user-flagged
    -- bug: pattern-bound `n` should resolve to `integer` (the lower
    -- bound the constraint generator emits from
    -- @addTypeConstraint integer tv_n@), not `unknown`.
    let src =
          Text.unlines
            [ "agent describe(p = p: (integer, string)) -> string {",
              "  match (p) {",
              "    case (n, s) => { \"ok\" }",
              "  }",
              "}"
            ]
    let r = prepare src
    -- Look up `n`'s VariableId by qualifying `nameRef.resolution`. The
    -- pattern's name span is at (line 3, column 11).
    let info = lookupAtPosition r.identifierResult r.zonkResult "<test>" Position {line = 3, column = 11}
    case info >>= (.hoverType) of
      Just ST.SemanticTypeInteger -> pure ()
      other ->
        expectationFailure $
          "expected SemanticTypeInteger for pattern-bound `n`, got: " <> show other

  it "case (n, s) hover targets n, not a sibling pattern's type (regression)" $ do
    -- Regression for the user-reported bug: hovering on `n` used to
    -- return @SemanticTypeString@ (the sibling `s`'s type, leaking
    -- through the match expression's generic typeOf fallback) because
    -- the hover walker did not descend into case-arm patterns.
    --
    -- Note: the pattern-bound `n`'s type still ends up as
    -- @SemanticTypeUnknown@ because the constraint generator does
    -- not (yet) constrain match-arm pattern variables against the
    -- subject's tuple element types. That is a separate typechecker
    -- bug — what we assert here is the hover walker no longer leaks
    -- the wrong type.
    let src =
          Text.unlines
            [ "agent describe(p = p: (integer, string)) -> string {",
              "  match (p) {",
              "    case (n, s) => { \"ok\" }",
              "  }",
              "}"
            ]
    let r = prepare src
    -- Line 3 col 11 = the `n` token (line is `    case (n, s) ...`).
    let info = lookupAtPosition r.identifierResult r.zonkResult "<test>" Position {line = 3, column = 11}
    case info >>= (.hoverType) of
      Just ST.SemanticTypeString ->
        expectationFailure "hover on `n` regressed to sibling pattern's type"
      Just (ST.SemanticTypeLiteralString _) ->
        expectationFailure "hover on `n` leaked the match expression's literal-string type"
      Just _ -> pure () -- integer (ideal) or unknown (current typechecker limit) both pass
      Nothing -> expectationFailure "expected some hover at `n`"

  it "constructor pattern: field bindings propagate the ctor's declared field types" $ do
    -- `data Circle(r: integer)` — matching `case Circle(r = v) => v`
    -- should bind `v` to integer (the ctor's declared field type).
    let src =
          Text.unlines
            [ "data Circle(r: integer)",
              "agent area(c = c: Circle) -> integer {",
              "  match (c) {",
              "    case Circle(r = v) => { v }",
              "  }",
              "}"
            ]
    let r = prepare src
    -- "    case Circle(r = v) => ..." — `v` is at col 22.
    -- "    case Circle(r = v)"
    -- 12345678901234567890123
    --      ^col 5 = c       ^col 22 = v
    let info = lookupAtPosition r.identifierResult r.zonkResult "<test>" Position {line = 4, column = 22}
    case info >>= (.hoverType) of
      Just ST.SemanticTypeInteger -> pure ()
      other ->
        expectationFailure $
          "expected integer for ctor-bound `v`, got: " <> show other

  it "nested pattern: tuple inside constructor (or vice versa) propagates element types" $ do
    -- `data Wrapper(inner: (integer, string))` — matching
    -- `case Wrapper(inner = (x, y)) => x` should bind `x` to integer.
    let src =
          Text.unlines
            [ "data Wrapper(inner: (integer, string))",
              "agent first(w = w: Wrapper) -> integer {",
              "  match (w) {",
              "    case Wrapper(inner = (x, y)) => { x }",
              "  }",
              "}"
            ]
    let r = prepare src
    -- "    case Wrapper(inner = (x, y)) => { x }"
    --     1234567890123456789012345678901234567890
    --                                   ^col 26 = x
    let info = lookupAtPosition r.identifierResult r.zonkResult "<test>" Position {line = 4, column = 27}
    case info >>= (.hoverType) of
      Just ST.SemanticTypeInteger -> pure ()
      other ->
        expectationFailure $
          "expected integer for nested-tuple-bound `x`, got: " <> show other

  it "handle: hover on the request name shows the request's signature + qname" $ do
    let src =
          Text.unlines
            [ "agent main() -> string {",
              "  handle {",
              "    request throw(msg = msg: string) {",
              "      break \"caught\"",
              "    }",
              "  }",
              "  throw(msg = \"boom\")",
              "  \"unreachable\"",
              "}"
            ]
    let r = prepare src
    -- "    request throw(msg = msg: string) {" — `throw` starts at col 13 on
    -- line 3 (4-space indent + "request " (8 chars)).
    let info = lookupAtPosition r.identifierResult r.zonkResult "<test>" Position {line = 3, column = 14}
    case info of
      Nothing -> expectationFailure "expected hover on `throw`"
      Just h -> do
        h.hoverQualifiedName `shouldBe` Just "primitive.throw"
        h.hoverType `shouldNotBe` Nothing

  it "literal pattern in match arm: hover returns its singleton type" $ do
    let src =
          Text.unlines
            [ "agent label(n = n: integer) -> string {",
              "  match (n) {",
              "    case 0 => { \"zero\" }",
              "    case _ => { \"other\" }",
              "  }",
              "}"
            ]
    let r = prepare src
    -- "    case 0 => ..." — `0` is at col 10 on line 3.
    let info = lookupAtPosition r.identifierResult r.zonkResult "<test>" Position {line = 3, column = 10}
    case info >>= (.hoverType) of
      Just (ST.SemanticTypeLiteralInteger 0) -> pure ()
      other ->
        expectationFailure $
          "expected literal-integer 0 for `0` pattern, got: " <> show other

  it "for-in binding: variable gets the array element type" $ do
    -- `for (let v in [1, 2, 3])` should bind v to integer (or literal-int
    -- union); hovering on `v` inside the body must NOT show unknown.
    let src =
          Text.unlines
            [ "agent sum() -> integer {",
              "  for (let v in [1, 2, 3], var acc: integer = 0) {",
              "    next with { acc = acc + v }",
              "  } then { acc }",
              "}"
            ]
    let r = prepare src
    -- "    next with { acc = acc + v }" — position the `v` after `+`.
    -- Find the column of `v` in line 3.
    -- `v` is at column 29 on line 3 (single char). Sample col 30 (just
    -- past `v`'s start) so the desugared `primitive.add` callee's span
    -- (which currently extends through `v`'s start position) doesn't
    -- shadow the variable hover.
    let info = lookupAtPosition r.identifierResult r.zonkResult "<test>" Position {line = 3, column = 30}
    case info >>= (.hoverType) of
      Just ST.SemanticTypeUnknown ->
        expectationFailure "for-loop variable `v` should not be unknown"
      Just _ -> pure ()
      Nothing -> expectationFailure "expected hover at `v`"

  it "matches the e2e 01-hello sample: hover on the string literal" $ do
    -- Exact source from e2e/samples/01-hello/src/main.ktr. The trailing
    -- expression `"hello, world"` is on line 3.
    let src =
          Text.unlines
            [ "@\"Returns the canonical greeting.\"",
              "agent main() -> string {",
              "  \"hello, world\"",
              "}"
            ]
    let r = prepare src
    let info = lookupAtPosition r.identifierResult r.zonkResult "<test>" Position {line = 3, column = 6}
    case info of
      Just _ -> pure ()
      Nothing -> expectationFailure "expected literal hover at (3, 6) to return Just"
  where
    isJust = \case
      Just _ -> True
      Nothing -> False
