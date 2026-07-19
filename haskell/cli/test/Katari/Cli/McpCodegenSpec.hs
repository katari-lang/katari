-- | The @katari mcp pull@ codegen contract, at three altitudes:
--
--   * a GOLDEN test — one fixture listing to exact generated text, so any template drift is a
--     conscious diff (and the wire-form asymmetry stays visible in review: a fallback parameter is
--     inserted as-is, a fully-mapped one through @json.encode@; decoding is all-or-nothing);
--   * ROUND-TRIP tests — every generated module must COMPILE against the real wired-in stdlib
--     (the exact @Katari.Compile.compile@ entry the CLI's check/build commands drive), across the
--     interesting shapes: a simple tool, optional parameters, a fallback parameter, mappable and
--     unmappable output schemas, and name-mangling collisions;
--   * COMPOSITION tests — the shape is a @connect@ scoped provider plus top-level tool agents, so
--     these prove the caller story end to end against a hand-written caller: a bare
--     @use github.connect(...)@ statement, the tools called directly, one passed as a VALUE to a
--     row-generic agent, and TWO generated modules composed in one block (their per-module
--     @credentials@ requests namespaced so nothing collides).
module Katari.Cli.McpCodegenSpec (spec) where

import Control.Monad (when)
import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Katari.Cli.McpCodegen (McpListing, PullContext (..), renderBindingModule)
import Katari.Compile qualified as Compile
import Katari.Data.ModuleName (ModuleName, moduleNameFromSegments)
import Katari.Diagnostics (hasErrors, renderDiagnostics)
import Test.Hspec

-- | Decode a fixture listing (the exact JSON `katari-mcp list-tools` prints). A malformed fixture
-- is a test bug — fail the test rather than propagate a bogus listing.
listingOf :: Text -> IO McpListing
listingOf raw = case Aeson.eitherDecodeStrict' (TextEncoding.encodeUtf8 raw) of
  Left decodeError -> fail ("fixture listing did not decode: " <> decodeError)
  Right listing -> pure listing

pullContext :: PullContext
pullContext =
  PullContext
    { url = "https://mcp.example.test/mcp",
      outPath = "src/github.ktr"
    }

render :: Text -> IO Text
render fixture = renderBindingModule pullContext <$> listingOf fixture

-- | Render a fixture under a specific pull context (its own url \/ out path — the module name a caller
-- imports is the out path's base name), for the multi-module composition tests.
renderWith :: PullContext -> Text -> IO Text
renderWith context fixture = renderBindingModule context <$> listingOf fixture

-- | Compile one generated module against the real stdlib and expect zero error diagnostics; on
-- failure the rendered module and the diagnostics are the assertion message, so a grammar or type
-- drift is diagnosable straight from the test output.
shouldCompile :: Text -> Expectation
shouldCompile rendered = do
  let sources = Map.singleton (moduleNameFromSegments ["github"]) rendered
      result = Compile.compile Compile.CompileInput {Compile.sources = sources}
  when (hasErrors result.diagnostics) $
    expectationFailure
      ( "the generated module does not compile:\n"
          <> Text.unpack (renderDiagnostics result.diagnostics)
          <> "\n--- generated module ---\n"
          <> Text.unpack rendered
      )

-- | Compile several named modules TOGETHER against the real stdlib (a generated binding plus a
-- hand-written caller, or two generated bindings composed in one caller) and expect zero errors; on
-- failure every module's source is part of the assertion message.
shouldCompileTogether :: Map.Map ModuleName Text -> Expectation
shouldCompileTogether sources = do
  let result = Compile.compile Compile.CompileInput {Compile.sources = sources}
  when (hasErrors result.diagnostics) $
    expectationFailure
      ( "the modules do not compile together:\n"
          <> Text.unpack (renderDiagnostics result.diagnostics)
          <> "\n--- modules ---\n"
          <> Text.unpack (Text.intercalate "\n\n" (Map.elems sources))
      )

---------------------------------------------------------------------------------------------------
-- Fixtures
---------------------------------------------------------------------------------------------------

-- | Two tools: a fully typed one (mapped params, mapped output, one optional param, one fallback
-- param) and a text-ish one with no output schema — the golden covers both output plans at once.
goldenFixture :: Text
goldenFixture =
  "{\"tools\": [\
  \  {\"name\": \"get-issue\",\
  \   \"description\": \"Fetch one issue.\\nSlow on \\\"cold\\\" repos.\",\
  \   \"inputSchema\": {\"type\": \"object\",\
  \                     \"properties\": {\"owner\": {\"type\": \"string\"},\
  \                                      \"repo\": {\"type\": \"string\"},\
  \                                      \"labels\": {\"type\": \"array\", \"items\": {\"type\": \"string\"}},\
  \                                      \"filter\": {\"enum\": [\"open\", \"closed\"]}},\
  \                     \"required\": [\"owner\", \"repo\"]},\
  \   \"outputSchema\": {\"type\": \"object\",\
  \                      \"properties\": {\"number\": {\"type\": \"integer\"},\
  \                                       \"title\": {\"type\": \"string\"},\
  \                                       \"assignee\": {\"anyOf\": [{\"type\": \"string\"}, {\"type\": \"null\"}]}},\
  \                      \"required\": [\"number\", \"title\"]}},\
  \  {\"name\": \"ping\", \"description\": \"\", \"inputSchema\": {\"type\": \"object\"}}\
  \]}"

golden :: Text
golden =
  Text.unlines
    [ "// Generated by `katari mcp pull --url https://mcp.example.test/mcp --out src/github.ktr`.",
      "// Regenerate instead of editing.",
      "//",
      "// Each server tool is a TOP-LEVEL agent, callable directly after `use github.connect(auth = ...)`: a",
      "// tool closes over nothing, so the connection's credentials are supplied ambiently by the `credentials`",
      "// request `connect` serves for the scope's duration. NOTE: `connect` still runs `mcp.provide`'s listing",
      "// round-trip to open the scope, even though these static bindings ignore the minted toolbox and call",
      "// through `mcp.call`; a future listing-free `mcp.open` could drop that one-time overhead.",
      "//",
      "// Type mapping (JSON Schema -> Katari), all-or-nothing per parameter and per tool output:",
      "//   - string / integer / number / boolean / null map directly; array -> array[T];",
      "//   - an object with properties -> an object type (a non-required property becomes a `?` field);",
      "//   - an object with only schema-valued additionalProperties -> record[T];",
      "//   - an anyOf whose members all map -> a union;",
      "//   - everything else (enum / const, allOf / oneOf, tuples, open or",
      "//     unmodelled schemas) falls back to `unknown`.",
      "// The mapping only chooses the surface TYPE — the argument value is inserted into the arguments tree",
      "// as-is either way, since a value is already a document (no `json.encode` wire step). The output side",
      "// is symmetric: `mcp.call[connection, T]` decodes the reply against `T` in the runtime, so a",
      "// fully-mapped outputSchema instantiates `T` to its type (decoded, `json.validation_error` on a mismatch)",
      "// and any other tool instantiates `T` to `unknown` (the raw reply as a document value).",
      "",
      "@\"This server's scope marker: every tool rides it, and `connect`'s `mcp.provide` discharges it, so a tool cannot escape the connection.\"",
      "effect connection",
      "",
      "@\"The connection's credentials — provided by `connect` for the scope's duration, read by every tool as `auth`.\"",
      "request credentials() -> mcp.auth",
      "",
      "@\"Open the pulled MCP server's connection for the extent of @continuation@ — as a bare `use github.connect(auth = ...)`, after which the tools are called directly (`github.get_issue(...)`). Establishes a `provide` scope over `https://mcp.example.test/mcp`, serves the connection's `credentials` to every tool, and discharges both on return. `auth` is `mcp.headers(values = ...)` for header or anonymous access, or `mcp.oauth(name = \\\"...\\\")` for a server-stored credential (a missing one pauses the run on an OAuth authorization escalation; answer it from the admin console or `katari answer`).\"",
      "agent connect[R, effect E](",
      "  auth: mcp.auth,",
      "  continuation: agent (value: null) -> R with {...(E | connection), credentials},",
      ") -> R with io | E {",
      "  let _ : mcp.toolbox[connection] = use mcp.provide[connection, R, E](url = \"https://mcp.example.test/mcp\", auth = auth)",
      "  use handler {",
      "    request credentials() { next auth }",
      "  }",
      "  continuation(value = null)",
      "}",
      "",
      "// The declared output of `get-issue`.",
      "type get_issue_output = {assignee?: string | null, number: integer, title: string}",
      "",
      "@\"Fetch one issue.\\nSlow on \\\"cold\\\" repos.\"",
      "agent get_issue(filter: unknown | null ?= null, labels: array[string] | null ?= null, owner: string, repo: string) -> get_issue_output with io | connection | credentials | prelude.throw[mcp.server_error | mcp.auth_error | json.validation_error] {",
      "  let arguments_0 = record.empty()",
      "  let arguments_1 = match (filter) {",
      "    case null -> arguments_0",
      "    case present -> record.set(target = arguments_0, key = \"filter\", value = present)",
      "  }",
      "  let arguments_2 = match (labels) {",
      "    case null -> arguments_1",
      "    case present -> record.set(target = arguments_1, key = \"labels\", value = present)",
      "  }",
      "  let arguments_3 = record.set(target = arguments_2, key = \"owner\", value = owner)",
      "  let arguments_4 = record.set(target = arguments_3, key = \"repo\", value = repo)",
      "  mcp.call[connection, get_issue_output](url = \"https://mcp.example.test/mcp\", auth = credentials(), tool = \"get-issue\", arguments = arguments_4)",
      "}",
      "",
      "agent ping(arguments: unknown) -> unknown with io | connection | credentials | prelude.throw[mcp.server_error | mcp.auth_error | json.validation_error] {",
      "  mcp.call[connection, unknown](url = \"https://mcp.example.test/mcp\", auth = credentials(), tool = \"ping\", arguments = arguments)",
      "}"
    ]

manglingFixture :: Text
manglingFixture =
  "{\"tools\": [\
  \  {\"name\": \"get-issue\", \"inputSchema\": {\"type\": \"object\", \"properties\": {\"type\": {\"type\": \"string\"}, \"maxResults\": {\"type\": \"integer\"}}, \"required\": [\"type\"]}},\
  \  {\"name\": \"get_issue\", \"inputSchema\": {\"type\": \"object\", \"properties\": {\"x\": {\"type\": \"number\"}}, \"required\": [\"x\"]}},\
  \  {\"name\": \"match\", \"inputSchema\": {\"type\": \"object\", \"properties\": {\"credentials\": {\"type\": \"string\"}}, \"required\": [\"credentials\"]}},\
  \  {\"name\": \"connect\", \"inputSchema\": {\"type\": \"object\", \"properties\": {\"q\": {\"type\": \"string\"}}, \"required\": [\"q\"]}},\
  \  {\"name\": \"3d-render\", \"inputSchema\": {\"type\": \"object\", \"properties\": {\"scene\": {\"type\": \"string\"}}, \"required\": [\"scene\"]}},\
  \  {\"name\": \"json\", \"inputSchema\": {\"type\": \"object\", \"properties\": {\"value\": {\"type\": \"string\"}}, \"required\": [\"value\"]}}\
  \]}"

outputShapesFixture :: Text
outputShapesFixture =
  "{\"tools\": [\
  \  {\"name\": \"typed\",\
  \   \"inputSchema\": {\"type\": \"object\", \"properties\": {\"q\": {\"type\": \"string\"}}, \"required\": [\"q\"]},\
  \   \"outputSchema\": {\"type\": \"object\",\
  \                      \"properties\": {\"hits\": {\"type\": \"array\", \"items\": {\"type\": \"object\", \"properties\": {\"id\": {\"type\": \"integer\"}}, \"required\": [\"id\"]}},\
  \                                       \"scores\": {\"type\": \"object\", \"additionalProperties\": {\"type\": \"number\"}}},\
  \                      \"required\": [\"hits\"]}},\
  \  {\"name\": \"partly-typed\",\
  \   \"inputSchema\": {\"type\": \"object\", \"properties\": {\"q\": {\"type\": \"string\"}}, \"required\": [\"q\"]},\
  \   \"outputSchema\": {\"type\": \"object\",\
  \                      \"properties\": {\"title\": {\"type\": \"string\"}, \"payload\": {}},\
  \                      \"required\": [\"title\", \"payload\"]}},\
  \  {\"name\": \"reserved-field\",\
  \   \"inputSchema\": {\"type\": \"object\", \"properties\": {\"q\": {\"type\": \"string\"}}, \"required\": [\"q\"]},\
  \   \"outputSchema\": {\"type\": \"object\",\
  \                      \"properties\": {\"type\": {\"type\": \"string\"}},\
  \                      \"required\": [\"type\"]}}\
  \]}"

-- | A hand-written caller for the golden `github` module: the whole caller story in one agent — a
-- BARE `use github.connect(...)` statement (no binder, so K3013 never bites — the binder-less `use`
-- assigns the continuation value type `null` directly), two top-level tools called DIRECTLY, and one
-- tool passed as a VALUE to a row-generic consumer (whose `agent never -> unknown with E` mirrors how
-- `ai.infer_with_tools` is generic over the tools' shared effect — the tool's row now carries
-- `credentials` + the scope, and `E` absorbs them).
callerModule :: Text
callerModule =
  Text.unlines
    [ "import github",
      "",
      "@\"A row-generic tool consumer, mirroring ai.infer_with_tools: it reads each tool's advertised name.\"",
      "agent describe_tools[effect E](tools: array[agent never -> unknown with E]) -> array[string] {",
      "  for (let tool in tools) {",
      "    next reflection.get_metadata(value = tool).name",
      "  }",
      "}",
      "",
      "@\"The caller story: a bare `use github.connect(...)`, then direct tool calls and value passing.\"",
      "agent main() -> string {",
      "  use handler {",
      "    request prelude.throw(error: mcp.server_error | mcp.auth_error | json.validation_error) -> never {",
      "      break f\"mcp failed: ${json.stringify(value = error)}\"",
      "    }",
      "  }",
      "  use github.connect(auth = mcp.oauth(name = \"github\"))",
      "  let issue = github.get_issue(owner = \"katari-lang\", repo = \"katari\")",
      "  let pong = github.ping(arguments = record.empty())",
      "  let names = describe_tools(tools = [github.get_issue])",
      "  f\"issue=${issue.title} pong=${json.stringify(value = pong)} names=${string.join(parts = names, separator = \",\")}\"",
      "}"
    ]

-- | A one-tool listing under a caller-chosen tool name — the seed for the two-server composition, so
-- each generated module carries its own `connect` + `credentials` and one directly-callable tool.
oneToolFixture :: Text -> Text
oneToolFixture toolName =
  "{\"tools\": [{\"name\": \""
    <> toolName
    <> "\", \"inputSchema\": {\"type\": \"object\", \"properties\": {\"q\": {\"type\": \"string\"}}, \"required\": [\"q\"]}}]}"

alphaContext :: PullContext
alphaContext = PullContext {url = "https://alpha.example.test/mcp", outPath = "src/alpha.ktr"}

bravoContext :: PullContext
bravoContext = PullContext {url = "https://bravo.example.test/mcp", outPath = "src/bravo.ktr"}

-- | Two generated modules composed in ONE block: two bare `use ...connect(...)` statements nest, each
-- discharging its own module-local scope marker (`alpha.connection`, `bravo.connection`) and its own
-- module-namespaced `credentials` request. The two markers are DISTINCT names that simply co-exist in
-- the row — no arg-union, no covariance — and the two `credentials` requests never collide because each
-- is namespaced by its module.
twoServerCaller :: Text
twoServerCaller =
  Text.unlines
    [ "import alpha",
      "import bravo",
      "",
      "@\"Two generated modules, one block: call a tool from each inside both connect scopes.\"",
      "agent two_server() -> string {",
      "  use handler {",
      "    request prelude.throw(error: mcp.server_error | mcp.auth_error | json.validation_error) -> never {",
      "      break f\"mcp failed: ${json.stringify(value = error)}\"",
      "    }",
      "  }",
      "  use alpha.connect(auth = mcp.oauth(name = \"alpha\"))",
      "  use bravo.connect(auth = mcp.oauth(name = \"bravo\"))",
      "  let a = alpha.search(q = \"x\")",
      "  let b = bravo.search(q = \"y\")",
      "  f\"${json.stringify(value = a)} ${json.stringify(value = b)}\"",
      "}"
    ]

---------------------------------------------------------------------------------------------------
-- Spec
---------------------------------------------------------------------------------------------------

spec :: Spec
spec = describe "katari mcp pull codegen" $ do
  describe "golden" $ do
    it "renders the fixture listing to the exact module text" $ do
      rendered <- render goldenFixture
      rendered `shouldBe` golden

    it "the golden module compiles against the real stdlib" $ do
      rendered <- render goldenFixture
      shouldCompile rendered

  describe "argument insertion (values are documents — no json.encode)" $ do
    it "inserts both a mapped and a fallback parameter as-is (no wire step)" $ do
      rendered <- render goldenFixture
      -- (a) `labels` maps (array[string]) and `filter` is an enum fallback — both insert the value AS-IS,
      -- because a value is already a document (there is no `json.encode` wire step for either).
      rendered `shouldSatisfy` Text.isInfixOf "key = \"labels\", value = present"
      rendered `shouldSatisfy` Text.isInfixOf "key = \"filter\", value = present"
      -- No `json.encode` embedding anywhere in the generated CODE (the header comment may mention it).
      rendered `shouldSatisfy` (not . Text.isInfixOf "value = json.encode")

    it "decodes only a fully-mapped outputSchema; any fallback inside keeps the raw reply" $ do
      rendered <- render outputShapesFixture
      -- (b) `typed` maps everywhere (nested array/object/record) — its `T` is the mapped type, so the
      -- runtime decodes the reply against it (no trailing `json.decode` anywhere anymore).
      rendered `shouldSatisfy` Text.isInfixOf "type typed_output = {hits: array[{id: integer}], scores?: record[number]}"
      rendered `shouldSatisfy` Text.isInfixOf "mcp.call[connection, typed_output](url ="
      rendered `shouldSatisfy` (not . Text.isInfixOf "json.decode[")
      -- (b) `partly-typed` has ONE untyped field — the whole output stays `unknown` (the `T` argument).
      rendered `shouldSatisfy` (not . Text.isInfixOf "partly_typed_output")
      rendered `shouldSatisfy` Text.isInfixOf "mcp.call[connection, unknown](url = \"https://mcp.example.test/mcp\", auth = credentials(), tool = \"partly-typed\""
      -- (b) a field named by a reserved word cannot label an object type — also raw.
      rendered `shouldSatisfy` (not . Text.isInfixOf "reserved_field_output")
      shouldCompile rendered

  describe "name mangling" $ do
    it "assigns deterministic identifiers (snake_case, digit prefix, reserved suffix, collision bump)" $ do
      rendered <- render manglingFixture
      rendered `shouldSatisfy` Text.isInfixOf "agent get_issue("
      -- The later original name loses the collision deterministically (sorted by original name).
      rendered `shouldSatisfy` Text.isInfixOf "agent get_issue_2("
      rendered `shouldSatisfy` Text.isInfixOf "agent match_("
      rendered `shouldSatisfy` Text.isInfixOf "agent _3d_render("
      -- `json` would shadow the default-import qualifier every body references — bumped.
      rendered `shouldSatisfy` Text.isInfixOf "agent json_2("
      -- A tool named `connect` would redeclare the module's own provider agent — bumped.
      rendered `shouldSatisfy` Text.isInfixOf "agent connect_2("
      -- The ORIGINAL names still ride in the tool arguments.
      rendered `shouldSatisfy` Text.isInfixOf "tool = \"get-issue\""
      rendered `shouldSatisfy` Text.isInfixOf "tool = \"get_issue\""
      rendered `shouldSatisfy` Text.isInfixOf "tool = \"3d-render\""
      rendered `shouldSatisfy` Text.isInfixOf "tool = \"json\""
      rendered `shouldSatisfy` Text.isInfixOf "tool = \"connect\""
      -- A parameter named by a reserved word mangles, but its record.set key stays original.
      rendered `shouldSatisfy` Text.isInfixOf "type_: string"
      rendered `shouldSatisfy` Text.isInfixOf "key = \"type\", value = type_"
      -- camelCase lowers to snake_case, key stays original.
      rendered `shouldSatisfy` Text.isInfixOf "max_results: integer | null ?= null"
      rendered `shouldSatisfy` Text.isInfixOf "key = \"maxResults\""
      -- A parameter named `credentials` would shadow the ambient request every tool body calls for
      -- its auth (`auth = credentials()`) — bumped; its record.set key stays original.
      rendered `shouldSatisfy` Text.isInfixOf "credentials_2: string"
      rendered `shouldSatisfy` Text.isInfixOf "key = \"credentials\", value = credentials_2"

    it "the mangling module compiles against the real stdlib" $ do
      rendered <- render manglingFixture
      shouldCompile rendered

  describe "the caller story" $ do
    it "a bare `use github.connect(...)` opens the connection, the tools are called directly, and one is passed as a value to a row-generic agent" $ do
      github <- render goldenFixture
      shouldCompileTogether
        ( Map.fromList
            [ (moduleNameFromSegments ["github"], github),
              (moduleNameFromSegments ["caller"], callerModule)
            ]
        )

  describe "two-server composition" $ do
    it "two generated modules compose in one block — each connect's own scope + module-namespaced credentials request nest without collision" $ do
      alpha <- renderWith alphaContext (oneToolFixture "search")
      bravo <- renderWith bravoContext (oneToolFixture "search")
      shouldCompileTogether
        ( Map.fromList
            [ (moduleNameFromSegments ["alpha"], alpha),
              (moduleNameFromSegments ["bravo"], bravo),
              (moduleNameFromSegments ["two_server"], twoServerCaller)
            ]
        )

  describe "degenerate listings" $ do
    it "an empty listing still renders a compiling module" $ do
      rendered <- render "{\"tools\": []}"
      shouldCompile rendered
