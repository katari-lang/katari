-- | Code generation for @katari mcp pull@: one MCP server listing in, one self-contained Katari
-- binding module out — a @connect@ agent whose result record carries one typed wrapper agent per
-- server tool, each closed over the connection (@url@ + @auth@) and calling through the schema-blind
-- @mcp.call@ external.
--
-- The type mapping is ALL-OR-NOTHING per parameter and per tool output, forced by the wire-form
-- asymmetry of the @json@ boundary: @json.encode@ \/ @json.decode@ speak the value WIRE form, so a
-- @json.json@ nested INSIDE a typed value would embed as its @$constructor@ tree — not as the raw
-- fragment an MCP server expects. A parameter whose schema maps completely is embedded with
-- @json.encode@; a parameter with any unmapped part falls back to @json.json@ as a whole and is
-- inserted into the arguments tree AS-IS (it already is a tree). Symmetrically, a tool's reply is
-- decoded with @json.decode[...]@ only when its ENTIRE @outputSchema@ maps; any other tool returns
-- the raw @json.json@ reply.
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
  { -- | The server url — @connect@'s default and part of the regenerate hint.
    url :: Text,
    -- | The @--out@ path, for the regenerate hint only.
    outPath :: Text,
    -- | The @--name@ OAuth credential the connect doc suggests (established by @katari mcp login@).
    credentialName :: Maybe Text
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
            <> concatMap synonymLines resolvedTools
            <> connectLines context resolvedTools
        )
        <> "\n"

-- | The names a tool identifier must not take: Katari reserved words are handled inside
-- 'assignIdentifier'; these are the module's own working names — @connect@'s parameters (a tool
-- agent would shadow them for every OTHER wrapper's body), @connect@ itself, and the default-import
-- qualifiers the bodies and signatures reference in value position.
toolNameSeed :: Set Text
toolNameSeed = Set.fromList ["connect", "url", "auth", "mcp", "json", "record", "prelude"]

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

-- | The names a parameter identifier must not take: the closed-over connection (@url@ \/ @auth@),
-- the body's working names (@raw@ and the @arguments_i@ fold chain — one slot per parameter plus
-- the seed), and the qualifiers the body references in value position.
parameterNameSeed :: Int -> Set Text
parameterNameSeed parameterCount =
  Set.fromList
    ( ["url", "auth", "raw", "arguments", "mcp", "json", "record", "prelude"]
        <> ["arguments_" <> Text.pack (show slot) | slot <- [0 .. parameterCount]]
    )

---------------------------------------------------------------------------------------------------
-- Emission
---------------------------------------------------------------------------------------------------

headerLines :: PullContext -> List Text
headerLines context =
  [ "// Generated by `katari mcp pull --url " <> context.url <> " --out " <> context.outPath <> nameHint <> "`.",
    "// Regenerate instead of editing.",
    "//",
    "// Type mapping (JSON Schema -> Katari), all-or-nothing per parameter and per tool output:",
    "//   - string / integer / number / boolean / null map directly; array -> array[T];",
    "//   - an object with properties -> an object type (a non-required property becomes a `?` field);",
    "//   - an object with only schema-valued additionalProperties -> record[T];",
    "//   - an anyOf whose members all map -> a union;",
    "//   - everything else (enum / const — no literal types yet — allOf / oneOf, tuples, open or",
    "//     unmodelled schemas) falls back to `json.json`.",
    "// All-or-nothing is the wire-form asymmetry: `json.encode` / `json.decode` speak the value WIRE",
    "// form, so a `json.json` nested inside a typed value would embed as its `$constructor` tree, not",
    "// as the raw fragment the server expects. A fallback parameter is therefore inserted into the",
    "// arguments tree as-is (it already is a tree), and a reply is decoded with `json.decode[...]`",
    "// only when the entire outputSchema maps — any other tool returns the raw `json.json` reply."
  ]
  where
    nameHint = maybe "" (" --name " <>) context.credentialName

-- | The per-tool output synonym, only where the output mapped. (Type synonyms take no @\@"..."@
-- annotation, so the provenance is a plain comment.)
synonymLines :: ResolvedTool -> List Text
synonymLines tool = case tool.output of
  OutputRaw -> []
  OutputTyped synonymName outputType ->
    [ "",
      "// The declared output of `" <> tool.originalName <> "`.",
      "type " <> synonymName <> " = " <> outputType
    ]

connectLines :: PullContext -> List ResolvedTool -> List Text
connectLines context resolvedTools =
  [ "",
    "@\"" <> escapeDocText (connectDoc context) <> "\"",
    "agent connect(url: string ?= \"" <> escapeDocText context.url <> "\", auth: mcp.auth) -> {"
  ]
    <> [indent 1 (returnTypeField tool) | tool <- resolvedTools]
    <> ["} {"]
    <> concatMap (map indentToolLine . toolAgentLines) resolvedTools
    <> ["", indent 1 "{"]
    <> [indent 2 (tool.identifier <> " = " <> tool.identifier <> ",") | tool <- resolvedTools]
    <> [indent 1 "}", "}"]

-- | Indent a tool agent's line one level inside connect's body — except a blank separator line,
-- which stays empty (trailing whitespace would churn diffs and formatters).
indentToolLine :: Text -> Text
indentToolLine line = if Text.null line then line else indent 1 line

connectDoc :: PullContext -> Text
connectDoc context =
  "Connect to the pulled MCP server — returns the typed tools closed over the connection (@url@ +\n\
  \@auth@). `auth` is `mcp.headers(values = ...)` for header or anonymous access, or\n\
  \`mcp.oauth(name = \""
    <> fromMaybe "<name>" context.credentialName
    <> "\")` for a credential established by `katari mcp login`."

returnTypeField :: ResolvedTool -> Text
returnTypeField tool =
  tool.identifier <> ": agent(" <> parameterTypeList tool <> ") -> " <> outputTypeText tool.output <> " with " <> effectRow tool.output <> ","

toolAgentLines :: ResolvedTool -> List Text
toolAgentLines tool =
  [ "",
    docPrefix <> "agent " <> tool.identifier <> "(" <> parameterList tool <> ") -> " <> outputTypeText tool.output <> " with " <> effectRow tool.output <> " {"
  ]
    <> bodyLines
    <> [ indent 1 (resultExpression tool.output),
         "}"
       ]
  where
    -- A local agent is a statement, parsed in line mode — its doc annotation must sit on the SAME
    -- line as the `agent` keyword (a lone-line annotation would end the statement at the newline).
    docPrefix
      | Text.null tool.description = ""
      | otherwise = "@\"" <> escapeDocText tool.description <> "\" "
    call argumentsText = "let raw = mcp.call(url = url, auth = auth, tool = \"" <> escapeDocText tool.originalName <> "\", arguments = " <> argumentsText <> ")"
    bodyLines = case tool.input of
      -- The pass-through plan: the caller's tree IS the arguments object, as-is.
      InputPassthrough -> [indent 1 (call "arguments")]
      InputFields parameters ->
        [indent 1 "let arguments_0 = record.empty()"]
          <> concat (zipWith parameterFoldLines [0 ..] parameters)
          <> [indent 1 (call ("json.json_object(entries = arguments_" <> Text.pack (show (length parameters)) <> ")"))]

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

resultExpression :: ResolvedOutput -> Text
resultExpression output = case output of
  OutputTyped synonymName _ -> "json.decode[" <> synonymName <> "](value = raw)"
  OutputRaw -> "raw"

-- | The wrapper declaration's parameter list: @name: T@, or @name: T | null ?= null@ when optional
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

-- | The same parameters in TYPE position (connect's return object): a default is not type syntax,
-- so an optional parameter renders as an optional field — @name?: T@ elaborates to @null | T@,
-- exactly the declaration's @T | null@ with a default (a defaulted parameter is an optional field
-- of the agent's parameter object).
parameterTypeList :: ResolvedTool -> Text
parameterTypeList tool = case tool.input of
  InputPassthrough -> "arguments: json.json"
  InputFields parameters -> Text.intercalate ", " (parameterFieldText <$> parameters)
  where
    parameterFieldText parameter =
      let baseType = fromMaybe "json.json" parameter.mappedType
          separator = if parameter.optional then "?: " else ": "
       in parameter.identifier <> separator <> baseType

outputTypeText :: ResolvedOutput -> Text
outputTypeText output = case output of
  OutputTyped synonymName _ -> synonymName
  OutputRaw -> "json.json"

-- | The wrapper's effect row: whatever @mcp.call@ carries (@io@ — an external call — plus the two
-- typed mcp throws), and @json.decode_error@ only when the wrapper decodes.
effectRow :: ResolvedOutput -> Text
effectRow output = case output of
  OutputTyped _ _ -> "io | prelude.throw[mcp.server_error | mcp.auth_error | json.decode_error]"
  OutputRaw -> "io | prelude.throw[mcp.server_error | mcp.auth_error]"

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
