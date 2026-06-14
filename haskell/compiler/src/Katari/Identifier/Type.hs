-- | Resolving type-level syntax (types, effects, attributes): 'TypeName' references against the type
-- and module namespaces, and the generic parameters a declaration brings into scope.
--
-- A bare name resolves in the type namespace (K2001 if absent). A qualified @module.Name@ resolves
-- the qualifier in the module namespace (K2004 if the qualifier is a value/type rather than a
-- module, K2001 if undefined) and then the member against that module's interface (K2002 if absent).
module Katari.Identifier.Type where

import GHC.List (List)
import Katari.Data.AST
import Katari.Data.GenericKind (GenericKind (..))
import Katari.Data.Id (GenericId, TypeResolution (..))
import Katari.Data.SourceSpan (SourceSpan)
import Katari.Identifier.Monad

---------------------------------------------------------------------------------------------------
-- Types
---------------------------------------------------------------------------------------------------

resolveType :: SyntacticTypeExpression Parsed -> Identifier (SyntacticTypeExpression Identified)
resolveType = \case
  TypePrimitive node -> pure (TypePrimitive node)
  TypeNever sourceSpan -> pure (TypeNever sourceSpan)
  TypeUnknown sourceSpan -> pure (TypeUnknown sourceSpan)
  TypeAll sourceSpan -> pure (TypeAll sourceSpan)
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

resolveTypeNameNode :: TypeNameNode Parsed -> Identifier (TypeNameNode Identified)
resolveTypeNameNode node = case node.moduleQualifier of
  Nothing -> do
    typeReference <- resolveTypeReference node.sourceSpan node.name
    pure TypeNameNode {moduleQualifier = Nothing, name = node.name, typeReference = typeReference, sourceSpan = node.sourceSpan}
  Just qualifier -> do
    (identifiedQualifier, moduleResolution) <- resolveModuleQualifier qualifier
    -- The reference (and its K2002 diagnostic) point at the member name only — @node.typeReference@
    -- carries the member span, while @node.sourceSpan@ spans the whole @module.Name@.
    typeResolution <- case moduleResolution of
      Nothing -> pure Nothing
      Just moduleName -> resolveTypeMember node.typeReference.sourceSpan moduleName node.name
    pure
      TypeNameNode
        { moduleQualifier = Just identifiedQualifier,
          name = node.name,
          typeReference = identifiedReference node.typeReference.sourceSpan typeResolution,
          sourceSpan = node.sourceSpan
        }

---------------------------------------------------------------------------------------------------
-- Generic parameters
---------------------------------------------------------------------------------------------------

-- | Bind a declaration's generic parameters (fresh ids, by kind) over @region@ (the declaration's
-- span — generics scope over its whole signature and body), resolve their bounds within that scope
-- (so a bound may mention a sibling generic), and run the continuation with the identified parameters
-- still in scope.
withGenericParameters :: SourceSpan -> List (GenericParameter Parsed) -> (List (GenericParameter Identified) -> Identifier a) -> Identifier a
withGenericParameters region parameters continuation = do
  prepared <- traverse prepareGenericParameter parameters
  bindInScope region [typeBinding parameter.name parameter.typeReference.sourceSpan resolution | (parameter, resolution) <- prepared] $ do
    identifiedParameters <- traverse resolvePreparedGenericParameter prepared
    continuation identifiedParameters

-- | Assign a fresh id to a generic parameter and derive the resolution its name will carry (its
-- kind decides which generic resolution).
prepareGenericParameter :: GenericParameter Parsed -> Identifier (GenericParameter Parsed, TypeResolution)
prepareGenericParameter parameter = do
  genericId <- freshGenericId
  pure (parameter, genericResolution parameter.kind genericId)

genericResolution :: GenericKind -> GenericId -> TypeResolution
genericResolution kind genericId = case kind of
  GenericKindType -> TypeResolutionGenericType genericId
  GenericKindEffect -> TypeResolutionGenericEffect genericId
  GenericKindAttribute -> TypeResolutionGenericAttribute genericId

resolvePreparedGenericParameter :: (GenericParameter Parsed, TypeResolution) -> Identifier (GenericParameter Identified)
resolvePreparedGenericParameter (parameter, resolution) = do
  upperBound <- traverse resolveType parameter.upperBound
  pure
    GenericParameter
      { name = parameter.name,
        labelReference = retagReference parameter.labelReference,
        typeReference = identifiedReference parameter.typeReference.sourceSpan (Just resolution),
        kind = parameter.kind,
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
