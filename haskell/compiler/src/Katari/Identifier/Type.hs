-- | Resolving type-level syntax (types, effects, attributes): 'TypeName' references against the type
-- and module namespaces, and the generic parameters a declaration brings into scope.
--
-- A bare name resolves in the type namespace (K2001 if absent). A qualified @module.Name@ resolves
-- the qualifier in the module namespace (K2004 if the qualifier is a value/type rather than a
-- module, K2001 if undefined) and then the member against that module's interface (K2002 if absent).
module Katari.Identifier.Type where

import GHC.List (List)
import Katari.Data.AST
import Katari.Data.Id (TypeResolution (..))
import Katari.Data.SourceSpan (SourceSpan)
import Katari.Identifier.Monad

---------------------------------------------------------------------------------------------------
-- Types
---------------------------------------------------------------------------------------------------

resolveType :: SyntacticTypeExpression Parsed -> Identifier (SyntacticTypeExpression Identified)
resolveType = \case
  TypePrimitive node -> pure (TypePrimitive node)
  TypeStringLiteral node -> pure (TypeStringLiteral node)
  TypeNever sourceSpan -> pure (TypeNever sourceSpan)
  TypeUnknown sourceSpan -> pure (TypeUnknown sourceSpan)
  TypeAll sourceSpan -> pure (TypeAll sourceSpan)
  TypeIo sourceSpan -> pure (TypeIo sourceSpan)
  TypePure sourceSpan -> pure (TypePure sourceSpan)
  TypeArray sourceSpan -> pure (TypeArray sourceSpan)
  TypeRecord sourceSpan -> pure (TypeRecord sourceSpan)
  TypeAttributeLiteral node -> pure (TypeAttributeLiteral node)
  TypeName node -> TypeName <$> resolveTypeNameNode node
  TypeAgent node -> do
    parameterType <- resolveType node.parameterType
    returnType <- resolveType node.returnType
    effects <- traverse resolveType node.effects
    pure (TypeAgent AgentTypeNode {parameterType = parameterType, returnType = returnType, effects = effects, sourceSpan = node.sourceSpan})
  TypeApplication node -> do
    applicationHead <- resolveType node.applicationHead
    applicationArguments <- traverse resolveType node.applicationArguments
    pure (TypeApplication TypeApplicationTypeNode {applicationHead = applicationHead, applicationArguments = applicationArguments, sourceSpan = node.sourceSpan})
  TypeTuple node -> do
    elementTypes <- traverse resolveType node.elementTypes
    pure (TypeTuple TupleTypeNode {elementTypes = elementTypes, sourceSpan = node.sourceSpan})
  TypeUnion node -> do
    branches <- traverse resolveType node.branches
    pure (TypeUnion TypeUnionNode {branches = branches, sourceSpan = node.sourceSpan})
  TypeObject node -> do
    reportDuplicateLabels [(field.name, field.sourceSpan) | field <- node.fields]
    fields <- traverse resolveObjectTypeField node.fields
    pure (TypeObject ObjectTypeNode {fields = fields, sourceSpan = node.sourceSpan})
  TypeAttributed node -> do
    baseType <- resolveType node.baseType
    attribute <- resolveType node.attribute
    pure (TypeAttributed AttributedTypeNode {baseType = baseType, attribute = attribute, sourceSpan = node.sourceSpan})
  TypeOverride node -> do
    base <- resolveType node.base
    overrides <- traverse resolveType node.overrides
    pure (TypeOverride OverrideTypeNode {base = base, overrides = overrides, sourceSpan = node.sourceSpan})

resolveObjectTypeField :: ObjectTypeField Parsed -> Identifier (ObjectTypeField Identified)
resolveObjectTypeField field = do
  fieldType <- resolveType field.fieldType
  pure ObjectTypeField {name = field.name, fieldType = fieldType, optional = field.optional, sourceSpan = field.sourceSpan}

---------------------------------------------------------------------------------------------------
-- Type names
---------------------------------------------------------------------------------------------------

-- | The reference (and its K2002 diagnostic) point at the member name only — @node.typeReference@
-- carries the member span when qualified, while @node.sourceSpan@ spans the whole @module.Name@.
resolveTypeNameNode :: TypeNameNode Parsed -> Identifier (TypeNameNode Identified)
resolveTypeNameNode node = do
  (moduleQualifier, typeReference) <- resolveQualifiedReference resolveTypeReference resolveTypeMember node.moduleQualifier node.name node.typeReference
  pure TypeNameNode {moduleQualifier = moduleQualifier, name = node.name, typeReference = typeReference, sourceSpan = node.sourceSpan}

---------------------------------------------------------------------------------------------------
-- Generic parameters
---------------------------------------------------------------------------------------------------

-- | Bind a declaration's generic parameters (fresh ids, by kind) over @region@ (the declaration's
-- span — generics scope over its whole signature and body) and run the continuation with them in
-- scope. Duplicate parameter names are rejected (K2003).
--
-- Each parameter's @extends@ bound resolves against the outer scope and the /preceding/ siblings, but
-- never its own id: @a extends a@ therefore refers to an outer @a@ (or is undefined), never to itself,
-- which keeps the bound relation acyclic — while @[a extends b, c extends a]@ still lets @c@'s bound
-- mention the earlier @a@.
withGenericParameters :: SourceSpan -> List (GenericParameter Parsed) -> (List (GenericParameter Identified) -> Identifier a) -> Identifier a
withGenericParameters region parameters continuation = do
  reportDuplicateLabels [(parameter.name, parameter.sourceSpan) | parameter <- parameters]
  prepared <- traverse prepareGenericParameter parameters
  identifiedParameters <- resolveBounds [] prepared
  bindInScope region (genericBinding <$> prepared) (continuation identifiedParameters)
  where
    resolveBounds _ [] = pure []
    resolveBounds preceding (current : rest) = do
      identified <- withResolutionScope preceding (resolvePreparedGenericParameter current)
      (identified :) <$> resolveBounds (preceding <> [genericBinding current]) rest
    genericBinding (parameter, resolution) = typeBinding parameter.name parameter.typeReference.sourceSpan resolution

-- | Assign a fresh id to a generic parameter; its name resolves to that id. The parameter's kind
-- (type / effect / attribute) does not affect the resolution — it travels on the 'GenericParameter'
-- node's @kind@ field and is consulted later, so every kind resolves through 'TypeResolutionGeneric'.
prepareGenericParameter :: GenericParameter Parsed -> Identifier (GenericParameter Parsed, TypeResolution)
prepareGenericParameter parameter = do
  genericId <- freshGenericId
  pure (parameter, TypeResolutionGeneric genericId)

resolvePreparedGenericParameter :: (GenericParameter Parsed, TypeResolution) -> Identifier (GenericParameter Identified)
resolvePreparedGenericParameter (parameter, resolution) = do
  upperBound <- traverse resolveType parameter.upperBound
  pure
    GenericParameter
      { name = parameter.name,
        labelReference = retagReference parameter.labelReference,
        typeReference = identifiedReference parameter.typeReference.sourceSpan (Just resolution),
        kind = parameter.kind,
        bindsLiteral = parameter.bindsLiteral,
        upperBound = upperBound,
        sourceSpan = parameter.sourceSpan
      }

---------------------------------------------------------------------------------------------------
-- Parameter signatures (request / external / primitive / data)
---------------------------------------------------------------------------------------------------

resolveParameterSignature :: ParameterSignature Parsed -> Identifier (ParameterSignature Identified)
resolveParameterSignature signature = do
  parameterType <- resolveType signature.parameterType
  pure
    ParameterSignature
      { annotation = signature.annotation,
        name = signature.name,
        labelReference = retagReference signature.labelReference,
        parameterType = parameterType,
        defaultValue = signature.defaultValue,
        sourceSpan = signature.sourceSpan
      }
