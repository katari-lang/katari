-- | Exhaustiveness and reachability checking for Katari match expressions
-- and irrefutable binding contexts.
--
-- Implements Maranget's "Warnings for pattern matching" (JFP 2007) as a
-- post-typecheck pass. The entry point walks the typechecked ('Zonked') module
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

    -- * Per-module check
    ExhaustiveEnv (..),
    checkExhaustiveModule,
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
  ( GenericsId,
    QualifiedName (..),
    VariableResolution (..),
  )
import Katari.SemanticType
  ( Parameter (..),
    Resolved,
    SemanticType (..),
    functionParameters,
  )
import Katari.SourceSpan (HasSourceSpan (..), SourceSpan)
import Katari.Typechecker.Identifier (ConstructorData (..))
import Katari.Typechecker.NormalizedType (BoundEnv, denormalise, expandGenerics, normaliseSemantic)

-- | Cross-module context the checker needs while walking a single module:
-- the constructors and top-level types reachable from the module (own +
-- transitive imports), plus the module's local type environment.
data ExhaustiveEnv = ExhaustiveEnv
  { constructors :: Map QualifiedName ConstructorData,
    topLevelTypes :: Map QualifiedName (SemanticType Resolved),
    localTypeEnv :: Map VariableResolution (SemanticType Resolved),
    -- | The module's generic parameters' @extends@ bounds (keyed by
    -- 'GenericsId'). A generic scrutinee is expanded to its bound before its
    -- shape is examined, so a structured pattern over @T extends [..]@ is
    -- soundly checked against the bound's shapes.
    genericBounds :: Map GenericsId (SemanticType Resolved)
  }

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
-- for each column (left-to-right) plus the per-module 'ExhaustiveEnv'.
data TypeCtx = TypeCtx
  { columnTypes :: [SemanticType Resolved],
    env :: ExhaustiveEnv,
    -- | The module's generic bounds, normalized once (so each column read can
    -- expand a generic scrutinee to its bound).
    boundEnv :: BoundEnv
  }

-- | The head column's subject type, with its outermost generics expanded to
-- their bounds so the shape checks (signature completeness, tag compatibility)
-- see the bound's concrete shapes. Sound: a generic's values are a subset of
-- its bound's, so a pattern set covering the bound covers the generic.
headColumnType :: TypeCtx -> SemanticType Resolved
headColumnType context = case context.columnTypes of
  (t : _) -> denormalise (expandGenerics context.boundEnv (normaliseSemantic t))
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
    | not (tagCompatibleWithType tag (headColumnType context) context.env) ->
        False
  -- Base: empty matrix — any (type-compatible) query is useful (nothing is
  -- covered yet).
  ([], _) -> True
  -- Recursive: dispatch on head of query.
  (_, PatHeadWildcard : restPats) ->
    let columnType = headColumnType context
        sigma = headsOf matrix
     in if isCompleteSig (map fst sigma) columnType context.env
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
  let subFieldTypes = getSubFieldTypes tag columnType context.env
      remaining = drop 1 context.columnTypes
   in context {columnTypes = subFieldTypes ++ remaining}

-- | Drop the first column type (for defaultMatrix).
defaultCtx :: TypeCtx -> TypeCtx
defaultCtx context = context {columnTypes = drop 1 context.columnTypes}

-- | Field types for a constructor, in alphabetical label order. Returns []
-- for literal / null tags (arity 0) and tuples (handled separately).
getSubFieldTypes :: CtorTag -> SemanticType Resolved -> ExhaustiveEnv -> [SemanticType Resolved]
getSubFieldTypes tag columnType env = case tag of
  CtorTagData qualifiedName ->
    case Map.lookup qualifiedName env.topLevelTypes of
      Just (SemanticTypeFunction parameterObject _ _) ->
        [parameter.parameterType | (_, parameter) <- Map.toAscList (functionParameters parameterObject)]
      _ -> []
  CtorTagTupleN n -> case columnType of
    -- Pad / truncate to the pattern's arity so the sub-pattern columns line
    -- up even when it names fewer or more positions than the tuple type
    -- (positions past the named length are 'unknown'); over an array the
    -- element type repeats.
    SemanticTypeTuple tupleTypes -> take n (tupleTypes ++ repeat SemanticTypeUnknown)
    SemanticTypeArray element -> replicate n element
    _ -> replicate n SemanticTypeUnknown
  CtorTagType narrowTag -> [typePatternTagToResolved narrowTag]
  CtorTagRecordKeys keys -> case columnType of
    SemanticTypeRecord v -> replicate (length keys) v
    -- An object pattern over an object subject can read each key's declared
    -- field type; missing keys (width subtyping) fall back to 'unknown'.
    SemanticTypeObject fields ->
      map (\key -> maybe SemanticTypeUnknown (.parameterType) (Map.lookup key fields)) keys
    _ -> replicate (length keys) SemanticTypeUnknown
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
  ExhaustiveEnv ->
  Bool
tagCompatibleWithType tag ty env = case ty of
  SemanticTypeUnknown -> True
  SemanticTypeNever -> True
  SemanticTypeUnion branches ->
    any (\branch -> tagCompatibleWithType tag branch env) branches
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
    CtorTagTupleN _ -> case ty of
      -- No arity/length check: under the minimum-elements semantics a tuple
      -- value may carry more positions than its type names, and tuple <:
      -- array, so a tuple pattern of any arity can match some value of any
      -- tuple- or array-typed subject (a long-enough value always exists).
      SemanticTypeTuple _ -> True
      SemanticTypeArray _ -> True
      _ -> False
    CtorTagData qualifiedName -> case ty of
      SemanticTypeData tid ->
        case Map.lookup qualifiedName env.constructors of
          Just cd -> cd.constructorTypeQName == tid
          Nothing -> False
      -- data <: object <: record: an object- or record-typed subject can
      -- hold a tagged data value at runtime, so a constructor pattern is
      -- reachable there. Conservative — we do not refine by whether this
      -- particular data is a subtype of the object; an over-broad
      -- reachability only ever misses a warning, never raises a false error.
      SemanticTypeObject _ -> True
      SemanticTypeRecord _ -> True
      _ -> False
    -- Runtime type-guard patterns are always compatible: the guard runs
    -- at runtime against any value, narrowing from whatever the static
    -- type is.
    CtorTagType _ -> True
    CtorTagRecordKeys _ -> True

isCompleteSig :: [CtorTag] -> SemanticType Resolved -> ExhaustiveEnv -> Bool
isCompleteSig seen ty env = case ty of
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
    -- A tuple pattern of arity n matches *every* value of this type iff
    -- n <= the named length (each value has at least that many positions),
    -- so a single such pattern already forms a complete signature. A longer
    -- pattern only covers the longer-than-named values and never completes.
    any (\case CtorTagTupleN n -> n <= length tupleTypes; _ -> False) seen
  SemanticTypeData tid ->
    let ctorQNames = [qualifiedName | (qualifiedName, _) <- ctorsOfType env tid]
        seenQNames = [qualifiedName | CtorTagData qualifiedName <- seen]
     in null ctorQNames
          || all (`elem` seenQNames) ctorQNames
  SemanticTypeUnion branches ->
    not (null branches)
      && all (\branch -> isCompleteSig seen branch env) branches
  SemanticTypeNever ->
    True
  _ ->
    False

-- ===========================================================================
-- Constructor enumeration helpers
-- ===========================================================================

ctorsOfType :: ExhaustiveEnv -> QualifiedName -> [(QualifiedName, Int)]
ctorsOfType env typeQName =
  [ (qualifiedName, lookupCtorArity env qualifiedName)
    | (qualifiedName, cd) <- Map.toList env.constructors,
      cd.constructorTypeQName == typeQName
  ]

-- | Arity of a constructor from its function-type signature.
lookupCtorArity :: ExhaustiveEnv -> QualifiedName -> Int
lookupCtorArity env qualifiedName =
  case Map.lookup qualifiedName env.topLevelTypes of
    Just (SemanticTypeFunction parameterObject _ _) -> Map.size (functionParameters parameterObject)
    _ -> 0

-- ===========================================================================
-- Pattern-to-head conversion
-- ===========================================================================

-- | Convert an AST 'AST.Pattern Zonked' to a 'PatHead'. Field patterns for
-- data constructors are sorted alphabetically by label to ensure consistent
-- column ordering across all rows.
patternToHead :: ExhaustiveEnv -> AST.Pattern Zonked -> PatHead
patternToHead env = \case
  AST.PatternVariable _ -> PatHeadWildcard
  AST.PatternWildcard _ -> PatHeadWildcard
  AST.PatternLiteral lp -> PatHeadCtor (literalTag lp.value) []
  AST.PatternTuple tp ->
    PatHeadCtor (CtorTagTupleN (length tp.elements)) (map (patternToHead env) tp.elements)
  AST.PatternQualifiedConstructor qp ->
    case qp.constructorName.resolution of
      Nothing -> PatHeadWildcard
      Just qualifiedName ->
        case Map.lookup qualifiedName env.constructors of
          Nothing -> PatHeadWildcard
          Just _cd ->
            let sortedSubs =
                  map (patternToHead env . snd) $
                    sortBy (comparing ((.text) . fst)) qp.parameters
             in PatHeadCtor (CtorTagData qualifiedName) sortedSubs
  AST.PatternType tp ->
    PatHeadCtor (CtorTagType tp.typeTag) [patternToHead env tp.inner]
  AST.PatternRecord rp ->
    let sortedEntries = sortBy (comparing fst) rp.entries
        sortedKeys = map fst sortedEntries
        sortedSubs = map (patternToHead env . snd) sortedEntries
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
  AST.ExpressionRecord e -> e.typeOf
  AST.ExpressionCall e -> e.typeOf
  AST.ExpressionBinaryOperator e -> e.typeOf
  AST.ExpressionUnaryOperator e -> e.typeOf
  AST.ExpressionIf e -> e.typeOf
  AST.ExpressionMatch e -> e.typeOf
  AST.ExpressionFor e -> e.typeOf
  AST.ExpressionBlock e -> e.typeOf
  AST.ExpressionFieldAccess e -> e.typeOf
  AST.ExpressionTypeApplication e -> e.typeOf
  AST.ExpressionTemplate e -> e.typeOf
  AST.ExpressionHandle e -> e.typeOf
  AST.ExpressionParTuple e -> e.typeOf
  AST.ExpressionQualifiedReference e -> e.typeOf

-- ===========================================================================
-- Witness rendering (simplified; steps 3-8)
-- ===========================================================================

renderWitnesses :: [Text] -> Text
renderWitnesses [] = "(unknown)"
renderWitnesses witnesses = "`" <> Text.intercalate " | " witnesses <> "`"

-- | Build a minimal human-readable counter-example from a 'PatHead'. Used
-- for K0290 / K0291 diagnostic messages.
renderPatHead :: PatHead -> Text
renderPatHead = \case
  PatHeadWildcard -> "_"
  PatHeadCtor (CtorTagLitBool b) _ -> if b then "true" else "false"
  PatHeadCtor CtorTagNull _ -> "null"
  PatHeadCtor (CtorTagLitInt n) _ -> Text.pack (show n)
  PatHeadCtor (CtorTagLitNum d) _ -> Text.pack (show d)
  PatHeadCtor (CtorTagLitStr s) _ -> "\"" <> s <> "\""
  PatHeadCtor (CtorTagTupleN n) subs ->
    "("
      <> Text.intercalate ", " (map renderPatHead subs)
      <> ")"
      <> if null subs then Text.pack (" {tuple/" <> show n <> "}") else ""
  PatHeadCtor (CtorTagData qualifiedName) subs ->
    let ctorName = qualifiedName.name
     in if null subs
          then ctorName <> "()"
          else ctorName <> "(" <> Text.intercalate ", " (map renderPatHead subs) <> ")"
  PatHeadCtor (CtorTagType tag) subs ->
    typePatternTagName tag
      <> "("
      <> Text.intercalate ", " (map renderPatHead subs)
      <> ")"
  PatHeadCtor (CtorTagRecordKeys keys) subs ->
    let renderedSubs = map renderPatHead subs
        zipped =
          if length keys == length renderedSubs
            then zipWith (\k v -> k <> " = " <> v) keys renderedSubs
            else renderedSubs
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

checkMatch :: ExhaustiveEnv -> AST.MatchExpression Zonked -> [ExhaustiveError]
checkMatch env me =
  let subjectType = getExpressionType me.subject
      context = TypeCtx {columnTypes = [subjectType], env = env, boundEnv = Map.map normaliseSemantic env.genericBounds}
      arms = me.cases
      armHeads = map (\arm -> patternToHead env arm.pattern) arms
      armRows = [PatRow [h] arm.sourceSpan | (arm, h) <- zip arms armHeads]
      matrix = PatMatrix armRows
      nonExhaustiveErrors =
        if useful context matrix [PatHeadWildcard]
          then
            let witness = renderPatHead PatHeadWildcard
             in [ExhaustiveErrorNonExhaustiveMatch me.sourceSpan [witness]]
          else []
      unreachableErrors =
        catMaybes
          [ if not (useful context (PatMatrix (take idx armRows)) [armHead])
              then Just (ExhaustiveErrorUnreachableArm arm.sourceSpan)
              else Nothing
            | (idx, arm, armHead) <- zip3 [0 ..] arms armHeads
          ]
   in nonExhaustiveErrors ++ unreachableErrors

checkIrrefutable ::
  ExhaustiveEnv ->
  AST.Pattern Zonked ->
  SemanticType Resolved ->
  [ExhaustiveError]
checkIrrefutable env pattern subjectType =
  let headPat = patternToHead env pattern
      context = TypeCtx {columnTypes = [subjectType], env = env, boundEnv = Map.map normaliseSemantic env.genericBounds}
      sourceSpan = sourceSpanOf pattern
      row = PatRow [headPat] sourceSpan
   in if useful context (PatMatrix [row]) [PatHeadWildcard]
        then
          let witness = renderPatHead PatHeadWildcard
           in [ExhaustiveErrorNonExhaustiveBinding sourceSpan [witness]]
        else []

-- ===========================================================================
-- AST walker
-- ===========================================================================

-- | Per-module exhaustiveness check. The @env@ must carry the
-- constructors and top-level types reachable from this module (own +
-- transitive imports) plus the module's own local type environment.
checkExhaustiveModule :: ExhaustiveEnv -> AST.Module Zonked -> [ExhaustiveError]
checkExhaustiveModule env m = concatMap (walkDeclaration env) m.declarations

walkDeclaration :: ExhaustiveEnv -> AST.Declaration Zonked -> [ExhaustiveError]
walkDeclaration env = \case
  AST.DeclarationAgent decl -> walkBlock env decl.body
  AST.DeclarationRequest _ -> []
  AST.DeclarationExternalAgent _ -> []
  AST.DeclarationPrimAgent _ -> []
  AST.DeclarationData _ -> []
  AST.DeclarationTypeSynonym _ -> []
  AST.DeclarationImport _ -> []
  AST.DeclarationError _ -> []

walkBlock :: ExhaustiveEnv -> AST.Block Zonked -> [ExhaustiveError]
walkBlock env block =
  concatMap (walkStatement env) block.statements
    ++ maybe [] (walkExpression env) block.returnExpression

walkHandler :: ExhaustiveEnv -> AST.RequestHandler Zonked -> [ExhaustiveError]
walkHandler env rh = walkBlock env rh.body

walkStatement :: ExhaustiveEnv -> AST.Statement Zonked -> [ExhaustiveError]
walkStatement env = \case
  AST.StatementLet ls ->
    walkExpression env ls.value
      ++ checkIrrefutable env ls.pattern (getExpressionType ls.value)
  AST.StatementAgent ls -> walkBlock env ls.body
  AST.StatementReturn rs ->
    walkExpression env rs.value
  AST.StatementNext ns ->
    walkExpression env ns.value
      ++ concatMap (walkExpression env . (.value)) ns.modifiers
  AST.StatementBreak bs ->
    walkExpression env bs.value
  AST.StatementForBreak fbs ->
    walkExpression env fbs.value
  AST.StatementExpression expr ->
    walkExpression env expr
  AST.StatementForNext fns ->
    walkExpression env fns.value
      ++ concatMap (walkExpression env . (.value)) fns.modifiers
  AST.StatementError _ -> []

walkExpression :: ExhaustiveEnv -> AST.Expression Zonked -> [ExhaustiveError]
walkExpression env = \case
  AST.ExpressionMatch me ->
    walkExpression env me.subject
      ++ concatMap (walkBlock env . (.body)) me.cases
      ++ checkMatch env me
  AST.ExpressionFor fe ->
    concatMap (walkForInBinding env) fe.inBindings
      ++ concatMap (walkExpression env . (.initial)) fe.varBindings
      ++ walkBlock env fe.body
      ++ maybe
        []
        ( \(maybePattern, thenBlock) ->
            maybe [] (\pat -> checkIrrefutable env pat SemanticTypeUnknown) maybePattern
              ++ walkBlock env thenBlock
        )
        fe.thenBlock
  AST.ExpressionIf ie ->
    walkExpression env ie.condition
      ++ walkBlock env ie.thenBlock
      ++ maybe [] (walkBlock env) ie.elseBlock
  AST.ExpressionBlock be ->
    walkBlock env be.block
  AST.ExpressionCall ce ->
    walkExpression env ce.callee
      ++ concatMap (walkExpression env . (.value)) ce.arguments
  AST.ExpressionBinaryOperator be ->
    walkExpression env be.left ++ walkExpression env be.right
  AST.ExpressionUnaryOperator ue ->
    walkExpression env ue.operand
  AST.ExpressionTuple te ->
    concatMap (walkExpression env) te.elements
  AST.ExpressionRecord re ->
    concatMap (walkExpression env . snd) re.entries
  AST.ExpressionFieldAccess fa ->
    walkExpression env fa.object
  AST.ExpressionTypeApplication ta ->
    walkExpression env ta.callee
  AST.ExpressionTemplate te ->
    concatMap (walkTemplateElement env) te.elements
  AST.ExpressionHandle he ->
    concatMap (walkHandler env) he.handlers
      ++ maybe
        []
        ( \(maybePattern, thenBlock) ->
            maybe [] (\pat -> checkIrrefutable env pat SemanticTypeUnknown) maybePattern
              ++ walkBlock env thenBlock
        )
        he.thenClause
      ++ walkBlock env he.body
  AST.ExpressionParTuple pte ->
    concatMap (walkExpression env) pte.elements
  AST.ExpressionLiteral _ -> []
  AST.ExpressionVariable _ -> []
  AST.ExpressionQualifiedReference _ -> []

walkForInBinding :: ExhaustiveEnv -> AST.ForInBinding Zonked -> [ExhaustiveError]
walkForInBinding env fib =
  walkExpression env fib.source
    ++ let elemType = case getExpressionType fib.source of
             SemanticTypeArray t -> t
             _ -> SemanticTypeUnknown
        in checkIrrefutable env fib.pattern elemType

walkTemplateElement :: ExhaustiveEnv -> AST.TemplateElement Zonked -> [ExhaustiveError]
walkTemplateElement env = \case
  AST.TemplateElementString _ -> []
  AST.TemplateElementExpression ee -> walkExpression env ee.value
