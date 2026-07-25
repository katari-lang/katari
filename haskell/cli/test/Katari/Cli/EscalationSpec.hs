module Katari.Cli.EscalationSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.List (List)
import Katari.Cli.Escalation (EntryPointReport (..), entryPointReports, renderEntryPointSection)
import Katari.Compile (CompileInput (..), CompileResult (..), compile)
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Diagnostics (hasErrors)
import Test.Hspec

-- | Compile the single-module @test@ program once, so both its diagnostics and its typed modules are
-- available to the assertions.
compiled :: CompileResult
compiled = compile CompileInput {sources = Map.singleton (ModuleName "test") program}

-- | The entry-point reports the way @check@ reads them — scoped to the one project module, so the
-- spliced-in stdlib never appears.
reports :: List EntryPointReport
reports = entryPointReports [ModuleName "test"] compiled.typedModules

-- | The one entry point whose qualified name matches, for asserting a single agent's row.
reportNamed :: Text -> Maybe EntryPointReport
reportNamed name = case filter (\report -> report.qualifiedName == name) reports of
  (found : _) -> Just found
  [] -> Nothing

-- | A program exercising every residual-row shape: a project-defined request, a stdlib generic
-- request, a request-plus-io mix, plain io, and a pure agent.
program :: Text
program =
  Text.intercalate
    "\n"
    [ "request ask(question: string) -> string",
      "external agent fetch_thing() -> integer",
      "data oops(n: integer)",
      "agent solve() -> string { ask(question = \"hi\") }",
      "agent thrower() -> integer { prelude.throw(error = oops(n = 1)) }",
      "agent mixed() -> integer { let answer = ask(question = \"hi\")",
      "  fetch_thing() }",
      "agent do_io() -> integer { fetch_thing() }",
      "agent pure_one() -> integer { 1 }"
    ]

-- | A two-package scenario: @gmail@ and @google_calendar@ each declare a same-named @credential@
-- request and @api_error@ data type. The entry agent escalates both credentials and a @throw@ over both
-- errors — the shape the audit found conflated to @credential | credential@ / @throw[api_error |
-- api_error]@ once the module qualifier was dropped from nested names.
multiPackageCompiled :: CompileResult
multiPackageCompiled =
  compile
    CompileInput
      { sources =
          Map.fromList
            [ (ModuleName "gmail", "request credential(name: string) -> string\ndata api_error(detail: string)"),
              (ModuleName "google_calendar", "request credential(name: string) -> string\ndata api_error(detail: string)"),
              ( ModuleName "test",
                Text.intercalate
                  "\n"
                  [ "import gmail",
                    "import google_calendar",
                    "agent entry() -> null with gmail.credential | google_calendar.credential | prelude.throw[gmail.api_error | google_calendar.api_error] {",
                    "  let a = gmail.credential(name = \"x\")",
                    "  let b = google_calendar.credential(name = \"y\")",
                    "  prelude.throw(error = gmail.api_error(detail = \"e\")) }"
                  ]
              )
            ]
      }

-- | The entry-point rows scoped to the root @test@ module (so the imported packages never appear).
multiPackageReports :: List EntryPointReport
multiPackageReports = entryPointReports [ModuleName "test"] multiPackageCompiled.typedModules

spec :: Spec
spec = do
  describe "entryPointReports" $ do
    it "compiles the sample program with no errors (so the typed rows are trustworthy)" $
      hasErrors compiled.diagnostics `shouldBe` False

    it "lists every top-level agent as an entry point" $
      map (.qualifiedName) reports
        `shouldMatchList` ["test.solve", "test.thrower", "test.mixed", "test.do_io", "test.pure_one"]

    it "reports a project-defined request fully-qualified" $
      reportNamed "test.solve"
        `shouldBe` Just EntryPointReport {qualifiedName = "test.solve", requests = ["test.ask"], io = False}

    it "reports a stdlib request fully-qualified, with its generic argument also module-qualified" $
      reportNamed "test.thrower"
        `shouldBe` Just EntryPointReport {qualifiedName = "test.thrower", requests = ["prelude.throw[test.oops]"], io = False}

    it "separates escalating requests from plain io" $
      reportNamed "test.mixed"
        `shouldBe` Just EntryPointReport {qualifiedName = "test.mixed", requests = ["test.ask"], io = True}

    it "flags an io-only entry point" $
      reportNamed "test.do_io"
        `shouldBe` Just EntryPointReport {qualifiedName = "test.do_io", requests = [], io = True}

    it "flags a pure entry point" $
      reportNamed "test.pure_one"
        `shouldBe` Just EntryPointReport {qualifiedName = "test.pure_one", requests = [], io = False}

  describe "renderEntryPointSection" $ do
    let section = renderEntryPointSection reports

    it "opens with the section header" $
      Text.isInfixOf "Entry points (requests that escalate to the run root):" section `shouldBe` True

    it "renders an escalating request under its entry point" $ do
      Text.isInfixOf "test.thrower" section `shouldBe` True
      Text.isInfixOf "escalates: prelude.throw[test.oops]" section `shouldBe` True

    it "renders a request-plus-io row with io last" $
      Text.isInfixOf "escalates: test.ask, io" section `shouldBe` True

    it "spells an io-only row" $
      Text.isInfixOf "escalates: (nothing but io)" section `shouldBe` True

    it "spells a pure row" $
      Text.isInfixOf "escalates: (nothing)" section `shouldBe` True

    it "reads (none) when a project has no top-level agents" $
      renderEntryPointSection [] `shouldBe` "Entry points (requests that escalate to the run root):\n  (none)"

  -- Regression for B7: two packages' same-named requests / data types must stay distinguishable in the
  -- row (module-qualified by last segment, like the source), not conflate to `credential | credential`.
  describe "entryPointReports (nested names keep their module across packages)" $ do
    it "compiles the two-package program with no errors" $
      hasErrors multiPackageCompiled.diagnostics `shouldBe` False

    it "qualifies nested requests and data types so the two modules stay distinguishable" $
      map (.requests) (filter (\report -> report.qualifiedName == "test.entry") multiPackageReports)
        `shouldBe` [["gmail.credential", "google_calendar.credential", "prelude.throw[gmail.api_error | google_calendar.api_error]"]]
