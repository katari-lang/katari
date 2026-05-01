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
import Katari.Diagnostic (Diagnostic, diagnosticError, diagnosticWarning)
import Katari.SemanticType
  ( Resolved,
    SemanticType (..),
  )
import Katari.SourceSpan (HasSourceSpan (..), SourceSpan)
import Katari.Typechecker.Identifier
  ( ConstructorData (..),
    ConstructorId,
    QualifiedName (..),
    TypeId,
    VariableId,
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
      "unreachable match arm: prior arms already cover this pattern"
      sourceSpan

-- ===========================================================================
-- Pattern representation (Maranget §2)
-- ===========================================================================

-- | Head constructor tag.
data CtorTag where
  CtorTagData :: !ConstructorId -> CtorTag
  CtorTagLitInt :: !Integer -> CtorTag
  CtorTagLitStr :: !Text -> CtorTag
  CtorTagLitBool :: !Bool -> CtorTag
  CtorTagNull :: CtorTag
  CtorTagTupleN :: !Int -> CtorTag
  deriving (Eq, Ord, Show)

-- | Simplified pattern head. Variables and wildcards become 'PatHeadWildcard'.
data PatHead where
  PatHeadWildcard :: PatHead
  PatHeadCtor :: !CtorTag -> ![PatHead] -> PatHead
  deriving (Eq, Show)

-- | A row of the pattern matrix.
data PatRow = PatRow
  { patRowPats :: ![PatHead],
    patRowSpan :: !SourceSpan
  }
  deriving (Show)

-- | Pattern matrix (list of rows, all the same width).
newtype PatMatrix = PatMatrix [PatRow]
  deriving (Show)

-- ===========================================================================
-- Algorithm context
-- ===========================================================================

-- | Threading context for the algorithm. Carries the subject column type
-- for each column (left-to-right) and the ZonkResult for ctor lookups.
data TypeCtx = TypeCtx
  { columnTypes :: ![SemanticType Resolved],
    zonkResult :: !ZonkResult
  }

headColumnType :: TypeCtx -> SemanticType Resolved
headColumnType ctx = case ctx.columnTypes of
  (t : _) -> t
  [] -> SemanticTypeUnknown

-- ===========================================================================
-- Maranget algorithm (§3.1 of Maranget 2007)
-- ===========================================================================

-- | @useful ctx P q@ — returns 'True' if row vector @q@ is useful w.r.t.
-- pattern matrix @P@, i.e. if there exists a value matched by @q@ but not
-- by any row of @P@.
useful :: TypeCtx -> PatMatrix -> [PatHead] -> Bool
useful ctx matrix@(PatMatrix rows) testRow = case (rows, testRow) of
  -- Base: empty matrix — any query is useful (nothing is covered yet).
  ([], _) -> True
  -- Base: empty query — useful only if matrix is empty (vacuous).
  (_, []) -> null rows
  -- Recursive: dispatch on head of query.
  (_, PatHeadWildcard : restPats) ->
    let colType = headColumnType ctx
        sigma = headsOf matrix
     in if isCompleteSig (map fst sigma) colType ctx.zonkResult
          then -- complete signature: recurse on each specialisation
            any
              ( \(tag, arity) ->
                  let freshWilds = replicate arity PatHeadWildcard
                      newCtx = specializeCtx tag colType ctx
                   in useful newCtx (specialize tag arity matrix) (freshWilds ++ restPats)
              )
              sigma
          else -- incomplete: fall through to default matrix
            useful (defaultCtx ctx) (defaultMatrix matrix) restPats
  (_, PatHeadCtor tag subPats : restPats) ->
    let arity = length subPats
        colType = headColumnType ctx
        newCtx = specializeCtx tag colType ctx
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
specializeCtx tag colType ctx =
  let subFieldTypes = getSubFieldTypes tag colType ctx.zonkResult
      remaining = drop 1 ctx.columnTypes
   in ctx {columnTypes = subFieldTypes ++ remaining}

-- | Drop the first column type (for defaultMatrix).
defaultCtx :: TypeCtx -> TypeCtx
defaultCtx ctx = ctx {columnTypes = drop 1 ctx.columnTypes}

-- | Field types for a constructor, in alphabetical label order. Returns []
-- for literal / null tags (arity 0) and tuples (handled separately).
getSubFieldTypes :: CtorTag -> SemanticType Resolved -> ZonkResult -> [SemanticType Resolved]
getSubFieldTypes tag colType zr = case tag of
  CtorTagData cid ->
    case Map.lookup cid zr.zonkedConstructors of
      Nothing -> []
      Just cd ->
        case Map.lookup cd.constructorVariableId zr.zonkedTypeEnvironment of
          Just (SemanticTypeFunction params _ _) ->
            map snd (Map.toAscList params)
          _ -> []
  CtorTagTupleN _ -> case colType of
    SemanticTypeTuple tupleTypes -> tupleTypes
    _ -> []
  _ -> []

-- ===========================================================================
-- Complete-signature check
-- ===========================================================================

-- | @isCompleteSig seen ty zr@ — returns 'True' if @seen@ (the set of ctor
-- tags appearing in the first column of the pattern matrix) constitutes a
-- complete signature for @ty@.
isCompleteSig :: [CtorTag] -> SemanticType Resolved -> ZonkResult -> Bool
isCompleteSig seen ty zr = case ty of
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
    let ctorIds = [cid | (cid, _) <- ctorsOfType zr tid]
        seenCtorIds = [cid | CtorTagData cid <- seen]
     in null ctorIds -- vacuously complete (no constructors)
          || all (`elem` seenCtorIds) ctorIds
  SemanticTypeUnion branches ->
    -- Complete iff every branch is completely covered.
    not (null branches)
      && all (\branch -> isCompleteSig seen branch zr) branches
  SemanticTypeNever ->
    True -- no values; vacuously exhaustive
  _ ->
    False -- Integer, Number, String, Array, Object, Unknown: infinite domain

-- ===========================================================================
-- Constructor enumeration helpers
-- ===========================================================================

-- | All constructors of a data type, with their arities.
ctorsOfType :: ZonkResult -> TypeId -> [(ConstructorId, Int)]
ctorsOfType zr typeId =
  [ (cid, lookupCtorArity zr cd.constructorVariableId)
    | (cid, cd) <- Map.toList zr.zonkedConstructors,
      cd.constructorTypeId == typeId
  ]

-- | Arity of a constructor from its function-type signature.
lookupCtorArity :: ZonkResult -> VariableId -> Int
lookupCtorArity zr varId =
  case Map.lookup varId zr.zonkedTypeEnvironment of
    Just (SemanticTypeFunction params _ _) -> Map.size params
    _ -> 0

-- ===========================================================================
-- Pattern-to-head conversion
-- ===========================================================================

-- | Convert an AST 'AST.Pattern Zonked' to a 'PatHead'. Field patterns for
-- data constructors are sorted alphabetically by label to ensure consistent
-- column ordering across all rows.
patternToHead :: AST.Pattern Zonked -> PatHead
patternToHead = \case
  AST.PatternVariable _ -> PatHeadWildcard
  AST.PatternWildcard _ -> PatHeadWildcard
  AST.PatternLiteral lp -> PatHeadCtor (literalTag lp.value) []
  AST.PatternTuple tp ->
    PatHeadCtor (CtorTagTupleN (length tp.elements)) (map patternToHead tp.elements)
  AST.PatternQualifiedConstructor qp ->
    case qp.constructorName.resolution of
      Nothing ->
        -- Unresolved ctor: treat as wildcard (Identifier error already emitted)
        PatHeadWildcard
      Just cid ->
        let sortedSubs =
              map (patternToHead . snd) $
                sortBy (comparing ((.text) . fst)) qp.parameters
         in PatHeadCtor (CtorTagData cid) sortedSubs

literalTag :: AST.LiteralValue -> CtorTag
literalTag = \case
  AST.LiteralValueInteger n -> CtorTagLitInt n
  AST.LiteralValueString s -> CtorTagLitStr s
  AST.LiteralValueBoolean b -> CtorTagLitBool b
  AST.LiteralValueNull -> CtorTagNull
  AST.LiteralValueNumber _ -> CtorTagLitStr "(number)"

-- | Extract the semantic type from any 'AST.Expression Zonked'.
getExpressionType :: AST.Expression Zonked -> SemanticType Resolved
getExpressionType = \case
  AST.ExpressionLiteral e -> e.typeOf
  AST.ExpressionVariable e -> e.typeOf
  AST.ExpressionTuple e -> e.typeOf
  AST.ExpressionArray e -> e.typeOf
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
  AST.ExpressionQualifiedReference e -> e.typeOf

-- ===========================================================================
-- Witness rendering (simplified; steps 3-8)
-- ===========================================================================

renderWitnesses :: [Text] -> Text
renderWitnesses [] = "(unknown)"
renderWitnesses witnesses = "`" <> Text.intercalate " | " witnesses <> "`"

-- | Build a minimal human-readable counter-example from a 'PatHead'. Used
-- for K0290 / K0291 diagnostic messages.
renderPatHead :: ZonkResult -> PatHead -> Text
renderPatHead zr = \case
  PatHeadWildcard -> "_"
  PatHeadCtor (CtorTagLitBool b) _ -> if b then "true" else "false"
  PatHeadCtor CtorTagNull _ -> "null"
  PatHeadCtor (CtorTagLitInt n) _ -> Text.pack (show n)
  PatHeadCtor (CtorTagLitStr s) _ -> "\"" <> s <> "\""
  PatHeadCtor (CtorTagTupleN n) subs ->
    "("
      <> Text.intercalate ", " (map (renderPatHead zr) subs)
      <> ")"
      <> if null subs then Text.pack (" {tuple/" <> show n <> "}") else ""
  PatHeadCtor (CtorTagData cid) subs ->
    let ctorName = case Map.lookup cid zr.zonkedConstructors of
          Just cd -> cd.constructorQualifiedName.name
          Nothing -> "?"
     in if null subs
          then ctorName <> "()"
          else ctorName <> "(" <> Text.intercalate ", " (map (renderPatHead zr) subs) <> ")"

-- ===========================================================================
-- Match checking
-- ===========================================================================

checkMatch :: ZonkResult -> AST.MatchExpression Zonked -> [ExhaustiveError]
checkMatch zr me =
  let subjectType = getExpressionType me.subject
      ctx = TypeCtx {columnTypes = [subjectType], zonkResult = zr}
      arms = me.cases
      armHeads = map (\arm -> patternToHead arm.pattern) arms
      armRows = [PatRow [h] arm.sourceSpan | (arm, h) <- zip arms armHeads]
      matrix = PatMatrix armRows
      -- Non-exhaustiveness: is there a value not covered by any arm?
      nonExhaustiveErrors =
        if useful ctx matrix [PatHeadWildcard]
          then
            let witness = renderPatHead zr PatHeadWildcard
             in [ExhaustiveErrorNonExhaustiveMatch me.sourceSpan [witness]]
          else []
      -- Reachability: is arm i already covered by prior arms?
      unreachableErrors =
        catMaybes
          [ if not (useful ctx (PatMatrix (take idx armRows)) [armHead])
              then Just (ExhaustiveErrorUnreachableArm arm.sourceSpan)
              else Nothing
            | (idx, arm, armHead) <- zip3 [0 ..] arms armHeads
          ]
   in nonExhaustiveErrors ++ unreachableErrors

-- | Check that @pattern@ is irrefutable (covers all values of @subjectType@).
-- Returns a K0291 error if not.
checkIrrefutable ::
  ZonkResult ->
  AST.Pattern Zonked ->
  SemanticType Resolved ->
  [ExhaustiveError]
checkIrrefutable zr pattern subjectType =
  let headPat = patternToHead pattern
      ctx = TypeCtx {columnTypes = [subjectType], zonkResult = zr}
      sourceSpan = sourceSpanOf pattern
      row = PatRow [headPat] sourceSpan
   in if useful ctx (PatMatrix [row]) [PatHeadWildcard]
        then
          let witness = renderPatHead zr PatHeadWildcard
           in [ExhaustiveErrorNonExhaustiveBinding sourceSpan [witness]]
        else []

-- ===========================================================================
-- AST walker
-- ===========================================================================

-- | Entry point: walk all Zonked modules and collect exhaustiveness errors.
checkExhaustive :: ZonkResult -> [ExhaustiveError]
checkExhaustive zr =
  concatMap (walkModule zr) (Map.elems zr.zonkedModules)

walkModule :: ZonkResult -> AST.Module Zonked -> [ExhaustiveError]
walkModule zr m = concatMap (walkDeclaration zr) m.declarations

walkDeclaration :: ZonkResult -> AST.Declaration Zonked -> [ExhaustiveError]
walkDeclaration zr = \case
  AST.DeclarationAgent decl ->
    walkAgentBody zr decl.name.resolution decl.parameters decl.body
  AST.DeclarationRequest _ -> []
  AST.DeclarationExternalAgent _ -> []
  AST.DeclarationData _ -> []
  AST.DeclarationTypeSynonym _ -> []
  AST.DeclarationImport _ -> []
  AST.DeclarationError _ -> []

-- | Walk an agent body: check parameter irrefutability + walk the block.
walkAgentBody ::
  ZonkResult ->
  Maybe VariableId ->
  [AST.ParameterBinding Zonked] ->
  AST.Block Zonked ->
  [ExhaustiveError]
walkAgentBody zr maybeVarId params block =
  paramErrors ++ walkBlock zr block
  where
    paramErrors = case maybeVarId of
      Nothing -> []
      Just varId ->
        case Map.lookup varId zr.zonkedTypeEnvironment of
          Just (SemanticTypeFunction paramTypes _ _) ->
            concatMap (checkParam zr paramTypes) params
          _ -> []

-- | Check that a parameter's pattern is irrefutable for its declared type.
checkParam ::
  ZonkResult ->
  Map Text (SemanticType Resolved) ->
  AST.ParameterBinding Zonked ->
  [ExhaustiveError]
checkParam zr paramTypes pb =
  let paramType = Map.findWithDefault SemanticTypeUnknown pb.label paramTypes
   in checkIrrefutable zr pb.pattern paramType

walkBlock :: ZonkResult -> AST.Block Zonked -> [ExhaustiveError]
walkBlock zr block =
  concatMap (walkStatement zr) block.statements
    ++ maybe [] (walkExpression zr) block.returnExpression
    ++ maybe [] (walkWhereBlock zr) block.whereBlock

walkWhereBlock :: ZonkResult -> AST.WhereBlock Zonked -> [ExhaustiveError]
walkWhereBlock zr wb =
  concatMap (walkHandler zr) wb.handlers
    ++ maybe
      []
      ( \(maybePattern, thenBlock) ->
          maybe [] checkThenPattern maybePattern
            ++ walkBlock zr thenBlock
      )
      wb.thenClause
  where
    -- The then-clause pattern binds the break/return value of the scope body.
    -- Its subject type is the union of all break-statement value types, which
    -- we cannot reconstruct cheaply here. SemanticTypeUnknown is the most
    -- conservative approximation: it still correctly rejects refutable patterns
    -- (literal / constructor matches) since the algorithm treats Unknown as an
    -- open type with no complete constructor signature.
    checkThenPattern pat = checkIrrefutable zr pat SemanticTypeUnknown

walkHandler :: ZonkResult -> AST.RequestHandler Zonked -> [ExhaustiveError]
walkHandler zr rh = walkBlock zr rh.body

walkStatement :: ZonkResult -> AST.Statement Zonked -> [ExhaustiveError]
walkStatement zr = \case
  AST.StatementLet ls ->
    walkExpression zr ls.value
      ++ checkIrrefutable zr ls.pattern (getExpressionType ls.value)
  AST.StatementAgent ls ->
    walkAgentBody zr ls.name.resolution ls.parameters ls.body
  AST.StatementReturn rs ->
    walkExpression zr rs.value
  AST.StatementNext ns ->
    walkExpression zr ns.value
      ++ concatMap (walkExpression zr . (.value)) ns.modifiers
  AST.StatementBreak bs ->
    walkExpression zr bs.value
  AST.StatementForBreak fbs ->
    walkExpression zr fbs.value
  AST.StatementExpression expr ->
    walkExpression zr expr
  AST.StatementForNext _ -> []
  AST.StatementError _ -> []

walkExpression :: ZonkResult -> AST.Expression Zonked -> [ExhaustiveError]
walkExpression zr = \case
  AST.ExpressionMatch me ->
    walkExpression zr me.subject
      ++ concatMap (walkBlock zr . (.body)) me.cases
      ++ checkMatch zr me
  AST.ExpressionFor fe ->
    concatMap (walkForInBinding zr) fe.inBindings
      ++ concatMap (walkExpression zr . (.initial)) fe.varBindings
      ++ walkBlock zr fe.body
      ++ maybe [] (walkBlock zr) fe.thenBlock
  AST.ExpressionIf ie ->
    walkExpression zr ie.condition
      ++ walkBlock zr ie.thenBlock
      ++ maybe [] (walkBlock zr) ie.elseBlock
  AST.ExpressionBlock be ->
    walkBlock zr be.block
  AST.ExpressionCall ce ->
    walkExpression zr ce.callee
      ++ concatMap (walkExpression zr . (.value)) ce.arguments
  AST.ExpressionBinaryOperator be ->
    walkExpression zr be.left ++ walkExpression zr be.right
  AST.ExpressionUnaryOperator ue ->
    walkExpression zr ue.operand
  AST.ExpressionTuple te ->
    concatMap (walkExpression zr) te.elements
  AST.ExpressionArray ae ->
    concatMap (walkExpression zr) ae.elements
  AST.ExpressionFieldAccess fa ->
    walkExpression zr fa.object
  AST.ExpressionIndexAccess ia ->
    walkExpression zr ia.array ++ walkExpression zr ia.index
  AST.ExpressionTemplate te ->
    concatMap (walkTemplateElement zr) te.elements
  AST.ExpressionLiteral _ -> []
  AST.ExpressionVariable _ -> []
  AST.ExpressionQualifiedReference _ -> []

walkForInBinding :: ZonkResult -> AST.ForInBinding Zonked -> [ExhaustiveError]
walkForInBinding zr fib =
  walkExpression zr fib.source
    ++ let elemType = case getExpressionType fib.source of
             SemanticTypeArray t -> t
             _ -> SemanticTypeUnknown
        in checkIrrefutable zr fib.pattern elemType

walkTemplateElement :: ZonkResult -> AST.TemplateElement Zonked -> [ExhaustiveError]
walkTemplateElement zr = \case
  AST.TemplateElementString _ -> []
  AST.TemplateElementExpression ee -> walkExpression zr ee.value
