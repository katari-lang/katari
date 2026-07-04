module Katari.QuerySpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Katari.Compile (CompileInput (..), CompileResult (..), compile)
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Data.QualifiedName (QualifiedName (..))
import Katari.Data.SourceSpan (Position (..), SourceSpan (..))
import Katari.Query
import Katari.Query.Completion qualified as Completion
import Test.Hspec

spec :: Spec
spec = do
  hoverSpec
  definitionSpec
  referencesSpec
  completionSpec

---------------------------------------------------------------------------------------------------
-- Fixture
---------------------------------------------------------------------------------------------------

-- | Two modules; positions in the tests refer to these sources. Lines and columns are 1-indexed.
mainSource :: Text
mainSource =
  Text.unlines
    [ "import { helper } from library", -- line 1
      "", -- line 2
      "agent main(input: string) -> string {", -- line 3
      "  let doubled = helper(value = input)", -- line 4
      "  doubled", -- line 5
      "}" -- line 6
    ]

librarySource :: Text
librarySource =
  Text.unlines
    [ "@\"Doubles a string.\"", -- line 1
      "agent helper(value: string) -> string {", -- line 2
      "  value ++ value", -- line 3
      "}" -- line 4
    ]

snapshotOf :: [(Text, Text)] -> QuerySnapshot
snapshotOf sources =
  buildQuerySnapshot
    (compile CompileInput {sources = Map.fromList [(ModuleName name, text) | (name, text) <- sources]})

fixture :: QuerySnapshot
fixture = snapshotOf [("main", mainSource), ("library", librarySource)]

mainModule :: ModuleName
mainModule = ModuleName "main"

libraryModule :: ModuleName
libraryModule = ModuleName "library"

at :: Int -> Int -> Position
at line column = Position {line = line, column = column}

---------------------------------------------------------------------------------------------------
-- Hover
---------------------------------------------------------------------------------------------------

hoverSpec :: Spec
hoverSpec = describe "hoverAt" $ do
  it "shows a parameter's type at its use site" $ do
    -- `input` inside the call argument on line 4.
    let hover = hoverAt fixture mainModule (at 4 34)
    (renderHoverType <$> (hover >>= (.semanticType))) `shouldBe` Just "string"

  it "shows the agent type on the declaration name" $ do
    -- `main` on line 3.
    let hover = hoverAt fixture mainModule (at 3 8)
    (renderHoverType <$> (hover >>= (.semanticType)))
      `shouldBe` Just "agent(input: string) -> string"

  it "carries the qualified name of a cross-module reference" $ do
    -- `helper` on line 4.
    let hover = hoverAt fixture mainModule (at 4 18)
    (hover >>= (.qualifiedName)) `shouldBe` Just "library.helper"

  it "falls back to the innermost expression type between names" $ do
    -- A position inside the call's argument list that sits on no name (the `value` label carries no
    -- resolution): the innermost typed node is the call itself.
    let hover = hoverAt fixture mainModule (at 4 25)
    (hover >>= (.qualifiedName)) `shouldBe` Nothing
    (renderHoverType <$> (hover >>= (.semanticType))) `shouldBe` Just "string"

---------------------------------------------------------------------------------------------------
-- Definition
---------------------------------------------------------------------------------------------------

definitionSpec :: Spec
definitionSpec = describe "definitionAt" $ do
  it "resolves a local variable to its binding" $ do
    -- `doubled` on line 5 → the let on line 4.
    let definition = definitionAt fixture mainModule (at 5 4)
    ((.start.line) <$> definition) `shouldBe` Just 4

  it "resolves a cross-module reference to the declaring module" $ do
    -- `helper` on line 4 of main → its declaration in library (line 2).
    let definition = definitionAt fixture mainModule (at 4 18)
    ((.filePath) <$> definition) `shouldBe` Just "library"
    ((.start.line) <$> definition) `shouldBe` Just 2

  it "resolves a stdlib reference to nothing (no navigable source)" $ do
    -- `++` desugars to a prelude call whose synthetic references span the operator expression;
    -- the stdlib has no symbol table, so there is nowhere to navigate.
    definitionAt fixture libraryModule (at 3 10) `shouldBe` Nothing

---------------------------------------------------------------------------------------------------
-- References
---------------------------------------------------------------------------------------------------

referencesSpec :: Spec
referencesSpec = describe "findReferences" $ do
  let index = buildOccurrenceIndex fixture

  it "finds all occurrences of a top-level agent across modules" $ do
    let target = (.target) <$> occurrenceAt fixture mainModule (at 4 18)
    target `shouldBe` Just (ResolvedReferenceTopLevelVariable QualifiedName {moduleName = libraryModule, name = "helper"})
    let spans = maybe [] (findReferences index) target
    -- The declaration in library and the call in main.
    length spans `shouldBe` 2
    map (.filePath) spans `shouldMatchList` ["library", "main"]

  it "keeps two modules' local variables apart" $ do
    -- `value` in library resolves to a local; occurrences stay within library.
    let target = (.target) <$> occurrenceAt fixture libraryModule (at 3 4)
    let spans = maybe [] (findReferences index) target
    all (\occurrenceSpan -> occurrenceSpan.filePath == "library") spans `shouldBe` True
    -- Parameter binding + two uses in `value ++ value`.
    length spans `shouldBe` 3

---------------------------------------------------------------------------------------------------
-- Completion
---------------------------------------------------------------------------------------------------

completionSpec :: Spec
completionSpec = describe "completion" $ do
  it "lists locals, imports, and stdlib qualifiers in scope" $ do
    let items = Completion.completionsAt fixture mainModule (at 5 4)
        labels = map (.label) items
    labels `shouldContain` ["doubled"]
    labels `shouldContain` ["helper"]
    labels `shouldContain` ["main"]
    -- A default-import stdlib qualifier is visible without an import statement.
    labels `shouldContain` ["string"]

  it "resolves a module qualifier for member completion" $ do
    case Completion.resolveDottedPath fixture mainModule (at 5 4) "string" of
      Just (Completion.AnchorModule moduleName) -> moduleName `shouldBe` ModuleName "prelude.string"
      other -> expectationFailure ("expected a module anchor, got " <> show other)

  it "lists a module's exports with documentation" $ do
    let items = Completion.completionsOfModule fixture libraryModule
    map (.label) items `shouldBe` ["helper"]
    map (.documentation) items `shouldBe` [Just "Doubles a string."]

  it "completes parameter labels inside a call" $ do
    case Completion.resolveDottedPath fixture mainModule (at 4 18) "helper" of
      Just (Completion.AnchorTyped callableType) -> do
        let items = Completion.completionsOfCallLabels callableType mempty
        map (.label) items `shouldBe` ["value"]
        Completion.completionsOfCallLabels callableType (Set.fromList ["value"]) `shouldBe` []
      other -> expectationFailure ("expected a typed anchor, got " <> show other)

  it "exposes module interfaces on the snapshot" $
    Map.member libraryModule fixture.moduleInterfaces `shouldBe` True

  it "records agent declaration types for detail rendering" $
    isJust (topLevelValueTypeOf fixture QualifiedName {moduleName = libraryModule, name = "helper"})
      `shouldBe` True
