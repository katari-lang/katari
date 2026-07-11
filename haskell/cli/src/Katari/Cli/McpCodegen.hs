-- | Code generation for @katari mcp pull@: one MCP server listing in, one self-contained Katari
-- binding module out — a @connect@ scoped provider (the bare @use github.connect(auth = ...)@ form)
-- plus one TOP-LEVEL typed agent per server tool, each calling through the schema-blind @mcp.call@
-- external under the provide scope. This follows the package provider idiom (a provider agent + a
-- capability request + top-level tool agents, as in the @tavily@ / @e2b@ packages): a top-level agent
-- can close over nothing, so instead of handing the caller a record of closures, @connect@ supplies
-- the connection's @auth@ AMBIENTLY through a generated @credentials@ request that every tool reads.
-- The caller writes @use github.connect(auth = ...)@ as a bare statement and then calls the tools
-- directly (@github.get_issue(...)@).
--
-- @connect@ opens the scope with @mcp.provide@ and serves @credentials@ with a @use handler@. The
-- continuation row uses a MIXED effect spelling: @{...(E | mcp.scope[\"<url>\"]), credentials}@ — the
-- scope marker rides the UNION side (so two @connect@s over two servers nest, their per-URL scopes
-- merging by arg-union), while the handled @credentials@ request rides the OVERWRITE side (a handled
-- request must be pinned out of the shared @E@ for the handler to discharge it; a pure @| credentials@
-- union leaves it in @E@ and the handler discharge fails, K3001). The two servers' @credentials@
-- requests never collide because each is namespaced by its own generated module.
--
-- NOTE: @connect@ still performs @mcp.provide@'s listing round-trip to open the scope, even though
-- these static bindings ignore the minted toolbox and dispatch through @mcp.call@; a future
-- listing-free @mcp.open@ primitive could remove that one-time overhead (unimplemented — recorded in
-- the pull design doc).
--
-- The type mapping is ALL-OR-NOTHING per parameter and per tool output. On the PARAMETER side this is
-- forced by the wire-form asymmetry of the @json@ boundary: @json.encode@ speaks the value WIRE form, so
-- a @json.json@ nested INSIDE a typed parameter would embed as its @$constructor@ tree — not the raw
-- fragment an MCP server expects. A parameter whose schema maps completely is embedded with
-- @json.encode@; a parameter with any unmapped part falls back to @json.json@ as a whole and is inserted
-- into the arguments tree AS-IS (it already is a tree). The OUTPUT side has no such asymmetry:
-- @mcp.call[url, T]@ decodes the reply against @T@ in the RUNTIME. A tool whose @outputSchema@ maps
-- completely instantiates @T@ to that type (decoded, @json.decode_error@ on a mismatch); any other tool
-- instantiates @T@ to @json.json@ (the raw reply as a tree — today's behaviour), so the wrapper is one
-- @mcp.call[...]@ call either way, with no trailing @json.decode@.
--
-- The body uses ONE uniform construction shape: the arguments object is folded field by field over
-- @record.set@ (@arguments_0@ .. @arguments_n@), an optional parameter folding through a @match@
-- whose @null@ arm skips the key — so an omitted argument and an explicit JSON null are never
-- conflated (@null@ is the Katari absence marker; a JSON null is @json.json_null()@).
--
-- Tool and parameter names are mangled to valid Katari identifiers deterministically (snake_case,
-- invalid characters to @_@, a leading digit prefixed, a reserved word suffixed, collisions bumped
-- with a numeric suffix); the ORIGINAL name always rides in the @tool = "..."@ argument or the
-- @record.set@ key, so the server sees exactly what it declared.
module Katari.Cli.McpCodegen
  ( McpListing (..),
    ToolListing (..),
    PullContext (..),
    renderBindingModule,
    mapSchema,
  )
where

import Data.Aeson (FromJSON (..), withObject, (.:), (.:?))
import Data.Char (isAlphaNum, isDigit, isLetter, isUpper, toLower)
import Data.List (sortOn)
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.List (List)
import Katari.Data.JSONSchema (AdditionalProperties (..), JSONSchema (..), ObjectSchema (..))
import Katari.Parser.Lexer (reservedWords)
import System.FilePath qualified as FilePath

---------------------------------------------------------------------------------------------------
-- The listing (what `katari-mcp list-tools` prints)
---------------------------------------------------------------------------------------------------

-- | One listed tool: the server-declared name \/ description and the schemas, decoded through
-- 'JSONSchema''s 'FromJSON' — the single authority on which JSON Schema subset the compiler models
-- (anything outside it decodes to an over-approximation and thus falls back to @json.json@ here).
data ToolListing = ToolListing
  { name :: Text,
    description :: Text,
    inputSchema :: JSONSchema,
    outputSchema :: Maybe JSONSchema
  }
  deriving stock (Show)

instance FromJSON ToolListing where
  parseJSON = withObject "ToolListing" $ \object' -> do
    name <- object' .: "name"
    description <- object' .:? "description"
    inputSchema <- object' .:? "inputSchema"
    outputSchema <- object' .:? "outputSchema"
    pure
      ToolListing
        { name = name,
          description = fromMaybe "" description,
          inputSchema = fromMaybe SchemaAny inputSchema,
          outputSchema = outputSchema
        }

newtype McpListing = McpListing
  { tools :: List ToolListing
  }
  deriving stock (Show)

instance FromJSON McpListing where
  parseJSON = withObject "McpListing" $ \object' -> McpListing <$> object' .: "tools"

---------------------------------------------------------------------------------------------------
-- The pull invocation the header records
---------------------------------------------------------------------------------------------------

data PullContext = PullContext
  { -- | The server url — baked as the literal everywhere in the binding (the @provide@ url, the
    -- @scope@ \/ @toolbox@ key, and every @mcp.call@ url), and part of the regenerate hint.
    url :: Text,
    -- | The @--out@ path, for the regenerate hint only.
    outPath :: Text
  }
  deriving stock (Show)

---------------------------------------------------------------------------------------------------
-- Schema -> Katari surface type (all-or-nothing)
---------------------------------------------------------------------------------------------------

-- | Map a JSON Schema to Katari surface type text. @Just@ carries a type with NO fallback anywhere
-- inside it; @Nothing@ means some part is outside the mapped subset and the caller must use
-- @json.json@ for the WHOLE schema (see the module comment for why partial mapping is unsound).
mapSchema :: JSONSchema -> Maybe Text
mapSchema schema = case schema of
  SchemaAny -> Nothing
  -- A bottom-typed parameter or output would be uncallable / undecodable; treat it as unmapped.
  SchemaNever -> Nothing
  SchemaNull -> Just "null"
  SchemaBoolean -> Just "boolean"
  SchemaInteger -> Just "integer"
  SchemaNumber -> Just "number"
  SchemaString -> Just "string"
  -- No literal types yet, so a pinned constant cannot be expressed.
  SchemaConst _ -> Nothing
  SchemaArray itemSchema -> do
    itemType <- mapSchema itemSchema
    pure ("array[" <> itemType <> "]")
  -- Tuples are representable in Katari but not in the mapping table yet (their wire validation
  -- semantics differ subtly from prefixItems); keep them a fallback.
  SchemaTuple _ -> Nothing
  SchemaObject objectSchema -> mapObjectSchema objectSchema
  SchemaAnyOf branches -> case branches of
    [] -> Nothing
    _ -> do
      memberTypes <- traverse mapSchema branches
      -- A union type is a flat @|@ at any nesting depth, so members join without parentheses.
      pure (Text.intercalate " | " memberTypes)
  -- A generic placeholder never appears in a server listing; decoding drift stays a fallback.
  SchemaGeneric _ -> Nothing

-- | An object with properties becomes an object type (a non-required property becomes a @?@
-- field); an object with ONLY schema-valued @additionalProperties@ becomes @record[T]@. A property
-- whose name is not a valid Katari identifier cannot be a field label, so it unmaps the object.
mapObjectSchema :: ObjectSchema -> Maybe Text
mapObjectSchema objectSchema = case objectSchema.properties of
  [] -> case objectSchema.additionalProperties of
    AdditionalPropertiesSchema valueSchema -> do
      valueType <- mapSchema valueSchema
      pure ("record[" <> valueType <> "]")
    -- An unconstrained (or key-less closed) object carries no field information to type.
    AdditionalPropertiesBoolean _ -> Nothing
  properties -> do
    fields <- traverse mapField properties
    pure ("{" <> Text.intercalate ", " fields <> "}")
  where
    requiredNames = Set.fromList objectSchema.required
    mapField (fieldName, fieldSchema) = do
      _ <- if isValidIdentifier fieldName then Just () else Nothing
      fieldType <- mapSchema fieldSchema
      let separator = if Set.member fieldName requiredNames then ": " else "?: "
      pure (fieldName <> separator <> fieldType)

-- | Whether a name parses as a Katari identifier as-is (the lexer's grammar: a letter or @_@ then
-- letters \/ digits \/ @_@, and not a reserved word).
isValidIdentifier :: Text -> Bool
isValidIdentifier name = case Text.uncons name of
  Nothing -> False
  Just (first, rest) ->
    (isLetter first || first == '_')
      && Text.all (\character -> isAlphaNum character || character == '_') rest
      && not (Set.member name reservedWords)

---------------------------------------------------------------------------------------------------
-- Identifier mangling (deterministic)
---------------------------------------------------------------------------------------------------

-- | Assign a fresh Katari identifier for a raw server-side name: snake_case it (an uppercase run
-- lowers, with @_@ inserted where it starts after a lowercase \/ digit; anything outside
-- letters \/ digits \/ @_@ becomes @_@), prefix a leading digit with @_@, replace an unusable
-- result with @fallback@, suffix a reserved word with @_@, then bump a collision against @used@
-- with @_2@, @_3@, ... Returns the assigned name and the extended used set.
assignIdentifier :: Text -> Set Text -> Text -> (Text, Set Text)
assignIdentifier fallback used raw =
  let assigned = deduplicate (reserve (normalize (snakeCase raw)))
   in (assigned, Set.insert assigned used)
  where
    normalize candidate
      | Text.null candidate || Text.all (== '_') candidate = fallback
      | otherwise = case Text.uncons candidate of
          Just (first, _) | isDigit first -> "_" <> candidate
          _ -> candidate
    reserve candidate
      | Set.member candidate reservedWords = candidate <> "_"
      | otherwise = candidate
    deduplicate candidate
      | Set.member candidate used = bump (2 :: Int)
      | otherwise = candidate
      where
        bump suffix =
          let bumped = candidate <> "_" <> Text.pack (show suffix)
           in if Set.member bumped used then bump (suffix + 1) else bumped

-- | Lower camelCase \/ kebab-case \/ arbitrary characters into snake_case, keeping every character
-- position (nothing is dropped, so distinct raw names stay distinct wherever possible).
snakeCase :: Text -> Text
snakeCase raw = Text.pack (walk Nothing (Text.unpack raw))
  where
    walk previous characters = case characters of
      [] -> []
      character : rest
        | isUpper character ->
            let separator = case previous of
                  Just previousCharacter
                    | isAlphaNum previousCharacter && not (isUpper previousCharacter) -> "_"
                  _ -> ""
             in separator <> (toLower character : walk (Just character) rest)
        | isAlphaNum character || character == '_' -> character : walk (Just character) rest
        | otherwise -> '_' : walk (Just character) rest

---------------------------------------------------------------------------------------------------
-- The generated module
---------------------------------------------------------------------------------------------------

-- | One tool, fully resolved for emission: its assigned identifier, its input plan (parameters in
-- the decoded property order — 'JSONSchema''s FromJSON yields properties in key order, so
-- generation is deterministic), and its output plan.
data ResolvedTool = ResolvedTool
  { originalName :: Text,
    identifier :: Text,
    description :: Text,
    input :: ResolvedInput,
    output :: ResolvedOutput
  }

-- | The wrapper's parameter plan: named parameters folded field by field into the arguments object,
-- or — for an input schema that names no properties to fold — one pass-through @arguments@ tree the
-- caller builds (so no tool is ever uncallable).
data ResolvedInput
  = InputFields (List ResolvedParameter)
  | InputPassthrough

data ResolvedParameter = ResolvedParameter
  { originalName :: Text,
    identifier :: Text,
    -- | @Just@ the mapped Katari type (embed with @json.encode@); @Nothing@ = the @json.json@
    -- fallback (insert into the tree as-is).
    mappedType :: Maybe Text,
    optional :: Bool
  }

-- | Whether the wrapper decodes its reply: only when the whole @outputSchema@ mapped ('OutputTyped'
-- carries the synonym name and its right-hand side); otherwise the raw @json.json@ tree returns.
data ResolvedOutput
  = OutputTyped Text Text
  | OutputRaw

-- | Render the whole binding module. Tools are sorted by their ORIGINAL server name, so
-- regeneration against an unchanged server is byte-identical.
renderBindingModule :: PullContext -> McpListing -> Text
renderBindingModule context listing =
  let resolvedTools = resolveTools (sortOn (.name) listing.tools)
   in Text.intercalate
        "\n"
        ( headerLines context
            <> credentialsRequestLines
            <> connectLines context
            <> concatMap (toolLines context) resolvedTools
        )
        <> "\n"

-- | The names a TOP-LEVEL tool agent must not take: Katari reserved words are handled inside
-- 'assignIdentifier'; these are the module's own top-level names a tool agent would collide with or
-- shadow — the @connect@ provider agent and the @credentials@ request (a tool of either name would
-- redeclare it), and the default-import qualifiers (@mcp@ \/ @json@ \/ @record@ \/ @prelude@) that the
-- tool bodies, @connect@, and the signatures reference in value or type position (a top-level agent
-- of that name would shadow the qualifier). @connect@'s own parameters (@auth@ \/ @continuation@) are
-- local to @connect@, so a top-level tool of that name cannot shadow them and needs no seed.
toolNameSeed :: Set Text
toolNameSeed = Set.fromList ["connect", "credentials", "mcp", "json", "record", "prelude"]

resolveTools :: List ToolListing -> List ResolvedTool
resolveTools = walk toolNameSeed
  where
    walk used tools = case tools of
      [] -> []
      tool : rest ->
        let (toolIdentifier, usedWithTool) = assignIdentifier "tool" used tool.name
         in resolveTool tool toolIdentifier : walk usedWithTool rest

resolveTool :: ToolListing -> Text -> ResolvedTool
resolveTool tool toolIdentifier =
  ResolvedTool
    { originalName = tool.name,
      identifier = toolIdentifier,
      description = tool.description,
      input = resolveInput tool.inputSchema,
      output = case tool.outputSchema >>= mapSchema of
        Just outputType -> OutputTyped (toolIdentifier <> "_output") outputType
        Nothing -> OutputRaw
    }

-- | The wrapper's input plan, from the input schema's top-level properties. A top-level property
-- name only labels the KATARI parameter (the original name rides in the @record.set@ key), so it is
-- mangled rather than falling back; anything below the top level cannot be renamed and stays under
-- the all-or-nothing rule. An input schema that names no properties at all folds nothing: a closed
-- empty object means "no arguments" (zero parameters, the empty object sent), anything else — a
-- property-less open object, a non-object — degrades to the pass-through tree.
resolveInput :: JSONSchema -> ResolvedInput
resolveInput inputSchema = case inputSchema of
  SchemaObject objectSchema -> case objectSchema.properties of
    [] -> case objectSchema.additionalProperties of
      AdditionalPropertiesBoolean False -> InputFields []
      _ -> InputPassthrough
    properties ->
      let requiredNames = Set.fromList objectSchema.required
          walk used remaining = case remaining of
            [] -> []
            (propertyName, propertySchema) : rest ->
              let (parameterIdentifier, usedNext) = assignIdentifier "argument" used propertyName
               in ResolvedParameter
                    { originalName = propertyName,
                      identifier = parameterIdentifier,
                      mappedType = mapSchema propertySchema,
                      optional = not (Set.member propertyName requiredNames)
                    }
                    : walk usedNext rest
       in InputFields (walk (parameterNameSeed (length properties)) properties)
  _ -> InputPassthrough

-- | The names a parameter identifier must not take: the @credentials@ request the body reads for
-- @auth@ (a parameter of that name would shadow it, so @auth = credentials()@ would call the
-- parameter instead of the request), the @arguments@ \/ @arguments_i@ fold chain (one slot per
-- parameter plus the seed), and the qualifiers the body references in value position (@mcp@ \/ @json@
-- \/ @record@ \/ @prelude@). @url@ \/ @auth@ no longer need a seed — the body references neither in
-- value position anymore (the url rides only as a literal, the auth only as @credentials()@).
parameterNameSeed :: Int -> Set Text
parameterNameSeed parameterCount =
  Set.fromList
    ( ["credentials", "arguments", "mcp", "json", "record", "prelude"]
        <> ["arguments_" <> Text.pack (show slot) | slot <- [0 .. parameterCount]]
    )

---------------------------------------------------------------------------------------------------
-- Emission
---------------------------------------------------------------------------------------------------

headerLines :: PullContext -> List Text
headerLines context =
  [ "// Generated by `katari mcp pull --url " <> context.url <> " --out " <> context.outPath <> "`.",
    "// Regenerate instead of editing.",
    "//",
    "// Each server tool is a TOP-LEVEL agent, callable directly after `use " <> moduleQualifier context <> "connect(auth = ...)`: a",
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
    "//     unmodelled schemas) falls back to `json.json`.",
    "// All-or-nothing on the PARAMETER side is the wire-form asymmetry: `json.encode` speaks the value",
    "// WIRE form, so a `json.json` nested inside a typed parameter would embed as its `$constructor` tree,",
    "// not the raw fragment the server expects — a fallback parameter is therefore inserted into the",
    "// arguments tree as-is (it already is a tree). The output side has no such asymmetry: `mcp.call[url,",
    "// T]` decodes the reply against `T` in the runtime, so a fully-mapped outputSchema instantiates `T`",
    "// to its type (decoded, `json.decode_error` on a mismatch) and any other tool instantiates `T` to",
    "// `json.json` (the raw reply as a tree)."
  ]

-- | The ambient @credentials@ request: @connect@ serves it (returning the connection's @auth@) and
-- every tool reads it for its @mcp.call@ auth, so a top-level tool closes over nothing. Its name is
-- namespaced by the generated module, so two servers' @credentials@ requests never collide.
credentialsRequestLines :: List Text
credentialsRequestLines =
  [ "",
    "@\"The connection's credentials — provided by `connect` for the scope's duration, read by every tool as `auth`.\"",
    "request credentials() -> mcp.auth"
  ]

-- | The @connect@ scoped provider. It takes NO @url@ parameter — the pulled url is baked as a literal
-- everywhere (which is what per-URL scoping needs), so it appears in @provide@'s @url@, the @toolbox@
-- \/ @scope@ keys, and every @mcp.call@. The body opens the scope with @mcp.provide@ (the @use@ form,
-- since Katari has no anonymous agent expressions — a provider is entered by capturing the rest of
-- the block as its continuation) and serves @credentials@ with a @use handler@. The @use@ binder on
-- the provide is REQUIRED (it carries the type annotation that supplies the continuation's
-- @toolbox[url]@ value type) but is discarded to @_@, because the tools call through the static
-- @mcp.call@ path rather than the minted toolbox. @provide@ discharges @scope[url]@ and the handler
-- discharges @credentials@, so only @io@ (the implicit effect of every external call, which a rigid
-- @E@ cannot absorb) remains on @connect@'s own row. The continuation row's MIXED spelling
-- @{...(E | scope[url]), credentials}@ is load-bearing: @scope[url]@ rides the UNION side so nested
-- @connect@s compose (a merged @scope[a | b]@ still covers each inner @provide@'s @scope[url]@, which
-- an overwrite-pinned entry cannot), while the handled @credentials@ rides the OVERWRITE side so it
-- is pinned out of the shared @E@ for the handler to discharge (a @| credentials@ union leaves it in
-- @E@ and the discharge fails, K3001). Inference solves @provide@'s own @E@ by cancelling the shared
-- @scope[url]@ entry, so the generated @use mcp.provide(...)@ needs no explicit @[url, R, E]@.
connectLines :: PullContext -> List Text
connectLines context =
  let scopeRow = scopeEffect context.url
      urlLiteral = "\"" <> escapeDocText context.url <> "\""
   in [ "",
        "@\"" <> escapeDocText (connectDoc context) <> "\"",
        "agent connect[R, effect E](",
        indent 1 "auth: mcp.auth,",
        indent 1 ("continuation: agent (value: null) -> R with {...(E | " <> scopeRow <> "), credentials},"),
        ") -> R with io | E {",
        indent 1 ("let _ : mcp.toolbox[" <> urlLiteral <> "] = use mcp.provide(url = " <> urlLiteral <> ", auth = auth)"),
        indent 1 "use handler {",
        indent 2 "request credentials() { next auth }",
        indent 1 "}",
        indent 1 "continuation(value = null)",
        "}"
      ]

-- | The scope effect a tool call carries, keyed by the pulled url literal: it rides every tool's
-- effect row and @connect@'s continuation row, and @mcp.provide@ discharges it. Module-qualified
-- (@mcp.scope@) since the binding module imports the prelude by default.
scopeEffect :: Text -> Text
scopeEffect url = "mcp.scope[\"" <> escapeDocText url <> "\"]"

-- | The module qualifier a caller writes, from the out path's base name (a Katari module is named
-- after its file): @"github."@ for @src/github.ktr@, or empty for a degenerate path with no base name
-- (so a doc reads @connect(...)@ rather than a bogus @.connect(...)@).
moduleQualifier :: PullContext -> Text
moduleQualifier context =
  let qualifier = Text.pack (FilePath.takeBaseName (Text.unpack context.outPath))
   in if Text.null qualifier then "" else qualifier <> "."

-- | The @connect@ doc: it opens the pulled server's connection for the extent of @continuation@ as a
-- bare @use@ statement, after which the tools are called directly. `auth` takes either
-- header/anonymous access or a named OAuth credential; the oauth form is the generic
-- @mcp.oauth(name = "...")@ placeholder — pull does not know (and no longer takes) a specific
-- credential name; the user fills in the one they established with @katari mcp login@. The pulled url
-- is inlined so the doc names the exact server the binding scopes.
connectDoc :: PullContext -> Text
connectDoc context =
  "Open the pulled MCP server's connection for the extent of @continuation@ — as a bare `use "
    <> moduleQualifier context
    <> "connect(auth = ...)`, after which the tools are called directly (`"
    <> moduleQualifier context
    <> "get_issue(...)`). Establishes a `provide` scope over `"
    <> context.url
    <> "`, serves the connection's `credentials` to every tool, and discharges both on return. "
    <> "`auth` is `mcp.headers(values = ...)` for header or anonymous access, or `mcp.oauth(name = \"...\")` "
    <> "for a credential established by `katari mcp login`."

-- | One tool's whole emission, top-level: a blank separator, its output synonym (when the output
-- mapped — a plain comment carries the provenance, since a type synonym takes no @\@"..."@), its own
-- doc annotation on its own line (top-level declarations are block-mode, so — unlike the old nested
-- statements — the annotation need not share the @agent@ line), then the agent.
toolLines :: PullContext -> ResolvedTool -> List Text
toolLines context tool =
  "" : synonymBlock <> docLine <> toolAgentLines context tool
  where
    synonymBlock = case tool.output of
      OutputRaw -> []
      OutputTyped synonymName outputType ->
        [ "// The declared output of `" <> tool.originalName <> "`.",
          "type " <> synonymName <> " = " <> outputType,
          ""
        ]
    docLine
      | Text.null tool.description = []
      | otherwise = ["@\"" <> escapeDocText tool.description <> "\""]

-- | One tool as a top-level agent: it reads the ambient @credentials()@ for its @mcp.call@ auth (a
-- top-level agent closes over nothing), and its row carries @io@, the provide @scope@, the
-- @credentials@ request, and `mcp.call`'s throws.
toolAgentLines :: PullContext -> ResolvedTool -> List Text
toolAgentLines context tool =
  [ "agent " <> tool.identifier <> "(" <> parameterList tool <> ") -> " <> outputTypeText tool.output <> " with " <> effectRow (scopeEffect context.url) <> " {"
  ]
    <> argumentLines
    <> [ indent 1 (call argumentsExpression),
         "}"
       ]
  where
    urlLiteral = "\"" <> escapeDocText context.url <> "\""
    -- The url is the pulled literal (there is no `url` parameter) — this binds `mcp.call`'s `[literal
    -- URL]` generic to the singleton (satisfying the `scope[url]` gate); `T` is the second, explicit
    -- generic (the mapped output type, or `json.json`), against which the runtime decodes the reply. Both
    -- generics MUST be written — a `literal` generic is inferred but still counts toward the explicit
    -- `[...]` arity — so the url literal appears in the instantiation and again as the `url` argument. The
    -- `auth` is the ambient `credentials()` (not a closed-over value). The call is the tool's tail
    -- expression: no trailing `json.decode`, since `mcp.call` decodes itself.
    call argumentsText =
      "mcp.call["
        <> urlLiteral
        <> ", "
        <> outputTypeText tool.output
        <> "](url = "
        <> urlLiteral
        <> ", auth = credentials(), tool = \""
        <> escapeDocText tool.originalName
        <> "\", arguments = "
        <> argumentsText
        <> ")"
    -- The arguments object the call sends: the caller's pass-through tree as-is, or the folded object.
    argumentsExpression = case tool.input of
      InputPassthrough -> "arguments"
      InputFields parameters -> "json.json_object(entries = arguments_" <> Text.pack (show (length parameters)) <> ")"
    argumentLines = case tool.input of
      -- The pass-through plan: the caller's tree IS the arguments object, nothing to fold.
      InputPassthrough -> []
      InputFields parameters ->
        [indent 1 "let arguments_0 = record.empty()"]
          <> concat (zipWith parameterFoldLines [0 ..] parameters)

-- | One parameter's fold step: @arguments_i@ -> @arguments_(i+1)@. A required parameter folds
-- unconditionally; an optional one matches @null@ (absent — the key is omitted) against @present@.
-- A mapped parameter embeds through @json.encode@; a fallback parameter IS a tree already and is
-- inserted as-is (the wire-form asymmetry — see the module comment).
parameterFoldLines :: Int -> ResolvedParameter -> List Text
parameterFoldLines slot parameter =
  let source = "arguments_" <> Text.pack (show slot)
      target = "arguments_" <> Text.pack (show (slot + 1))
      embed subject = case parameter.mappedType of
        Just _ -> "json.encode(value = " <> subject <> ")"
        Nothing -> subject
      insert subject = "record.set(target = " <> source <> ", key = \"" <> escapeDocText parameter.originalName <> "\", value = " <> embed subject <> ")"
   in if parameter.optional
        then
          [ indent 1 ("let " <> target <> " = match (" <> parameter.identifier <> ") {"),
            indent 2 ("case null -> " <> source),
            indent 2 ("case present -> " <> insert "present"),
            indent 1 "}"
          ]
        else [indent 1 ("let " <> target <> " = " <> insert parameter.identifier)]

-- | The tool declaration's parameter list: @name: T@, or @name: T | null ?= null@ when optional
-- (defaulting to @null@ marks absence — the fold omits the key, so absent and JSON null never
-- conflate).
parameterList :: ResolvedTool -> Text
parameterList tool = case tool.input of
  InputPassthrough -> "arguments: json.json"
  InputFields parameters -> Text.intercalate ", " (parameterSignatureText <$> parameters)
  where
    parameterSignatureText parameter =
      let baseType = fromMaybe "json.json" parameter.mappedType
       in if parameter.optional
            then parameter.identifier <> ": " <> baseType <> " | null ?= null"
            else parameter.identifier <> ": " <> baseType

outputTypeText :: ResolvedOutput -> Text
outputTypeText output = case output of
  OutputTyped synonymName _ -> synonymName
  OutputRaw -> "json.json"

-- | The tool's effect row: @io@ (an external call), the provide @scope@ the call is gated by, the
-- ambient @credentials@ request the tool reads for its auth, and the three typed throws `mcp.call`
-- itself declares — @server_error@ / @auth_error@ and @json.decode_error@ (the runtime raises the last
-- when a reply does not conform to the decode target). It is UNIFORM across both output plans: even
-- the @json.json@ plan calls the same @mcp.call[...]@, whose row carries @decode_error@, so the tool
-- must carry it too (it is never actually raised for @json.json@, which keeps the raw tree). The scope
-- ties the call to the enclosing @provide@; @credentials@ ties it to @connect@'s handler.
effectRow :: Text -> Text
effectRow scopeRow =
  "io | " <> scopeRow <> " | credentials | prelude.throw[mcp.server_error | mcp.auth_error | json.decode_error]"

-- | Escape text into a Katari string \/ doc-annotation literal: backslash and double quote escape,
-- newlines become the @\\n@ escape so every generated literal stays on one line, and the other
-- control characters the lexer has escapes for follow suit.
escapeDocText :: Text -> Text
escapeDocText = Text.concatMap escapeCharacter
  where
    escapeCharacter character = case character of
      '\\' -> "\\\\"
      '"' -> "\\\""
      '\n' -> "\\n"
      '\t' -> "\\t"
      '\r' -> "\\r"
      other -> Text.singleton other

indent :: Int -> Text -> Text
indent level line = Text.replicate level "  " <> line
