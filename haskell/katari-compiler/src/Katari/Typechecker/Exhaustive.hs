-- | Exhaustiveness and reachability checking for Katari match expressions
-- and irrefutable binding contexts.
--
-- Implements Maranget's "Warnings for pattern matching" (JFP 2007) as a
-- post-Zonker pass. The entry point 'checkExhaustive' walks 'ZonkResult'
-- and returns:
--
--   * 'ExhaustiveErrorNonExhaustiveMatch'   (K0290) — a @match@ is missing
--     at least one case.
--   * 'ExhaustiveErrorNonExhaustiveBinding' (K0291) — a @let@ / parameter /
--     @for@-binding pattern is refutable (could fail at run time).
--   * 'ExhaustiveErrorUnreachableArm'       (K0292) — a match arm is
--     unreachable because earlier arms already cover it.
module Katari.Typechecker.Exhaustive
  ( -- * Errors
    ExhaustiveError (..),

    -- * Diagnostics
    toDiagnostic,

    -- * Entry
    checkExhaustive,
  )
where

import Data.List (nubBy, sortBy)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, mapMaybe)
import Data.Ord (comparing)
import Data.Text (Text)
import Data.Text qualified as Text
import Katari.AST (NameRef (..), Zonked)
import Katari.AST qualified as AST
import Katari.Common (LiteralValue (..), TypePatternTag (..))
import Katari.Diagnostic (Diagnostic, diagnosticError, diagnosticWarning)
import Katari.Id
  ( QualifiedName (..),
    VariableResolution (..),
  )
import Katari.SemanticType
  ( Resolved,
    SemanticType (..),
  )
import Katari.SourceSpan (HasSourceSpan (..), SourceSpan)
import Katari.Typechecker.Identifier
  ( ConstructorData (..),
    IdentifierResult (..),
  )
import Katari.Typechecker.Zonker (ZonkResult (..))

-- ===========================================================================
-- Error type
-- ===========================================================================

data ExhaustiveError where
  -- | A @match@ expression is missing coverage for at least one value.
  -- The 'SourceSpan' points to the @match@ keyword. K0290.
  ExhaustiveErrorNonExhaustiveMatch :: SourceSpan -> [Text] -> ExhaustiveError
  -- | A binding pattern is refutable (let / param / for / then). K0291.
  ExhaustiveErrorNonExhaustiveBinding :: SourceSpan -> [Text] -> ExhaustiveError
  -- | A match arm can never be reached. K0292.
  ExhaustiveErrorUnreachableArm :: SourceSpan -> ExhaustiveError

deriving instance Show ExhaustiveError

-- ===========================================================================
-- Diagnostic conversion
-- ===========================================================================

-- | Map an 'ExhaustiveError' to a 'Diagnostic'.
toDiagnostic :: ExhaustiveError -> Diagnostic
toDiagnostic = \case
  ExhaustiveErrorNonExhaustiveMatch sourceSpan witnesses ->
    diagnosticError
      "K0290"
      ("non-exhaustive match: missing case " <> renderWitnesses witnesses)
      sourceSpan
  ExhaustiveErrorNonExhaustiveBinding sourceSpan witnesses ->
    diagnosticError
      "K0291"
      ( "irrefutable pattern required here, but value could match "
          <> renderWitnesses witnesses
      )
      sourceSpan
  ExhaustiveErrorUnreachableArm sourceSpan ->
    diagnosticWarning
      "K0292"
      "unreachable match arm: no value matches this pattern (prior arms already cover it, or its head is incompatible with the subject's type)"
      sourceSpan

-- ===========================================================================
-- Pattern representation (Maranget §2)
-- ===========================================================================

-- | Head constructor tag.
data CtorTag where
  CtorTagData :: QualifiedName -> CtorTag
  CtorTagLitInt :: Integer -> CtorTag
  CtorTagLitNum :: Double -> CtorTag
  CtorTagLitStr :: Text -> CtorTag
  CtorTagLitBool :: Bool -> CtorTag
  CtorTagNull :: CtorTag
  CtorTagTupleN :: Int -> CtorTag
  -- | Runtime type-guard pattern (@integer(p)@, @record(p)@, etc.). Arity
  -- is 1 (the inner pattern). The signature is never complete on its own;
  -- a wildcard arm is required for exhaustiveness.
  CtorTagType :: TypePatternTag -> CtorTag
  -- | Record pattern: the keys are stored sorted so two patterns over the
  -- same key set collapse to the same tag (and one becomes redundant w.r.t.
  -- the other). Arity equals the number of keys; sub-patterns appear in
  -- key-sorted order. Never forms a complete signature.
  CtorTagRecordKeys :: [Text] -> CtorTag
  deriving (Eq, Ord, Show)

-- | Simplified pattern head. Variables and wildcards become 'PatHeadWildcard'.
data PatHead where
  PatHeadWildcard :: PatHead
  PatHeadCtor :: CtorTag -> [PatHead] -> PatHead
  deriving (Eq, Show)

-- | A row of the pattern matrix.
data PatRow = PatRow
  { patRowPats :: [PatHead],
    patRowSpan :: SourceSpan
  }
  deriving (Show)

-- | Pattern matrix (list of rows, all the same width).
newtype PatMatrix = PatMatrix [PatRow]
  deriving (Show)

-- ===========================================================================
-- Algorithm context
-- ===========================================================================

-- | Threading context for the algorithm. Carries the subject column type
-- for each column (left-to-right), the 'IdentifierResult' for constructor
-- lookups, and the 'ZonkResult' for type-environment lookups.
data TypeCtx = TypeCtx
  { columnTypes :: [SemanticType Resolved],
    identifierResult :: IdentifierResult,
    zonkResult :: ZonkResult
  }

headColumnType :: TypeCtx -> SemanticType Resolved
headColumnType context = case context.columnTypes of
  (t : _) -> t
  [] -> SemanticTypeUnknown

-- ===========================================================================
-- Maranget algorithm (§3.1 of Maranget 2007)
-- ===========================================================================

-- | @useful context P q@ — returns 'True' if row vector @q@ is useful w.r.t.
-- pattern matrix @P@, i.e. if there exists a value matched by @q@ but not
-- by any row of @P@.
useful :: TypeCtx -> PatMatrix -> [PatHead] -> Bool
useful context matrix@(PatMatrix rows) testRow = case (rows, testRow) of
  -- Base: empty query — useful only if matrix is empty (vacuous).
  (_, []) -> null rows
  -- If the head of the query is a 'Ctor' tag structurally incompatible
  -- with the column's subject type (e.g. a string-literal pattern against
  -- an integer subject), the query matches no value — vacuously not
  -- useful. Checked before the empty-matrix base case so a disjoint head
  -- on the first arm is still flagged as unreachable.
  (_, PatHeadCtor tag _ : _)
    | not (tagCompatibleWithType tag (headColumnType context) context.identifierResult context.zonkResult) ->
        False
  -- Base: empty matrix — any (type-compatible) query is useful (nothing is
  -- covered yet).
  ([], _) -> True
  -- Recursive: dispatch on head of query.
  (_, PatHeadWildcard : restPats) ->
    let columnType = headColumnType context
        sigma = headsOf matrix
     in if isCompleteSig (map fst sigma) columnType context.identifierResult context.zonkResult
          then -- complete signature: recurse on each specialisation

            any
              ( \(tag, arity) ->
                  let freshWilds = replicate arity PatHeadWildcard
                      newCtx = specializeCtx tag columnType context
                   in useful newCtx (specialize tag arity matrix) (freshWilds ++ restPats)
              )
              sigma
          else -- incomplete: fall through to default matrix
            useful (defaultCtx context) (defaultMatrix matrix) restPats
  (_, PatHeadCtor tag subPats : restPats) ->
    let arity = length subPats
        columnType = headColumnType context
        newCtx = specializeCtx tag columnType context
     in useful newCtx (specialize tag arity matrix) (subPats ++ restPats)

-- | Collect distinct constructor tags from the first column of the matrix
-- (wildcards are not constructors). Returns @(tag, arity)@ pairs.
headsOf :: PatMatrix -> [(CtorTag, Int)]
headsOf (PatMatrix rows) =
  nubBy
    (\a b -> fst a == fst b)
    [(tag, length subs) | PatRow (PatHeadCtor tag subs : _) _ <- rows]

-- | Specialise the matrix for constructor @tag@ with @arity@ fields.
-- Rows whose first column is @tag@ are expanded; wildcard-head rows gain
-- @arity@ fresh wildcard columns; other ctor-head rows are dropped.
specialize :: CtorTag -> Int -> PatMatrix -> PatMatrix
specialize tag arity (PatMatrix rows) =
  PatMatrix (mapMaybe (specializeRow tag arity) rows)

specializeRow :: CtorTag -> Int -> PatRow -> Maybe PatRow
specializeRow tag arity PatRow {patRowPats, patRowSpan} =
  case patRowPats of
    [] -> Nothing
    (head_ : rest) -> case head_ of
      PatHeadCtor headTag subPats
        | headTag == tag ->
            Just (PatRow (subPats <> rest) patRowSpan)
        | otherwise -> Nothing
      PatHeadWildcard ->
        Just (PatRow (replicate arity PatHeadWildcard <> rest) patRowSpan)

-- | Default matrix: keep rows whose first column is a wildcard, then drop
-- that column.
defaultMatrix :: PatMatrix -> PatMatrix
defaultMatrix (PatMatrix rows) =
  PatMatrix (mapMaybe defaultRow rows)

defaultRow :: PatRow -> Maybe PatRow
defaultRow PatRow {patRowPats, patRowSpan} =
  case patRowPats of
    [] -> Nothing
    (PatHeadWildcard : rest) -> Just (PatRow rest patRowSpan)
    (PatHeadCtor {} : _) -> Nothing

-- | Update the column-type context when specialising on @tag@.
-- The head column is replaced by the field types of @tag@.
specializeCtx :: CtorTag -> SemanticType Resolved -> TypeCtx -> TypeCtx
specializeCtx tag columnType context =
  let subFieldTypes = getSubFieldTypes tag columnType context.identifierResult context.zonkResult
      remaining = drop 1 context.columnTypes
   in context {columnTypes = subFieldTypes ++ remaining}

-- | Drop the first column type (for defaultMatrix).
defaultCtx :: TypeCtx -> TypeCtx
defaultCtx context = context {columnTypes = drop 1 context.columnTypes}

-- | Field types for a constructor, in alphabetical label order. Returns []
-- for literal / null tags (arity 0) and tuples (handled separately).
getSubFieldTypes :: CtorTag -> SemanticType Resolved -> IdentifierResult -> ZonkResult -> [SemanticType Resolved]
getSubFieldTypes tag columnType idResult zonkResult = case tag of
  CtorTagData qualifiedName ->
    case Map.lookup (ResolvedTopLevel qualifiedName) zonkResult.zonkedTypeEnvironment of
      Just (SemanticTypeFunction parameters _ _) ->
        map snd (Map.toAscList parameters)
      _ -> []
  CtorTagTupleN _ -> case columnType of
    SemanticTypeTuple tupleTypes -> tupleTypes
    _ -> []
  CtorTagType narrowTag -> [typePatternTagToResolved narrowTag]
  CtorTagRecordKeys keys ->
    let valueType = case columnType of
          SemanticTypeRecord v -> v
          _ -> SemanticTypeUnknown
     in replicate (length keys) valueType
  _ -> []

-- | The narrowed semantic type associated with a runtime type-guard tag.
-- Mirrors 'typePatternTagToSemantic' but at the 'Resolved' phase.
typePatternTagToResolved :: TypePatternTag -> SemanticType Resolved
typePatternTagToResolved = \case
  TypePatternTagInteger -> SemanticTypeInteger
  TypePatternTagNumber -> SemanticTypeNumber
  TypePatternTagString -> SemanticTypeString
  TypePatternTagBoolean -> SemanticTypeBoolean
  TypePatternTagAgent -> SemanticTypeFunctionAny

-- ===========================================================================
-- Complete-signature check
-- ===========================================================================

-- | @isCompleteSig seen ty idResult zonkResult@ — returns 'True' if @seen@
-- (the set of ctor tags appearing in the first column of the pattern
-- matrix) constitutes a complete signature for @ty@.
-- | @tagCompatibleWithType tag ty ...@ — does the constructor tag denote
-- at least one value of @ty@? Returns 'False' when the tag is structurally
-- disjoint from the type (e.g. a string-literal tag against an integer
-- column). Used by 'useful' to detect arms whose pattern can never match
-- the subject. The check is conservative: unknown / variable / never
-- column types return 'True' (= don't flag) so we don't over-warn while
-- inference is incomplete.
tagCompatibleWithType ::
  CtorTag ->
  SemanticType Resolved ->
  IdentifierResult ->
  ZonkResult ->
  Bool
tagCompatibleWithType tag ty idResult zonkResult = case ty of
  SemanticTypeUnknown -> True
  SemanticTypeNever -> True
  SemanticTypeUnion branches ->
    any (\branch -> tagCompatibleWithType tag branch idResult zonkResult) branches
  _ -> case tag of
    CtorTagLitInt n -> case ty of
      SemanticTypeInteger -> True
      SemanticTypeNumber -> True
      SemanticTypeLiteralInteger m -> m == n
      _ -> False
    CtorTagLitNum d -> case ty of
      SemanticTypeNumber -> True
      SemanticTypeLiteralInteger m -> fromInteger m == d
      _ -> False
    CtorTagLitStr s -> case ty of
      SemanticTypeString -> True
      SemanticTypeLiteralString t -> t == s
      _ -> False
    CtorTagLitBool b -> case ty of
      SemanticTypeBoolean -> True
      SemanticTypeLiteralBoolean b' -> b == b'
      _ -> False
    CtorTagNull -> case ty of
      SemanticTypeNull -> True
      _ -> False
    CtorTagTupleN n -> case ty of
      SemanticTypeTuple es -> length es == n
      _ -> False
    CtorTagData qualifiedName -> case ty of
      SemanticTypeData tid ->
        case Map.lookup qualifiedName idResult.identifiedConstructors of
          Just cd -> cd.constructorTypeQName == tid
          Nothing -> False
      _ -> False
    -- Runtime type-guard patterns are always compatible: the guard runs
    -- at runtime against any value, narrowing from whatever the static
    -- type is. We don't try to detect "guard against a type that's
    -- statically impossible" — that's a separate (and tricky) check.
    CtorTagType _ -> True
    CtorTagRecordKeys _ -> True

isCompleteSig :: [CtorTag] -> SemanticType Resolved -> IdentifierResult -> ZonkResult -> Bool
isCompleteSig seen ty idResult zonkResult = case ty of
  SemanticTypeBoolean ->
    CtorTagLitBool True `elem` seen && CtorTagLitBool False `elem` seen
  SemanticTypeNull ->
    CtorTagNull `elem` seen
  SemanticTypeLiteralBoolean b ->
    CtorTagLitBool b `elem` seen
  SemanticTypeLiteralInteger n ->
    CtorTagLitInt n `elem` seen
  SemanticTypeLiteralString s ->
    CtorTagLitStr s `elem` seen
  SemanticTypeTuple tupleTypes ->
    CtorTagTupleN (length tupleTypes) `elem` seen
  SemanticTypeData tid ->
    let ctorQNames = [qualifiedName | (qualifiedName, _) <- ctorsOfType idResult zonkResult tid]
        seenQNames = [qualifiedName | CtorTagData qualifiedName <- seen]
     in null ctorQNames
          || all (`elem` seenQNames) ctorQNames
  SemanticTypeUnion branches ->
    -- Complete iff every branch is completely covered.
    not (null branches)
      && all (\branch -> isCompleteSig seen branch idResult zonkResult) branches
  SemanticTypeNever ->
    True -- no values; vacuously exhaustive
  _ ->
    False -- Integer, Number, String, Array, Object, Unknown: infinite domain

-- ===========================================================================
-- Constructor enumeration helpers
-- ===========================================================================

ctorsOfType :: IdentifierResult -> ZonkResult -> QualifiedName -> [(QualifiedName, Int)]
ctorsOfType idResult zonkResult typeQName =
  [ (qualifiedName, lookupCtorArity zonkResult qualifiedName)
    | (qualifiedName, cd) <- Map.toList idResult.identifiedConstructors,
      cd.constructorTypeQName == typeQName
  ]

-- | Arity of a constructor from its function-type signature.
lookupCtorArity :: ZonkResult -> QualifiedName -> Int
lookupCtorArity zonkResult qualifiedName =
  case Map.lookup (ResolvedTopLevel qualifiedName) zonkResult.zonkedTypeEnvironment of
    Just (SemanticTypeFunction parameters _ _) -> Map.size parameters
    _ -> 0

-- ===========================================================================
-- Pattern-to-head conversion
-- ===========================================================================

-- | Convert an AST 'AST.Pattern Zonked' to a 'PatHead'. Field patterns for
-- data constructors are sorted alphabetically by label to ensure consistent
-- column ordering across all rows.
patternToHead :: IdentifierResult -> AST.Pattern Zonked -> PatHead
patternToHead idResult = \case
  AST.PatternVariable _ -> PatHeadWildcard
  AST.PatternWildcard _ -> PatHeadWildcard
  AST.PatternLiteral lp -> PatHeadCtor (literalTag lp.value) []
  AST.PatternTuple tp ->
    PatHeadCtor (CtorTagTupleN (length tp.elements)) (map (patternToHead idResult) tp.elements)
  AST.PatternQualifiedConstructor qp ->
    case qp.constructorName.resolution of
      Nothing ->
        -- Unresolved ctor: treat as wildcard (Identifier error already emitted)
        PatHeadWildcard
      Just qualifiedName ->
        case Map.lookup qualifiedName idResult.identifiedConstructors of
          Nothing -> PatHeadWildcard
          Just _cd ->
            let sortedSubs =
                  map (patternToHead idResult . snd) $
                    sortBy (comparing ((.text) . fst)) qp.parameters
             in PatHeadCtor (CtorTagData qualifiedName) sortedSubs
  AST.PatternType tp ->
    PatHeadCtor (CtorTagType tp.typeTag) [patternToHead idResult tp.inner]
  AST.PatternRecord rp ->
    let sortedEntries = sortBy (comparing fst) rp.entries
        sortedKeys = map fst sortedEntries
        sortedSubs = map (patternToHead idResult . snd) sortedEntries
     in PatHeadCtor (CtorTagRecordKeys sortedKeys) sortedSubs

literalTag :: LiteralValue -> CtorTag
literalTag = \case
  LiteralValueInteger n -> CtorTagLitInt n
  LiteralValueString s -> CtorTagLitStr s
  LiteralValueBoolean b -> CtorTagLitBool b
  LiteralValueNull -> CtorTagNull
  LiteralValueNumber d -> CtorTagLitNum d
  -- 'LiteralValueAgent' is an IR-only literal produced by Lowering; the
  -- AST exhaustiveness checker should never encounter one. Fall back to
  -- 'Null' rather than crashing — the surrounding match is already
  -- ill-typed and will emit a diagnostic via the regular path.
  LiteralValueAgent _ -> CtorTagNull

-- | Extract the semantic type from any 'AST.Expression Zonked'.
getExpressionType :: AST.Expression Zonked -> SemanticType Resolved
getExpressionType = \case
  AST.ExpressionLiteral e -> e.typeOf
  AST.ExpressionVariable e -> e.typeOf
  AST.ExpressionTuple e -> e.typeOf
  AST.ExpressionArray e -> e.typeOf
  AST.ExpressionRecord e -> e.typeOf
  AST.ExpressionCall e -> e.typeOf
  AST.ExpressionBinaryOperator e -> e.typeOf
  AST.ExpressionUnaryOperator e -> e.typeOf
  AST.ExpressionIf e -> e.typeOf
  AST.ExpressionMatch e -> e.typeOf
  AST.ExpressionFor e -> e.typeOf
  AST.ExpressionBlock e -> e.typeOf
  AST.ExpressionFieldAccess e -> e.typeOf
  AST.ExpressionIndexAccess e -> e.typeOf
  AST.ExpressionTemplate e -> e.typeOf
  AST.ExpressionHandle e -> e.typeOf
  AST.ExpressionParTuple e -> e.typeOf
  AST.ExpressionParArray e -> e.typeOf
  AST.ExpressionQualifiedReference e -> e.typeOf

-- ===========================================================================
-- Witness rendering (simplified; steps 3-8)
-- ===========================================================================

renderWitnesses :: [Text] -> Text
renderWitnesses [] = "(unknown)"
renderWitnesses witnesses = "`" <> Text.intercalate " | " witnesses <> "`"

-- | Build a minimal human-readable counter-example from a 'PatHead'. Used
-- for K0290 / K0291 diagnostic messages.
renderPatHead :: IdentifierResult -> ZonkResult -> PatHead -> Text
renderPatHead idResult zonkResult = \case
  PatHeadWildcard -> "_"
  PatHeadCtor (CtorTagLitBool b) _ -> if b then "true" else "false"
  PatHeadCtor CtorTagNull _ -> "null"
  PatHeadCtor (CtorTagLitInt n) _ -> Text.pack (show n)
  PatHeadCtor (CtorTagLitNum d) _ -> Text.pack (show d)
  PatHeadCtor (CtorTagLitStr s) _ -> "\"" <> s <> "\""
  PatHeadCtor (CtorTagTupleN n) subs ->
    "("
      <> Text.intercalate ", " (map (renderPatHead idResult zonkResult) subs)
      <> ")"
      <> if null subs then Text.pack (" {tuple/" <> show n <> "}") else ""
  PatHeadCtor (CtorTagData qualifiedName) subs ->
    let ctorName = qualifiedName.name
     in if null subs
          then ctorName <> "()"
          else ctorName <> "(" <> Text.intercalate ", " (map (renderPatHead idResult zonkResult) subs) <> ")"
  PatHeadCtor (CtorTagType tag) subs ->
    typePatternTagName tag
      <> "("
      <> Text.intercalate ", " (map (renderPatHead idResult zonkResult) subs)
      <> ")"
  PatHeadCtor (CtorTagRecordKeys keys) subs ->
    let renderedSubs = map (renderPatHead idResult zonkResult) subs
        zipped =
          if length keys == length renderedSubs
            then zipWith (\k v -> k <> " = " <> v) keys renderedSubs
            else renderedSubs -- defensive — shouldn't happen
     in "{ " <> Text.intercalate ", " zipped <> " }"

typePatternTagName :: TypePatternTag -> Text
typePatternTagName = \case
  TypePatternTagInteger -> "integer"
  TypePatternTagNumber -> "number"
  TypePatternTagString -> "string"
  TypePatternTagBoolean -> "boolean"
  TypePatternTagAgent -> "agent"

-- ===========================================================================
-- Match checking
-- ===========================================================================

checkMatch :: IdentifierResult -> ZonkResult -> AST.MatchExpression Zonked -> [ExhaustiveError]
checkMatch idResult zonkResult me =
  let subjectType = getExpressionType me.subject
      context = TypeCtx {columnTypes = [subjectType], identifierResult = idResult, zonkResult = zonkResult}
      arms = me.cases
      armHeads = map (\arm -> patternToHead idResult arm.pattern) arms
      armRows = [PatRow [h] arm.sourceSpan | (arm, h) <- zip arms armHeads]
      matrix = PatMatrix armRows
      -- Non-exhaustiveness: is there a value not covered by any arm?
      nonExhaustiveErrors =
        if useful context matrix [PatHeadWildcard]
          then
            let witness = renderPatHead idResult zonkResult PatHeadWildcard
             in [ExhaustiveErrorNonExhaustiveMatch me.sourceSpan [witness]]
          else []
      -- Reachability: is arm i already covered by prior arms?
      unreachableErrors =
        catMaybes
          [ if not (useful context (PatMatrix (take idx armRows)) [armHead])
              then Just (ExhaustiveErrorUnreachableArm arm.sourceSpan)
              else Nothing
            | (idx, arm, armHead) <- zip3 [0 ..] arms armHeads
          ]
   in nonExhaustiveErrors ++ unreachableErrors

-- | Check that @pattern@ is irrefutable (covers all values of @subjectType@).
-- Returns a K0291 error if not.
checkIrrefutable ::
  IdentifierResult ->
  ZonkResult ->
  AST.Pattern Zonked ->
  SemanticType Resolved ->
  [ExhaustiveError]
checkIrrefutable idResult zonkResult pattern subjectType =
  let headPat = patternToHead idResult pattern
      context = TypeCtx {columnTypes = [subjectType], identifierResult = idResult, zonkResult = zonkResult}
      sourceSpan = sourceSpanOf pattern
      row = PatRow [headPat] sourceSpan
   in if useful context (PatMatrix [row]) [PatHeadWildcard]
        then
          let witness = renderPatHead idResult zonkResult PatHeadWildcard
           in [ExhaustiveErrorNonExhaustiveBinding sourceSpan [witness]]
        else []

-- ===========================================================================
-- AST walker
-- ===========================================================================

-- | Entry point: walk all Zonked modules and collect exhaustiveness errors.
checkExhaustive :: IdentifierResult -> ZonkResult -> [ExhaustiveError]
checkExhaustive idResult zonkResult =
  concatMap (walkModule idResult zonkResult) (Map.elems zonkResult.zonkedModules)

walkModule :: IdentifierResult -> ZonkResult -> AST.Module Zonked -> [ExhaustiveError]
walkModule idResult zonkResult m = concatMap (walkDeclaration idResult zonkResult) m.declarations

walkDeclaration :: IdentifierResult -> ZonkResult -> AST.Declaration Zonked -> [ExhaustiveError]
walkDeclaration idResult zonkResult = \case
  AST.DeclarationAgent decl ->
    walkAgentBody idResult zonkResult decl.name.resolution decl.parameters decl.body
  AST.DeclarationRequest _ -> []
  AST.DeclarationExternalAgent _ -> []
  AST.DeclarationPrimAgent _ -> []
  AST.DeclarationData _ -> []
  AST.DeclarationTypeSynonym _ -> []
  AST.DeclarationImport _ -> []
  AST.DeclarationError _ -> []

-- | Walk an agent body: check parameter irrefutability + walk the block.
walkAgentBody ::
  IdentifierResult ->
  ZonkResult ->
  Maybe VariableResolution ->
  [AST.ParameterBinding Zonked] ->
  AST.Block Zonked ->
  [ExhaustiveError]
walkAgentBody idResult zonkResult maybeResolution parameters block =
  paramErrors ++ walkBlock idResult zonkResult block
  where
    paramErrors = case maybeResolution of
      Nothing -> []
      Just variableResolution ->
        case Map.lookup variableResolution zonkResult.zonkedTypeEnvironment of
          Just (SemanticTypeFunction paramTypes _ _) ->
            concatMap (checkParam idResult zonkResult paramTypes) parameters
          _ -> []

-- | Check that a parameter's pattern is irrefutable for its declared type.
checkParam ::
  IdentifierResult ->
  ZonkResult ->
  Map Text (SemanticType Resolved) ->
  AST.ParameterBinding Zonked ->
  [ExhaustiveError]
checkParam idResult zonkResult paramTypes pb =
  let paramType = Map.findWithDefault SemanticTypeUnknown pb.label paramTypes
   in checkIrrefutable idResult zonkResult pb.pattern paramType

walkBlock :: IdentifierResult -> ZonkResult -> AST.Block Zonked -> [ExhaustiveError]
walkBlock idResult zonkResult block =
  concatMap (walkStatement idResult zonkResult) block.statements
    ++ maybe [] (walkExpression idResult zonkResult) block.returnExpression

walkHandler :: IdentifierResult -> ZonkResult -> AST.RequestHandler Zonked -> [ExhaustiveError]
walkHandler idResult zonkResult rh = walkBlock idResult zonkResult rh.body

walkStatement :: IdentifierResult -> ZonkResult -> AST.Statement Zonked -> [ExhaustiveError]
walkStatement idResult zonkResult = \case
  AST.StatementLet ls ->
    walkExpression idResult zonkResult ls.value
      ++ checkIrrefutable idResult zonkResult ls.pattern (getExpressionType ls.value)
  AST.StatementAgent ls ->
    walkAgentBody idResult zonkResult ls.name.resolution ls.parameters ls.body
  AST.StatementReturn rs ->
    walkExpression idResult zonkResult rs.value
  AST.StatementNext ns ->
    walkExpression idResult zonkResult ns.value
      ++ concatMap (walkExpression idResult zonkResult . (.value)) ns.modifiers
  AST.StatementBreak bs ->
    walkExpression idResult zonkResult bs.value
  AST.StatementForBreak fbs ->
    walkExpression idResult zonkResult fbs.value
  AST.StatementExpression expr ->
    walkExpression idResult zonkResult expr
  AST.StatementForNext _ -> []
  AST.StatementError _ -> []

walkExpression :: IdentifierResult -> ZonkResult -> AST.Expression Zonked -> [ExhaustiveError]
walkExpression idResult zonkResult = \case
  AST.ExpressionMatch me ->
    walkExpression idResult zonkResult me.subject
      ++ concatMap (walkBlock idResult zonkResult . (.body)) me.cases
      ++ checkMatch idResult zonkResult me
  AST.ExpressionFor fe ->
    concatMap (walkForInBinding idResult zonkResult) fe.inBindings
      ++ concatMap (walkExpression idResult zonkResult . (.initial)) fe.varBindings
      ++ walkBlock idResult zonkResult fe.body
      ++ maybe [] (walkBlock idResult zonkResult) fe.thenBlock
  AST.ExpressionIf ie ->
    walkExpression idResult zonkResult ie.condition
      ++ walkBlock idResult zonkResult ie.thenBlock
      ++ maybe [] (walkBlock idResult zonkResult) ie.elseBlock
  AST.ExpressionBlock be ->
    walkBlock idResult zonkResult be.block
  AST.ExpressionCall ce ->
    walkExpression idResult zonkResult ce.callee
      ++ concatMap (walkExpression idResult zonkResult . (.value)) ce.arguments
  AST.ExpressionBinaryOperator be ->
    walkExpression idResult zonkResult be.left ++ walkExpression idResult zonkResult be.right
  AST.ExpressionUnaryOperator ue ->
    walkExpression idResult zonkResult ue.operand
  AST.ExpressionTuple te ->
    concatMap (walkExpression idResult zonkResult) te.elements
  AST.ExpressionArray ae ->
    concatMap (walkExpression idResult zonkResult) ae.elements
  AST.ExpressionRecord re ->
    concatMap (walkExpression idResult zonkResult . snd) re.entries
  AST.ExpressionFieldAccess fa ->
    walkExpression idResult zonkResult fa.object
  AST.ExpressionIndexAccess ia ->
    walkExpression idResult zonkResult ia.array ++ walkExpression idResult zonkResult ia.index
  AST.ExpressionTemplate te ->
    concatMap (walkTemplateElement idResult zonkResult) te.elements
  AST.ExpressionHandle he ->
    concatMap (walkHandler idResult zonkResult) he.handlers
      ++ maybe
        []
        ( \(maybePattern, thenBlock) ->
            maybe [] (\pat -> checkIrrefutable idResult zonkResult pat SemanticTypeUnknown) maybePattern
              ++ walkBlock idResult zonkResult thenBlock
        )
        he.thenClause
      ++ walkBlock idResult zonkResult he.body
  AST.ExpressionParTuple pte ->
    concatMap (walkExpression idResult zonkResult) pte.elements
  AST.ExpressionParArray pae ->
    concatMap (walkExpression idResult zonkResult) pae.elements
  AST.ExpressionLiteral _ -> []
  AST.ExpressionVariable _ -> []
  AST.ExpressionQualifiedReference _ -> []

walkForInBinding :: IdentifierResult -> ZonkResult -> AST.ForInBinding Zonked -> [ExhaustiveError]
walkForInBinding idResult zonkResult fib =
  walkExpression idResult zonkResult fib.source
    ++ let elemType = case getExpressionType fib.source of
             SemanticTypeArray t -> t
             _ -> SemanticTypeUnknown
        in checkIrrefutable idResult zonkResult fib.pattern elemType

walkTemplateElement :: IdentifierResult -> ZonkResult -> AST.TemplateElement Zonked -> [ExhaustiveError]
walkTemplateElement idResult zonkResult = \case
  AST.TemplateElementString _ -> []
  AST.TemplateElementExpression ee -> walkExpression idResult zonkResult ee.value
