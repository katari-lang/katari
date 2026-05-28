module Katari.Query.CompletionSpec (spec) where

import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Katari.Compile qualified as C
import Katari.Compile qualified as Compile
import Katari.Lexer qualified as Lexer
import Katari.Parser qualified as Parser
import Katari.Query qualified as Query
import Katari.Query.Completion
import Katari.SemanticType (SemanticType (..), emptyRequest)
import Katari.SourceSpan (Position (..))
import Katari.Typechecker.Identifier
  ( IdentifierResult (..),
    SymbolEntry (..),
  )
import Katari.Typechecker.Zonker (ZonkResult (..))
import Test.Hspec

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Compile a single-module program and return the IdentifierResult +
-- ZonkResult. Fails the test if compilation produced any error-severity
-- diagnostic.
prepare :: Text -> IO Query.QuerySnapshot
prepare src = do
  let result =
        C.compileSync
          C.CompileInput
            { C.sources =
                Map.singleton
                  "main"
                  C.SourceEntry {C.filePath = "<test>", C.sourceText = src},
              C.cache = Map.empty
            }
  pure result.querySnapshot

prepareMulti :: [(Text, FilePath, Text)] -> IO Query.QuerySnapshot
prepareMulti sources = do
  let result =
        C.compileSync
          C.CompileInput
            { C.sources =
                Map.fromList
                  [ (name, C.SourceEntry {C.filePath = path, C.sourceText = src})
                    | (name, path, src) <- sources
                  ],
              C.cache = Map.empty
            }
  pure result.querySnapshot

completionLabels :: [CompletionItem] -> [Text]
completionLabels = map (.ciLabel)

findLabel :: Text -> [CompletionItem] -> Maybe CompletionItem
findLabel lbl = find (\ci -> ci.ciLabel == lbl)

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = describe "Katari.Query.Completion" $ do
  it "offers an agent parameter inside the body" $ do
    -- agent foo(name = name: string) -> string {
    --   name   <- cursor here, completion should offer "name"
    -- }
    snap <- prepare "agent foo(name = name: string) -> string {\n  name\n}\n"
    let items = completionsAt snap "<test>" Position {line = 2, column = 3}
    completionLabels items `shouldSatisfy` ("name" `elem`)

  it "marks a parameter binding as a local variable" $ do
    snap <- prepare "agent foo(name = name: string) -> string {\n  name\n}\n"
    let items = completionsAt snap "<test>" Position {line = 2, column = 3}
    fmap (.ciKind) (findLabel "name" items) `shouldBe` Just CKLocalVariable

  it "offers top-level callables from anywhere in the module" $ do
    -- 'helper' is a top-level agent — completion at any position in
    -- the file should include it.
    snap <-
      prepare $
        Text.unlines
          [ "agent helper() -> integer { 1 }",
            "agent main() -> integer {",
            "  0",
            "}"
          ]
    let items = completionsAt snap "<test>" Position {line = 3, column = 3}
    completionLabels items `shouldSatisfy` ("helper" `elem`)
    fmap (.ciKind) (findLabel "helper" items) `shouldBe` Just CKAgent

  it "offers data constructors and types" $ do
    snap <-
      prepare $
        Text.unlines
          [ "data Point(x: integer, y: integer)",
            "agent main() -> integer {",
            "  0",
            "}"
          ]
    let items = completionsAt snap "<test>" Position {line = 3, column = 3}
    let pointItems = filter (\ci -> ci.ciLabel == "Point") items
    -- mergeByLabel keeps one (it picks the constructor over the type).
    pointItems `shouldNotBe` []
    fmap (.ciKind) (findLabel "Point" items) `shouldBe` Just CKConstructor

  it "hides top-level callables from un-imported modules" $ do
    -- helper.ktr defines a top-level agent `secret`. main.ktr does
    -- NOT import it. Completion at a position in main.ktr must NOT
    -- offer `secret`.
    snap <-
      prepareMulti
        [ ("helper", "<helper>", "agent secret() -> integer { 0 }\n"),
          ("main", "<main>", "agent main() -> integer { 0 }\n")
        ]
    let items = completionsAt snap "<main>" Position {line = 1, column = 27}
    completionLabels items `shouldSatisfy` notElem "secret"

  it "offers names brought in by `import { ... } from other`" $ do
    snap <-
      prepareMulti
        [ ("helper", "<helper>", "agent friend() -> integer { 0 }\n"),
          ( "main",
            "<main>",
            Text.unlines
              [ "import { friend } from helper",
                "agent main() -> integer { 0 }"
              ]
          )
        ]
    let items = completionsAt snap "<main>" Position {line = 2, column = 27}
    completionLabels items `shouldSatisfy` ("friend" `elem`)
    fmap (.ciKind) (findLabel "friend" items) `shouldBe` Just CKAgent

  it "offers a module alias as CKModule for `import other as alias`" $ do
    snap <-
      prepareMulti
        [ ("helper", "<helper>", "agent friend() -> integer { 0 }\n"),
          ( "main",
            "<main>",
            Text.unlines
              [ "import helper as h",
                "agent main() -> integer { 0 }"
              ]
          )
        ]
    let items = completionsAt snap "<main>" Position {line = 2, column = 27}
    -- The alias `h` should appear as a module; `friend` (= the
    -- aliased module's member) should NOT appear bare.
    completionLabels items `shouldSatisfy` ("h" `elem`)
    fmap (.ciKind) (findLabel "h" items) `shouldBe` Just CKModule
    completionLabels items `shouldSatisfy` notElem "friend"

  it "resolveDottedPath: alias → AnchorModule; completionsOfModule lists exports" $ do
    snap <-
      prepareMulti
        [ ( "helper",
            "<helper>",
            Text.unlines
              [ "agent friend() -> integer { 0 }",
                "agent buddy() -> string { \"hi\" }",
                "data Pair(a: integer, b: integer)"
              ]
          ),
          ( "main",
            "<main>",
            Text.unlines
              [ "import helper as h",
                "agent main() -> integer { 0 }"
              ]
          )
        ]
    case resolveDottedPath snap "<main>" Position {line = 2, column = 27} "h" of
      Just (AnchorModule helperId) -> do
        let items = completionsOfModule snap helperId
        completionLabels items `shouldSatisfy` ("friend" `elem`)
        completionLabels items `shouldSatisfy` ("buddy" `elem`)
        completionLabels items `shouldSatisfy` ("Pair" `elem`)
        fmap (.ciKind) (findLabel "friend" items) `shouldBe` Just CKAgent
        fmap (.ciKind) (findLabel "Pair" items) `shouldBe` Just CKConstructor
      other -> expectationFailure $ "expected AnchorModule, got: " <> show other

  it "resolveDottedPath: bare callable name → AnchorTyped (function); label completion via type" $ do
    snap <-
      prepare
        ( Text.unlines
            [ "agent greet(name = name: string, age = age: integer) -> string { name }",
              "agent main() -> string { greet(name = \"x\", age = 0) }"
            ]
        )
    case resolveDottedPath snap "<test>" Position {line = 2, column = 26} "greet" of
      Just (AnchorTyped ty) -> do
        let items = completionsOfCallLabels ty Set.empty
        completionLabels items `shouldMatchList` ["name", "age"]
        let remaining = completionsOfCallLabels ty (Set.singleton "name")
        completionLabels remaining `shouldMatchList` ["age"]
      other -> expectationFailure $ "expected AnchorTyped, got: " <> show other

  it "resolveDottedPath: external → AnchorTyped (function)" $ do
    -- Regression: a user reported label completion does not work
    -- inside @cron_impl(@. Verify the ext-agent declaration's type is
    -- reachable as a SemanticTypeFunction (not Unknown / wrong shape).
    snap <-
      prepare $
        Text.unlines
          [ "@\"Cron tick.\"",
            "request scheduled() -> null",
            "@\"Schedule a callback.\"",
            "external cron_impl(callback: agent () -> null with scheduled) -> null from \"FFI:lib.cron_impl\"",
            "agent main() -> integer { 0 }"
          ]
    case resolveDottedPath snap "<test>" Position {line = 5, column = 26} "cron_impl" of
      Just (AnchorTyped ty) -> do
        let items = completionsOfCallLabels ty Set.empty
        completionLabels items `shouldMatchList` ["callback"]
      other ->
        expectationFailure $ "expected AnchorTyped for `cron_impl`, got: " <> show other

  it "resolveDottedPath: local variable bound to data value → field completion" $ do
    snap <-
      prepare $
        Text.unlines
          [ "data Point(x: integer, y: string)",
            "agent main() -> integer {",
            "  let p = Point(x = 1, y = \"hi\")",
            "  0",
            "}"
          ]
    -- Cursor on line 4 col 3 (just past `let p = ...` so `p` is in scope).
    case resolveDottedPath snap "<test>" Position {line = 4, column = 3} "p" of
      Just (AnchorTyped ty) -> do
        let items = completionsOfFields snap ty
        completionLabels items `shouldMatchList` ["x", "y"]
      other ->
        expectationFailure $ "expected AnchorTyped for data value `p`, got: " <> show other

  it "resolveDottedPath: qualified callable `mod.func` → AnchorTyped (function)" $ do
    snap <-
      prepareMulti
        [ ( "helper",
            "<helper>",
            "agent greet(name = name: string) -> string { name }\n"
          ),
          ( "main",
            "<main>",
            Text.unlines
              [ "import helper as h",
                "agent main() -> integer { 0 }"
              ]
          )
        ]
    case resolveDottedPath snap "<main>" Position {line = 2, column = 27} "h.greet" of
      Just (AnchorTyped ty) -> do
        let items = completionsOfCallLabels ty Set.empty
        completionLabels items `shouldMatchList` ["name"]
      other ->
        expectationFailure $ "expected AnchorTyped for `h.greet`, got: " <> show other

  it "completionsOfCallLabels on union of functions: intersects parameter labels" $ do
    -- Manually build a union type: `(name: string) -> string` |
    -- `(name: string, age: integer) -> string`. The intersection is
    -- `{name}` (only label common to both branches).
    let fn1 =
          SemanticTypeFunction
            (Map.singleton "name" SemanticTypeString)
            SemanticTypeString
            emptyRequest
        fn2 =
          SemanticTypeFunction
            ( Map.fromList
                [("name", SemanticTypeString), ("age", SemanticTypeInteger)]
            )
            SemanticTypeString
            emptyRequest
        union = SemanticTypeUnion [fn1, fn2]
        items = completionsOfCallLabels union Set.empty
    completionLabels items `shouldMatchList` ["name"]

  it "ciDetail renders the actual semantic type (no <type> placeholder)" $ do
    snap <-
      prepare $
        Text.unlines
          [ "agent helper() -> integer { 1 }",
            "agent main() -> integer { 0 }"
          ]
    let items = completionsAt snap "<test>" Position {line = 2, column = 26}
    case findLabel "helper" items of
      Just ci -> do
        ci.ciDetail `shouldNotBe` Just "<type>"
        ci.ciDetail `shouldNotBe` Nothing
        -- Sanity-check: the rendered type for `helper` is `() -> integer`.
        -- The renderer's exact spacing might evolve, so we just look
        -- for the @integer@ substring (= the return type).
        fmap (Text.isInfixOf "integer") ci.ciDetail `shouldBe` Just True
      Nothing -> expectationFailure "expected `helper` completion"
