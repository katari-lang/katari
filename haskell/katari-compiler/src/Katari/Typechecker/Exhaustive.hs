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
import Katari.Common (LiteralValue (..))
import Katari.Diagnostic (Diagnostic, diagnosticError, diagnosticWarning)
import Katari.SemanticType
  ( Resolved,
    SemanticType (..),
  )
import Katari.SourceSpan (HasSourceSpan (..), SourceSpan)
import Katari.Id
  ( ConstructorId,
    QualifiedName (..),
    TypeId,
    VariableId,
  )
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
      "unreachable match arm: prior arms already cover this pattern"
      sourceSpan

-- ===========================================================================
-- Pattern representation (Maranget §2)
-- ===========================================================================

-- | Head constructor tag.
data CtorTag where
  CtorTagData :: ConstructorId -> CtorTag
  CtorTagLitInt :: Integer -> CtorTag
  CtorTagLitStr :: Text -> CtorTag
  CtorTagLitBool :: Bool -> CtorTag
  CtorTagNull :: CtorTag
  CtorTagTupleN :: Int -> CtorTag
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
  -- Base: empty matrix — any query is useful (nothing is covered yet).
  ([], _) -> True
  -- Base: empty query — useful only if matrix is empty (vacuous).
  (_, []) -> null rows
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
  CtorTagData cid ->
    case Map.lookup cid idResult.identifiedConstructors of
      Nothing -> []
      Just cd ->
        case Map.lookup cd.constructorVariableId zonkResult.zonkedTypeEnvironment of
          Just (SemanticTypeFunction parameters _ _) ->
            map snd (Map.toAscList parameters)
          _ -> []
  CtorTagTupleN _ -> case columnType of
    SemanticTypeTuple tupleTypes -> tupleTypes
    _ -> []
  _ -> []

-- ===========================================================================
-- Complete-signature check
-- ===========================================================================

-- | @isCompleteSig seen ty idResult zonkResult@ — returns 'True' if @seen@
-- (the set of ctor tags appearing in the first column of the pattern
-- matrix) constitutes a complete signature for @ty@.
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
    let ctorIds = [cid | (cid, _) <- ctorsOfType idResult zonkResult tid]
        seenCtorIds = [cid | CtorTagData cid <- seen]
     in null ctorIds -- vacuously complete (no constructors)
          || all (`elem` seenCtorIds) ctorIds
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

-- | All constructors of a data type, with their arities.
ctorsOfType :: IdentifierResult -> ZonkResult -> TypeId -> [(ConstructorId, Int)]
ctorsOfType idResult zonkResult typeId =
  [ (cid, lookupCtorArity zonkResult cd.constructorVariableId)
    | (cid, cd) <- Map.toList idResult.identifiedConstructors,
      cd.constructorTypeId == typeId
  ]

-- | Arity of a constructor from its function-type signature.
lookupCtorArity :: ZonkResult -> VariableId -> Int
lookupCtorArity zonkResult varId =
  case Map.lookup varId zonkResult.zonkedTypeEnvironment of
    Just (SemanticTypeFunction parameters _ _) -> Map.size parameters
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

literalTag :: LiteralValue -> CtorTag
literalTag = \case
  LiteralValueInteger n -> CtorTagLitInt n
  LiteralValueString s -> CtorTagLitStr s
  LiteralValueBoolean b -> CtorTagLitBool b
  LiteralValueNull -> CtorTagNull
  LiteralValueNumber _ -> CtorTagLitStr "(number)"
  -- 'LiteralValueAgent' is an IR-only literal produced by Lowering; the
  -- AST exhaustiveness checker should never encounter one.
  LiteralValueAgent _ -> error "literalTag: LiteralValueAgent should not appear in AST patterns"

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
  PatHeadCtor (CtorTagLitStr s) _ -> "\"" <> s <> "\""
  PatHeadCtor (CtorTagTupleN n) subs ->
    "("
      <> Text.intercalate ", " (map (renderPatHead idResult zonkResult) subs)
      <> ")"
      <> if null subs then Text.pack (" {tuple/" <> show n <> "}") else ""
  PatHeadCtor (CtorTagData cid) subs ->
    let ctorName = case Map.lookup cid idResult.identifiedConstructors of
          Just cd -> cd.constructorQualifiedName.name
          Nothing -> "?"
     in if null subs
          then ctorName <> "()"
          else ctorName <> "(" <> Text.intercalate ", " (map (renderPatHead idResult zonkResult) subs) <> ")"

-- ===========================================================================
-- Match checking
-- ===========================================================================

checkMatch :: IdentifierResult -> ZonkResult -> AST.MatchExpression Zonked -> [ExhaustiveError]
checkMatch idResult zonkResult me =
  let subjectType = getExpressionType me.subject
      context = TypeCtx {columnTypes = [subjectType], identifierResult = idResult, zonkResult = zonkResult}
      arms = me.cases
      armHeads = map (\arm -> patternToHead arm.pattern) arms
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
  let headPat = patternToHead pattern
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
  AST.DeclarationData _ -> []
  AST.DeclarationTypeSynonym _ -> []
  AST.DeclarationImport _ -> []
  AST.DeclarationError _ -> []

-- | Walk an agent body: check parameter irrefutability + walk the block.
walkAgentBody ::
  IdentifierResult ->
  ZonkResult ->
  Maybe VariableId ->
  [AST.ParameterBinding Zonked] ->
  AST.Block Zonked ->
  [ExhaustiveError]
walkAgentBody idResult zonkResult maybeVarId parameters block =
  paramErrors ++ walkBlock idResult zonkResult block
  where
    paramErrors = case maybeVarId of
      Nothing -> []
      Just varId ->
        case Map.lookup varId zonkResult.zonkedTypeEnvironment of
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
