-- | The @katari docs@ extraction: project a program's declarations into the library-API-reference
-- JSON (contract @katariDocsVersion = 1@, see @docs/2026-07-17-library-api-reference.md@).
--
-- The surface type is the primary data — generics, effect rows, @of@ attributes, unions and synonym
-- references carry information a JSON schema cannot express — so every type is emitted as a
-- 'TypeNode' tree that mirrors 'SyntacticTypeExpression' faithfully, with a @rendered@ source form
-- on every node. The renderer lives here and nowhere else: consumers (katari-web) never synthesise
-- type text, so any node at any depth is copyable as-is.
--
-- Schemas are NOT re-derived: the lowered IR already carries each callable's 'SchemaInformation'
-- (the same wire view the runtime's @get_metadata@ hands an AI), so the docs look it up by the
-- declaration's qualified name and attach it only when it is closed (no generic placeholders).
--
-- Extraction is phase-polymorphic through 'DocsExtraction' so the Typed user program and the Parsed
-- stdlib (@--stdlib@ has no typed AST to read) share one walker; the phase-dependent reads —
-- resolution and the checked type — are the two accessor fields, everything else is phase-free.
module Katari.Docs where

import Data.Aeson (ToJSON (..), Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Pair)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.List (List)
import Katari.Data.AST
import Katari.Data.GenericKind (GenericKind (..), renderGenericKind)
import Katari.Data.IR (Agent (..), Block (..), BlockInformation (..), EntryInformation (..), IRModule (..), SchemaInformation (..))
import Katari.Data.Id (TypeResolution (..))
import Katari.Data.JSONSchema (JSONSchema (..))
import Katari.Data.ModuleName (ModuleName)
import Katari.Data.QualifiedName (QualifiedName (..))
import Katari.Data.SemanticType (renderSemanticType, renderStringLiteralType)

-- | The docs JSON contract version, bumped on any breaking change to the emitted shape so a
-- consumer can reject a document it does not understand.
katariDocsVersion :: Int
katariDocsVersion = 1

---------------------------------------------------------------------------------------------------
-- Phase access
---------------------------------------------------------------------------------------------------

-- | The two phase-dependent reads the extraction needs, passed as accessors so one walker serves
-- both the Typed user program and the Parsed stdlib (whose typed AST the compile driver does not
-- retain).
data DocsExtraction phase = DocsExtraction
  { typeResolution :: Reference phase TypeReference -> Maybe TypeResolution,
    checkedType :: ExpressionType phase -> Maybe Text
  }

typedExtraction :: DocsExtraction Typed
typedExtraction =
  DocsExtraction
    { typeResolution = (.resolution),
      checkedType = Just . renderSemanticType
    }

-- | The Parsed phase carries no resolution and no checked type, so both accessors are constantly
-- empty — a stdlib 'TypeNode' still shows its surface qualifier, which is enough to link against.
parsedExtraction :: DocsExtraction Parsed
parsedExtraction =
  DocsExtraction
    { typeResolution = const Nothing,
      checkedType = const Nothing
    }

---------------------------------------------------------------------------------------------------
-- Document shape (the JSON contract, one Haskell record per object)
---------------------------------------------------------------------------------------------------

data DocsDocument = DocsDocument
  { compilerVersion :: Text,
    packageName :: Text,
    packageVersion :: Maybe Text,
    modules :: List DocsModule
  }
  deriving stock (Eq, Show)

data DocsModule = DocsModule
  { name :: ModuleName,
    declarations :: List DocsDeclaration
  }
  deriving stock (Eq, Show)

data DeclarationKind
  = DeclarationKindAgent
  | DeclarationKindExternalAgent
  | DeclarationKindPrimitiveAgent
  | DeclarationKindRequest
  | DeclarationKindMarkerEffect
  | DeclarationKindData
  | DeclarationKindTypeSynonym
  deriving stock (Eq, Show)

-- | One declaration row. The contract is a single object shape across every kind: a field a kind
-- does not define stays @null@ (and serialises as @null@), except 'private', which exists only on
-- agent declarations and is omitted from the JSON elsewhere.
data DocsDeclaration = DocsDeclaration
  { kind :: DeclarationKind,
    name :: Text,
    -- | Handle privacy of an @agent@ declaration ('Nothing' for every other kind). A private agent
    -- is still part of the API surface — its handle is callable from a private world — so it is
    -- documented rather than hidden.
    private :: Maybe Bool,
    documentation :: Maybe Text,
    signature :: Text,
    generics :: List GenericDocumentation,
    parameters :: List ParameterDocumentation,
    returnType :: Maybe TypeNode,
    effects :: Maybe TypeNode,
    -- | Agent only: the checker-resolved function type (inference included), the truth the surface
    -- signature may under-specify (an omitted return / effect, a destructuring parameter).
    checkedType :: Maybe Text,
    -- | External agent only: the @from "name"@ reactor clause as written ('Nothing' when the call
    -- routes to the default FFI sidecar — the default is the runtime's, not restated here).
    reactor :: Maybe Text,
    -- | Type synonym only: the right-hand side.
    definition :: Maybe TypeNode,
    -- | The wire view from the lowered IR, attached only when closed (see 'closedSchema').
    schema :: Maybe SchemaInformation
  }
  deriving stock (Eq, Show)

data GenericDocumentation = GenericDocumentation
  { name :: Text,
    kind :: GenericKind,
    bindsLiteral :: Bool,
    upperBound :: Maybe TypeNode
  }
  deriving stock (Eq, Show)

data ParameterDocumentation = ParameterDocumentation
  { label :: Text,
    documentation :: Maybe Text,
    -- | 'Nothing' for an agent parameter without a type annotation (and for a destructuring
    -- parameter, whose shape is a pattern, not a type) — 'DocsDeclaration.checkedType' carries the
    -- inferred truth.
    parameterType :: Maybe TypeNode,
    defaultValue :: Maybe LiteralValue
  }
  deriving stock (Eq, Show)

---------------------------------------------------------------------------------------------------
-- TypeNode (the structured surface-type tree)
---------------------------------------------------------------------------------------------------

-- | A faithful, phase-free image of one 'SyntacticTypeExpression' node. @rendered@ is this node's
-- own source form (never parenthesised — a parent adds parentheses when its grammar slot needs
-- them), so every node is independently copyable.
data TypeNode = TypeNode
  { rendered :: Text,
    detail :: TypeNodeDetail
  }
  deriving stock (Eq, Show)

data TypeNodeDetail where
  DetailPrimitive :: Text -> TypeNodeDetail
  DetailStringLiteral :: Text -> TypeNodeDetail
  DetailNever :: TypeNodeDetail
  DetailUnknown :: TypeNodeDetail
  DetailAll :: TypeNodeDetail
  DetailIo :: TypeNodeDetail
  DetailPure :: TypeNodeDetail
  DetailArray :: TypeNodeDetail
  DetailRecord :: TypeNodeDetail
  DetailName :: NameDetail -> TypeNodeDetail
  DetailAgent :: AgentDetail -> TypeNodeDetail
  DetailApplication :: ApplicationDetail -> TypeNodeDetail
  DetailTuple :: List TypeNode -> TypeNodeDetail
  DetailUnion :: List TypeNode -> TypeNodeDetail
  DetailObject :: List ObjectFieldDocumentation -> TypeNodeDetail
  DetailAttributed :: AttributedDetail -> TypeNodeDetail
  DetailAttributeLiteral :: Text -> TypeNodeDetail
  DetailOverride :: OverrideDetail -> TypeNodeDetail
  deriving stock (Eq, Show)

data NameDetail = NameDetail
  { qualifier :: Maybe Text,
    name :: Text,
    resolved :: Maybe ResolvedTypeReference
  }
  deriving stock (Eq, Show)

-- | Where a surface type name points after resolution: a declaration (linkable by qualified name)
-- or a generic parameter of the enclosing declaration (identified by its surface name — a generic
-- is always referenced unqualified, so the node's own name is its identity within the declaration).
data ResolvedTypeReference where
  ResolvedQualifiedName :: QualifiedName -> ResolvedTypeReference
  ResolvedGenericParameter :: Text -> ResolvedTypeReference
  deriving stock (Eq, Show)

data AgentDetail = AgentDetail
  { parameter :: TypeNode,
    returnType :: TypeNode,
    effects :: Maybe TypeNode
  }
  deriving stock (Eq, Show)

data ApplicationDetail = ApplicationDetail
  { applicationHead :: TypeNode,
    applicationArguments :: List TypeNode
  }
  deriving stock (Eq, Show)

data ObjectFieldDocumentation = ObjectFieldDocumentation
  { name :: Text,
    optional :: Bool,
    fieldType :: TypeNode
  }
  deriving stock (Eq, Show)

data AttributedDetail = AttributedDetail
  { base :: TypeNode,
    attribute :: TypeNode
  }
  deriving stock (Eq, Show)

data OverrideDetail = OverrideDetail
  { base :: TypeNode,
    overrides :: List TypeNode
  }
  deriving stock (Eq, Show)

---------------------------------------------------------------------------------------------------
-- Rendering precedence
--
-- Mirrors the grammar of "Katari.Parser.Type" (loosest first: union, attribution, application,
-- atoms), so a rendered tree re-parses to the same shape with the fewest parentheses.
---------------------------------------------------------------------------------------------------

unionLevel, attributedLevel, applicationLevel, atomLevel :: Int
unionLevel = 0
attributedLevel = 1
applicationLevel = 2
atomLevel = 3

-- | How tightly a node's own rendering binds. An agent type sits at the loosest level even though
-- the parser accepts it as an atom head: its return type extends greedily to the right (a following
-- @of@ / @|@ / @[...]@ would be swallowed into the return), so anywhere tighter than a whole
-- expression it must be parenthesised.
bindingLevel :: SyntacticTypeExpression phase -> Int
bindingLevel = \case
  TypeUnion _ -> unionLevel
  TypeAgent _ -> unionLevel
  TypeAttributed _ -> attributedLevel
  TypeApplication _ -> applicationLevel
  TypePrimitive _ -> atomLevel
  TypeStringLiteral _ -> atomLevel
  TypeNever _ -> atomLevel
  TypeUnknown _ -> atomLevel
  TypeAll _ -> atomLevel
  TypeIo _ -> atomLevel
  TypePure _ -> atomLevel
  TypeName _ -> atomLevel
  TypeArray _ -> atomLevel
  TypeRecord _ -> atomLevel
  TypeTuple _ -> atomLevel
  TypeObject _ -> atomLevel
  TypeAttributeLiteral _ -> atomLevel
  TypeOverride _ -> atomLevel

-- | A child's text inside a parent slot that requires at least @requiredLevel@ binding strength:
-- the child's own rendering, parenthesised when it binds looser than the slot admits.
embeddedText :: Int -> SyntacticTypeExpression phase -> TypeNode -> Text
embeddedText requiredLevel childExpression childNode =
  if bindingLevel childExpression >= requiredLevel
    then childNode.rendered
    else "(" <> childNode.rendered <> ")"

---------------------------------------------------------------------------------------------------
-- TypeNode construction (structure and rendering in one pass, so the two can never drift)
---------------------------------------------------------------------------------------------------

buildTypeNode :: DocsExtraction phase -> SyntacticTypeExpression phase -> TypeNode
buildTypeNode extraction expression = case expression of
  TypePrimitive node ->
    let keyword = renderPrimitiveTypeKind node.kind
     in TypeNode {rendered = keyword, detail = DetailPrimitive keyword}
  TypeStringLiteral node ->
    TypeNode {rendered = renderStringLiteralType node.value, detail = DetailStringLiteral node.value}
  TypeNever _ -> TypeNode {rendered = "never", detail = DetailNever}
  TypeUnknown _ -> TypeNode {rendered = "unknown", detail = DetailUnknown}
  TypeAll _ -> TypeNode {rendered = "all", detail = DetailAll}
  TypeIo _ -> TypeNode {rendered = "io", detail = DetailIo}
  TypePure _ -> TypeNode {rendered = "pure", detail = DetailPure}
  TypeArray _ -> TypeNode {rendered = "array", detail = DetailArray}
  TypeRecord _ -> TypeNode {rendered = "record", detail = DetailRecord}
  TypeName node ->
    let qualifier = (\moduleQualifier -> moduleQualifier.name) <$> node.moduleQualifier
     in TypeNode
          { rendered = maybe node.name (\qualifierName -> qualifierName <> "." <> node.name) qualifier,
            detail =
              DetailName
                NameDetail
                  { qualifier = qualifier,
                    name = node.name,
                    resolved = resolvedReference extraction node
                  }
          }
  TypeAgent node ->
    let parameterNode = buildTypeNode extraction node.parameterType
        returnNode = buildTypeNode extraction node.returnType
        effectsNode = buildTypeNode extraction <$> node.effects
        -- An object parameter renders through the canonical parenthesised sugar (the way agent
        -- types are written in source); any other parameter type sits in the application-level
        -- slot the grammar gives it.
        parameterText = case parameterNode.detail of
          DetailObject fields -> "(" <> Text.intercalate ", " (objectFieldText <$> fields) <> ")"
          _ -> " " <> embeddedText applicationLevel node.parameterType parameterNode
        -- With a `with` clause present, an agent-typed return must be parenthesised: re-parsed
        -- without parentheses, the inner agent type would capture the outer effect clause.
        returnText = case (node.effects, node.returnType) of
          (Just _, TypeAgent _) -> "(" <> returnNode.rendered <> ")"
          _ -> returnNode.rendered
        effectsText = maybe "" (\effectNode -> " with " <> effectNode.rendered) effectsNode
     in TypeNode
          { rendered = "agent" <> parameterText <> " -> " <> returnText <> effectsText,
            detail =
              DetailAgent
                AgentDetail {parameter = parameterNode, returnType = returnNode, effects = effectsNode}
          }
  TypeApplication node ->
    let headNode = buildTypeNode extraction node.applicationHead
        argumentNodes = buildTypeNode extraction <$> node.applicationArguments
     in TypeNode
          { rendered =
              embeddedText applicationLevel node.applicationHead headNode
                <> "["
                <> Text.intercalate ", " ((.rendered) <$> argumentNodes)
                <> "]",
            detail =
              DetailApplication
                ApplicationDetail {applicationHead = headNode, applicationArguments = argumentNodes}
          }
  TypeTuple node ->
    let elementNodes = buildTypeNode extraction <$> node.elementTypes
     in TypeNode
          { rendered = "[" <> Text.intercalate ", " ((.rendered) <$> elementNodes) <> "]",
            detail = DetailTuple elementNodes
          }
  TypeUnion node ->
    let branchNodes = [(branch, buildTypeNode extraction branch) | branch <- node.branches]
     in TypeNode
          { rendered =
              Text.intercalate
                " | "
                [embeddedText attributedLevel branch branchNode | (branch, branchNode) <- branchNodes],
            detail = DetailUnion (snd <$> branchNodes)
          }
  TypeObject node ->
    let fields =
          [ ObjectFieldDocumentation
              { name = field.name,
                optional = field.optional,
                fieldType = buildTypeNode extraction field.fieldType
              }
            | field <- node.fields
          ]
     in TypeNode
          { rendered = "{" <> Text.intercalate ", " (objectFieldText <$> fields) <> "}",
            detail = DetailObject fields
          }
  TypeAttributed node ->
    let baseNode = buildTypeNode extraction node.baseType
        attributeNode = buildTypeNode extraction node.attribute
     in TypeNode
          { rendered =
              embeddedText attributedLevel node.baseType baseNode
                <> " of "
                <> embeddedText applicationLevel node.attribute attributeNode,
            detail = DetailAttributed AttributedDetail {base = baseNode, attribute = attributeNode}
          }
  TypeAttributeLiteral node ->
    let keyword = case node.kind of
          AttributeLiteralPublic -> "public"
          AttributeLiteralPrivate -> "private"
     in TypeNode {rendered = keyword, detail = DetailAttributeLiteral keyword}
  TypeOverride node ->
    let baseNode = buildTypeNode extraction node.base
        overrideNodes = [(override, buildTypeNode extraction override) | override <- node.overrides]
     in TypeNode
          { rendered =
              "{..."
                <> baseNode.rendered
                <> Text.concat
                  [", " <> embeddedText applicationLevel override overrideNode | (override, overrideNode) <- overrideNodes]
                <> "}",
            detail = DetailOverride OverrideDetail {base = baseNode, overrides = snd <$> overrideNodes}
          }

resolvedReference :: DocsExtraction phase -> TypeNameNode phase -> Maybe ResolvedTypeReference
resolvedReference extraction node = case extraction.typeResolution node.typeReference of
  Just (TypeResolutionQualifiedName qualifiedName) -> Just (ResolvedQualifiedName qualifiedName)
  Just (TypeResolutionGeneric _) -> Just (ResolvedGenericParameter node.name)
  Nothing -> Nothing

renderPrimitiveTypeKind :: PrimitiveTypeKind -> Text
renderPrimitiveTypeKind = \case
  PrimitiveTypeKindNull -> "null"
  PrimitiveTypeKindInteger -> "integer"
  PrimitiveTypeKindNumber -> "number"
  PrimitiveTypeKindString -> "string"
  PrimitiveTypeKindBoolean -> "boolean"
  PrimitiveTypeKindFile -> "file"

objectFieldText :: ObjectFieldDocumentation -> Text
objectFieldText field = field.name <> optionalMark <> ": " <> field.fieldType.rendered
  where
    optionalMark = if field.optional then "?" else ""

renderLiteralValue :: LiteralValue -> Text
renderLiteralValue = \case
  LiteralValueInteger value -> Text.pack (show value)
  LiteralValueNumber value -> Text.pack (show value)
  LiteralValueString value -> renderStringLiteralType value
  LiteralValueBoolean True -> "true"
  LiteralValueBoolean False -> "false"
  LiteralValueNull -> "null"

---------------------------------------------------------------------------------------------------
-- Declaration extraction
---------------------------------------------------------------------------------------------------

-- | Project a compiled program into its documented modules: one 'DocsModule' per source module (in
-- name order, so the output is deterministic), each carrying its declarations in source order.
extractModules ::
  DocsExtraction phase ->
  Map ModuleName (Module phase) ->
  Map ModuleName IRModule ->
  List DocsModule
extractModules extraction modules loweredModules =
  [ DocsModule
      { name = moduleName,
        declarations = mapMaybe (extractDeclaration extraction loweredModules moduleName) module'.declarations
      }
    | (moduleName, module') <- Map.toAscList modules
  ]

-- | One declaration's documentation row. Imports and parse-error sentinels are not API surface, so
-- they yield nothing; every real declaration — including a @private agent@, whose handle is part of
-- the API for private callers — is documented.
extractDeclaration ::
  DocsExtraction phase ->
  Map ModuleName IRModule ->
  ModuleName ->
  Declaration phase ->
  Maybe DocsDeclaration
extractDeclaration extraction loweredModules moduleName = \case
  DeclarationAgent declaration ->
    let generics = genericDocumentation extraction <$> declaration.genericParameters
        parameters = bindingParameter extraction <$> declaration.parameters
        returnType = buildTypeNode extraction <$> declaration.returnType
        effects = buildTypeNode extraction <$> declaration.effects
        privatePrefix = if declaration.private then "private " else ""
        signature =
          privatePrefix
            <> "agent "
            <> declaration.name
            <> renderGenericsClause generics
            <> renderParametersClause parameters
            <> renderReturnClause returnType
            <> renderEffectsClause effects
     in Just
          (baseDeclaration DeclarationKindAgent declaration.name signature)
            { private = Just declaration.private,
              documentation = declaration.annotation,
              generics = generics,
              parameters = parameters,
              returnType = returnType,
              effects = effects,
              checkedType = extraction.checkedType declaration.typeOf,
              schema = wireSchema loweredModules moduleName declaration.name
            }
  DeclarationRequest declaration ->
    let generics = genericDocumentation extraction <$> declaration.genericParameters
        parameters = signatureParameter extraction <$> declaration.parameters
        returnType = buildTypeNode extraction declaration.returnType
        signature =
          "request "
            <> declaration.name
            <> renderGenericsClause generics
            <> renderParametersClause parameters
            <> " -> "
            <> returnType.rendered
     in Just
          (baseDeclaration DeclarationKindRequest declaration.name signature)
            { documentation = declaration.annotation,
              generics = generics,
              parameters = parameters,
              returnType = Just returnType,
              schema = wireSchema loweredModules moduleName declaration.name
            }
  DeclarationMarkerEffect declaration ->
    let generics = genericDocumentation extraction <$> declaration.genericParameters
        signature = "effect " <> declaration.name <> renderGenericsClause generics
     in Just
          (baseDeclaration DeclarationKindMarkerEffect declaration.name signature)
            { documentation = declaration.annotation,
              generics = generics
            }
  DeclarationExternalAgent declaration ->
    let generics = genericDocumentation extraction <$> declaration.genericParameters
        parameters = signatureParameter extraction <$> declaration.parameters
        returnType = buildTypeNode extraction declaration.returnType
        effects = buildTypeNode extraction <$> declaration.effects
        signature =
          "external agent "
            <> declaration.name
            <> renderGenericsClause generics
            <> renderParametersClause parameters
            <> " -> "
            <> returnType.rendered
            <> renderEffectsClause effects
            <> maybe "" (\reactorName -> " from " <> renderStringLiteralType reactorName) declaration.reactor
     in Just
          (baseDeclaration DeclarationKindExternalAgent declaration.name signature)
            { documentation = declaration.annotation,
              generics = generics,
              parameters = parameters,
              returnType = Just returnType,
              effects = effects,
              reactor = declaration.reactor,
              schema = wireSchema loweredModules moduleName declaration.name
            }
  DeclarationPrimitiveAgent declaration ->
    let generics = genericDocumentation extraction <$> declaration.genericParameters
        parameters = signatureParameter extraction <$> declaration.parameters
        returnType = buildTypeNode extraction declaration.returnType
        effects = buildTypeNode extraction <$> declaration.effects
        signature =
          "primitive agent "
            <> declaration.name
            <> renderGenericsClause generics
            <> renderParametersClause parameters
            <> " -> "
            <> returnType.rendered
            <> renderEffectsClause effects
     in Just
          (baseDeclaration DeclarationKindPrimitiveAgent declaration.name signature)
            { documentation = declaration.annotation,
              generics = generics,
              parameters = parameters,
              returnType = Just returnType,
              effects = effects,
              schema = wireSchema loweredModules moduleName declaration.name
            }
  DeclarationData declaration ->
    let generics = genericDocumentation extraction <$> declaration.genericParameters
        parameters = signatureParameter extraction <$> declaration.parameters
        signature =
          "data "
            <> declaration.name
            <> renderGenericsClause generics
            <> renderParametersClause parameters
     in Just
          (baseDeclaration DeclarationKindData declaration.name signature)
            { documentation = declaration.annotation,
              generics = generics,
              parameters = parameters,
              schema = wireSchema loweredModules moduleName declaration.name
            }
  DeclarationTypeSynonym declaration ->
    let generics = genericDocumentation extraction <$> declaration.genericParameters
        definition = buildTypeNode extraction declaration.definition
        signature =
          "type "
            <> declaration.name
            <> renderGenericsClause generics
            <> " = "
            <> definition.rendered
     in Just
          (baseDeclaration DeclarationKindTypeSynonym declaration.name signature)
            { generics = generics,
              definition = Just definition
            }
  DeclarationImport _ -> Nothing
  DeclarationError _ -> Nothing

-- | The all-empty declaration row every kind starts from, filling only the fields the contract
-- defines for it — so a field a kind never touches is uniformly @null@ rather than accidentally
-- populated.
baseDeclaration :: DeclarationKind -> Text -> Text -> DocsDeclaration
baseDeclaration kind name signature =
  DocsDeclaration
    { kind = kind,
      name = name,
      private = Nothing,
      documentation = Nothing,
      signature = signature,
      generics = [],
      parameters = [],
      returnType = Nothing,
      effects = Nothing,
      checkedType = Nothing,
      reactor = Nothing,
      definition = Nothing,
      schema = Nothing
    }

genericDocumentation :: DocsExtraction phase -> GenericParameter phase -> GenericDocumentation
genericDocumentation extraction parameter =
  GenericDocumentation
    { name = parameter.name,
      kind = parameter.kind,
      bindsLiteral = parameter.bindsLiteral,
      upperBound = buildTypeNode extraction <$> parameter.upperBound
    }

-- | An agent parameter (@label => pattern@ with sugar). A destructuring binder carries a pattern,
-- not a type, so only its label is documented — 'DocsDeclaration.checkedType' shows the parameter's
-- inferred type.
bindingParameter :: DocsExtraction phase -> ParameterBinding phase -> ParameterDocumentation
bindingParameter extraction binding = case binding.binder of
  BindVariable _ typeAnnotation defaultValue ->
    ParameterDocumentation
      { label = binding.name,
        documentation = binding.annotation,
        parameterType = buildTypeNode extraction <$> typeAnnotation,
        defaultValue = (.value) <$> defaultValue
      }
  BindDestructure _ ->
    ParameterDocumentation
      { label = binding.name,
        documentation = binding.annotation,
        parameterType = Nothing,
        defaultValue = Nothing
      }

-- | A typed parameter of a request / external / primitive / data declaration (type required).
signatureParameter :: DocsExtraction phase -> ParameterSignature phase -> ParameterDocumentation
signatureParameter extraction parameter =
  ParameterDocumentation
    { label = parameter.name,
      documentation = parameter.annotation,
      parameterType = Just (buildTypeNode extraction parameter.parameterType),
      defaultValue = (.value) <$> parameter.defaultValue
    }

---------------------------------------------------------------------------------------------------
-- Signature text (the copyable one-line surface form)
---------------------------------------------------------------------------------------------------

renderGenericsClause :: List GenericDocumentation -> Text
renderGenericsClause = \case
  [] -> ""
  generics -> "[" <> Text.intercalate ", " (renderGeneric <$> generics) <> "]"
  where
    renderGeneric generic =
      kindPrefix generic
        <> generic.name
        <> maybe "" (\bound -> " extends " <> bound.rendered) generic.upperBound
    kindPrefix generic = case (generic.kind, generic.bindsLiteral) of
      (GenericKindType, True) -> "literal "
      (GenericKindType, False) -> ""
      (GenericKindEffect, _) -> "effect "
      (GenericKindAttribute, _) -> "attribute "

renderParametersClause :: List ParameterDocumentation -> Text
renderParametersClause parameters = "(" <> Text.intercalate ", " (renderParameter <$> parameters) <> ")"
  where
    renderParameter parameter =
      parameter.label
        <> maybe "" (\parameterType -> ": " <> parameterType.rendered) parameter.parameterType
        <> maybe "" (\defaultValue -> " ?= " <> renderLiteralValue defaultValue) parameter.defaultValue

renderReturnClause :: Maybe TypeNode -> Text
renderReturnClause = maybe "" (\returnType -> " -> " <> returnType.rendered)

renderEffectsClause :: Maybe TypeNode -> Text
renderEffectsClause = maybe "" (\effects -> " with " <> effects.rendered)

---------------------------------------------------------------------------------------------------
-- Schema lookup (the wire view, straight from the lowered IR)
---------------------------------------------------------------------------------------------------

-- | The wire view of a declaration's callable: the 'SchemaInformation' its lowered 'BlockAgent'
-- wrapper carries, looked up by qualified name through the module's entries. Only value callables
-- are looked up (the caller skips type-only declarations, whose name lives in a different
-- namespace and could collide with an unrelated callable's entry).
wireSchema :: Map ModuleName IRModule -> ModuleName -> Text -> Maybe SchemaInformation
wireSchema loweredModules moduleName declarationName = do
  irModule <- Map.lookup moduleName loweredModules
  entry <- Map.lookup QualifiedName {moduleName = moduleName, name = declarationName} irModule.entries
  blockInformation <- Map.lookup entry.block irModule.blocks
  case blockInformation.block of
    BlockAgent agent -> closedSchema agent.schema
    _ -> Nothing

-- | Keep only a closed wire view. A callable with generic parameters has open @$generic@
-- placeholders (the reference shows its surface type instead — placeholders are never presented),
-- and the open fallback (@SchemaAny@ / @SchemaAny@) carries no information; both mean "no schema".
closedSchema :: SchemaInformation -> Maybe SchemaInformation
closedSchema schema = case (Map.null schema.genericBindings, schema.input, schema.output) of
  (True, SchemaAny, SchemaAny) -> Nothing
  (True, _, _) -> Just schema
  (False, _, _) -> Nothing

---------------------------------------------------------------------------------------------------
-- JSON encoding (the katariDocsVersion = 1 contract)
---------------------------------------------------------------------------------------------------

instance ToJSON DocsDocument where
  toJSON document =
    object
      [ "katariDocsVersion" .= katariDocsVersion,
        "compiler" .= document.compilerVersion,
        "package" .= object ["name" .= document.packageName, "version" .= document.packageVersion],
        "modules" .= document.modules
      ]

instance ToJSON DocsModule where
  toJSON docsModule = object ["name" .= docsModule.name, "declarations" .= docsModule.declarations]

instance ToJSON DeclarationKind where
  toJSON kind = toJSON (renderDeclarationKind kind)

renderDeclarationKind :: DeclarationKind -> Text
renderDeclarationKind = \case
  DeclarationKindAgent -> "agent"
  DeclarationKindExternalAgent -> "external_agent"
  DeclarationKindPrimitiveAgent -> "primitive_agent"
  DeclarationKindRequest -> "request"
  DeclarationKindMarkerEffect -> "marker_effect"
  DeclarationKindData -> "data"
  DeclarationKindTypeSynonym -> "type_synonym"

instance ToJSON DocsDeclaration where
  toJSON declaration =
    object
      ( [ "kind" .= declaration.kind,
          "name" .= declaration.name
        ]
          -- The private flag exists only on agent declarations, so other kinds omit the key
          -- entirely rather than emitting a meaningless null.
          <> ["private" .= isPrivate | Just isPrivate <- [declaration.private]]
          <> [ "documentation" .= declaration.documentation,
               "signature" .= declaration.signature,
               "generics" .= declaration.generics,
               "parameters" .= declaration.parameters,
               "returnType" .= declaration.returnType,
               "effects" .= declaration.effects,
               "checkedType" .= declaration.checkedType,
               "reactor" .= declaration.reactor,
               "definition" .= declaration.definition,
               "schema" .= declaration.schema
             ]
      )

instance ToJSON GenericDocumentation where
  toJSON generic =
    object
      [ "name" .= generic.name,
        "kind" .= renderGenericKind generic.kind,
        "bindsLiteral" .= generic.bindsLiteral,
        "upperBound" .= generic.upperBound
      ]

instance ToJSON ParameterDocumentation where
  toJSON parameter =
    object
      [ "label" .= parameter.label,
        "documentation" .= parameter.documentation,
        "type" .= parameter.parameterType,
        "default" .= (defaultDocumentationJSON <$> parameter.defaultValue)
      ]

-- | A parameter default carries both the JSON value and its rendered source form, so a @null@
-- default stays distinguishable from "no default" and the web never re-renders literals.
defaultDocumentationJSON :: LiteralValue -> Value
defaultDocumentationJSON value =
  object ["value" .= literalValueJSON value, "rendered" .= renderLiteralValue value]

literalValueJSON :: LiteralValue -> Value
literalValueJSON = \case
  LiteralValueInteger value -> toJSON value
  LiteralValueNumber value -> toJSON value
  LiteralValueString value -> toJSON value
  LiteralValueBoolean value -> toJSON value
  LiteralValueNull -> Aeson.Null

instance ToJSON TypeNode where
  toJSON typeNode =
    let (tag, fields) = detailEncoding typeNode.detail
     in object (("node" .= tag) : ("rendered" .= typeNode.rendered) : fields)

detailEncoding :: TypeNodeDetail -> (Text, List Pair)
detailEncoding = \case
  DetailPrimitive name -> ("primitive", ["name" .= name])
  DetailStringLiteral value -> ("string_literal", ["value" .= value])
  DetailNever -> ("never", [])
  DetailUnknown -> ("unknown", [])
  DetailAll -> ("all", [])
  DetailIo -> ("io", [])
  DetailPure -> ("pure", [])
  DetailArray -> ("array", [])
  DetailRecord -> ("record", [])
  DetailName nameDetail ->
    ( "name",
      [ "qualifier" .= nameDetail.qualifier,
        "name" .= nameDetail.name,
        "resolved" .= nameDetail.resolved
      ]
    )
  DetailAgent agentDetail ->
    ( "agent",
      [ "parameter" .= agentDetail.parameter,
        "return" .= agentDetail.returnType,
        "effects" .= agentDetail.effects
      ]
    )
  DetailApplication applicationDetail ->
    ( "application",
      [ "head" .= applicationDetail.applicationHead,
        "arguments" .= applicationDetail.applicationArguments
      ]
    )
  DetailTuple elements -> ("tuple", ["elements" .= elements])
  DetailUnion branches -> ("union", ["branches" .= branches])
  DetailObject fields -> ("object", ["fields" .= fields])
  DetailAttributed attributedDetail ->
    ("attributed", ["base" .= attributedDetail.base, "attribute" .= attributedDetail.attribute])
  DetailAttributeLiteral kind -> ("attribute_literal", ["kind" .= kind])
  DetailOverride overrideDetail ->
    ("override", ["base" .= overrideDetail.base, "overrides" .= overrideDetail.overrides])

instance ToJSON ObjectFieldDocumentation where
  toJSON field =
    object ["name" .= field.name, "optional" .= field.optional, "type" .= field.fieldType]

instance ToJSON ResolvedTypeReference where
  toJSON = \case
    ResolvedQualifiedName qualifiedName -> toJSON qualifiedName
    ResolvedGenericParameter name -> object ["generic" .= name]
