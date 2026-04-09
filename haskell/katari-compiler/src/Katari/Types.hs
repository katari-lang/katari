module Katari.Types
  ( NormalizedType (..),
    NormalFields (..),
    BoolKind (..),
    NumericKind (..),
    IntPart (..),
    NumPart (..),
    StringKind (..),
    ObjectFields (..),
    FieldInfo (..),
    Discriminator (..),
    LitVal (..),

    -- * Smart constructors
    ntNever,
    ntNull,
    ntBool,
    ntInteger,
    ntNumber,
    ntString,

    -- * Operations
    isNeverNT,
    normalize,
    unionNT,
    intersectNT,
    subtypeNT,
    subtractNT,
    patternTypeNT,
    tryMakeDISC,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Katari.Syntax
  ( Lit (..),
    ObjField (..),
    Pat (..),
    PrimTag (..),
    Type (..),
  )

-- ---------------------------------------------------------------------------
-- NormalizedType
-- ---------------------------------------------------------------------------

data NormalizedType
  = NTUnknown
  | NTDISC Discriminator
  | NTFields NormalFields
  deriving (Show, Eq)

data NormalFields = NormalFields
  { nfNull :: Bool,
    nfBoolean :: Maybe BoolKind,
    nfNumeric :: Maybe NumericKind,
    nfString :: Maybe StringKind,
    nfArray :: Maybe NormalizedType,
    nfObject :: Maybe ObjectFields
  }
  deriving (Show, Eq)

data BoolKind = BoolFull | BoolLits (Set Bool)
  deriving (Show, Eq)

data NumericKind = NumericKind
  { nkInt :: IntPart,
    nkNum :: NumPart
  }
  deriving (Show, Eq)

data IntPart = IntAbsent | IntFull | IntLits (Set Integer)
  deriving (Show, Eq)

data NumPart = NumAbsent | NumFull | NumLits (Set Double)
  deriving (Show, Eq)

data StringKind = StringFull | StringLits (Set Text)
  deriving (Show, Eq)

newtype ObjectFields = ObjectFields
  { ofFields :: Map Text FieldInfo
  }
  deriving (Show, Eq)

data FieldInfo = FieldInfo
  { fiType :: NormalizedType,
    fiOptional :: Bool,
    fiAnnot :: Maybe Text
  }
  deriving (Show, Eq)

-- Discriminated union
data Discriminator = Discriminator
  { discField :: Text,
    discMapping :: Map LitVal NormalFields
  }
  deriving (Show, Eq)

-- Discriminator literal value (key in disc mapping)
data LitVal
  = LVBool Bool
  | LVInt Integer
  | LVNum Double
  | LVStr Text
  deriving (Show, Eq, Ord)

-- ---------------------------------------------------------------------------
-- Smart constructors
-- ---------------------------------------------------------------------------

emptyFields :: NormalFields
emptyFields = NormalFields False Nothing Nothing Nothing Nothing Nothing

ntNever :: NormalizedType
ntNever = NTFields emptyFields

ntNull :: NormalizedType
ntNull = NTFields emptyFields {nfNull = True}

ntBool :: NormalizedType
ntBool = NTFields emptyFields {nfBoolean = Just BoolFull}

ntInteger :: NormalizedType
ntInteger = NTFields emptyFields {nfNumeric = Just (NumericKind IntFull NumAbsent)}

ntNumber :: NormalizedType
ntNumber = NTFields emptyFields {nfNumeric = Just (NumericKind IntFull NumFull)}

ntString :: NormalizedType
ntString = NTFields emptyFields {nfString = Just StringFull}

-- ---------------------------------------------------------------------------
-- isNever
-- ---------------------------------------------------------------------------

isNeverNT :: NormalizedType -> Bool
isNeverNT = \case
  NTFields nf -> isNeverFields nf
  _ -> False

isNeverFields :: NormalFields -> Bool
isNeverFields NormalFields {..} =
  not nfNull
    && null nfBoolean
    && null nfNumeric
    && null nfString
    && null nfArray
    && null nfObject

isNeverNumeric :: NumericKind -> Bool
isNeverNumeric = \case
  NumericKind IntAbsent NumAbsent -> True
  _ -> False

-- ---------------------------------------------------------------------------
-- normalize
-- ---------------------------------------------------------------------------

normalize :: Type -> Map Text NormalizedType -> NormalizedType
normalize ty env = case ty of
  TNull -> ntNull
  TBoolean -> ntBool
  TInteger -> ntInteger
  TNumber -> ntNumber
  TString -> ntString
  TNever -> ntNever
  TUnknown -> NTUnknown
  TLitBool b -> NTFields emptyFields {nfBoolean = Just (BoolLits (Set.singleton b))}
  TLitInt i -> NTFields emptyFields {nfNumeric = Just (NumericKind (IntLits (Set.singleton i)) NumAbsent)}
  TLitNum n -> NTFields emptyFields {nfNumeric = Just (NumericKind IntAbsent (NumLits (Set.singleton n)))}
  TLitStr s -> NTFields emptyFields {nfString = Just (StringLits (Set.singleton s))}
  TArray t -> NTFields emptyFields {nfArray = Just (normalize t env)}
  TUnion ts -> foldr (unionNT . (`normalize` env)) ntNever ts
  TInter ts -> foldr (intersectNT . (`normalize` env)) NTUnknown ts
  TAlias name -> fromMaybe ntNever (Map.lookup name env) -- unknown alias → never
  TObj fields ->
    let ofields =
          Map.fromList
            [ ( ofName f,
                FieldInfo
                  { fiType = normalize (ofType f) env,
                    fiOptional = ofOptional f,
                    fiAnnot = ofAnnot f
                  }
              )
              | f <- fields
            ]
        -- Check if any required field is never
        neverPropagated =
          any
            (\fi -> not (fiOptional fi) && isNeverNT (fiType fi))
            (Map.elems ofields)
     in if neverPropagated
          then ntNever
          else case tryMakeDISC fields ofields env of
            Just disc -> NTDISC disc
            Nothing -> NTFields emptyFields {nfObject = Just (ObjectFields ofields)}

-- Try to build a DISC from object fields
-- Requires exactly one 'uniq' field with a literal type
tryMakeDISC :: [ObjField] -> Map Text FieldInfo -> Map Text NormalizedType -> Maybe Discriminator
tryMakeDISC fields ofields _env = case filter ofUniq fields of
  [f] ->
    let nf =
          NormalFields
            { nfNull = False,
              nfBoolean = Nothing,
              nfNumeric = Nothing,
              nfString = Nothing,
              nfArray = Nothing,
              nfObject = Just (ObjectFields ofields)
            }
        mkDisc lv =
          Just $
            Discriminator
              { discField = ofName f,
                discMapping = Map.singleton lv nf
              }
     in case ofType f of
          TLitBool b -> mkDisc (LVBool b)
          TLitInt i -> mkDisc (LVInt i)
          TLitStr s -> mkDisc (LVStr s)
          _ -> Nothing
  _ -> Nothing

-- ---------------------------------------------------------------------------
-- Union
-- ---------------------------------------------------------------------------

unionNT :: NormalizedType -> NormalizedType -> NormalizedType
unionNT a b = case (a, b) of
  (NTUnknown, _) -> NTUnknown
  (_, NTUnknown) -> NTUnknown
  (NTDISC d1, NTDISC d2)
    | discField d1 == discField d2 -> NTDISC (unionDisc d1 d2)
    | otherwise -> NTFields (unionFields (discToFields d1) (discToFields d2))
  -- never ∪ disc = disc, disc ∪ never = disc (preserve DISC structure).
  (NTDISC d, NTFields nf)
    | isNeverFields nf -> NTDISC d
    | otherwise -> NTFields (unionFields (discToFields d) nf)
  (NTFields nf, NTDISC d)
    | isNeverFields nf -> NTDISC d
    | otherwise -> NTFields (unionFields nf (discToFields d))
  (NTFields f1, NTFields f2) -> NTFields (unionFields f1 f2)

unionDisc :: Discriminator -> Discriminator -> Discriminator
unionDisc d1 d2 =
  let merged = Map.unionWith unionFields (discMapping d1) (discMapping d2)
   in d1 {discMapping = merged}

discToFields :: Discriminator -> NormalFields
discToFields disc =
  let nfs = Map.elems (discMapping disc)
   in foldl unionFields emptyFields nfs

unionFields :: NormalFields -> NormalFields -> NormalFields
unionFields f1 f2 =
  NormalFields
    { nfNull = nfNull f1 || nfNull f2,
      nfBoolean = unionBool (nfBoolean f1) (nfBoolean f2),
      nfNumeric = unionNumeric (nfNumeric f1) (nfNumeric f2),
      nfString = unionString (nfString f1) (nfString f2),
      nfArray = unionArr (nfArray f1) (nfArray f2),
      nfObject = unionObj (nfObject f1) (nfObject f2)
    }

unionBool :: Maybe BoolKind -> Maybe BoolKind -> Maybe BoolKind
unionBool a b = case (a, b) of
  (Nothing, x) -> x
  (x, Nothing) -> x
  (Just BoolFull, _) -> Just BoolFull
  (_, Just BoolFull) -> Just BoolFull
  (Just (BoolLits s1), Just (BoolLits s2)) ->
    let s = Set.union s1 s2
     in if s == Set.fromList [True, False] then Just BoolFull else Just (BoolLits s)

unionNumeric :: Maybe NumericKind -> Maybe NumericKind -> Maybe NumericKind
unionNumeric a b = case (a, b) of
  (Nothing, x) -> x
  (x, Nothing) -> x
  (Just n1, Just n2) ->
    let ip = unionIntPart (nkInt n1) (nkInt n2)
        np = unionNumPart (nkNum n1) (nkNum n2)
        nk = NumericKind ip np
     in if isNeverNumeric nk then Nothing else Just nk

unionIntPart :: IntPart -> IntPart -> IntPart
unionIntPart a b = case (a, b) of
  (IntFull, _) -> IntFull
  (_, IntFull) -> IntFull
  (IntAbsent, x) -> x
  (x, IntAbsent) -> x
  (IntLits s1, IntLits s2) -> IntLits (Set.union s1 s2)

unionNumPart :: NumPart -> NumPart -> NumPart
unionNumPart a b = case (a, b) of
  (NumFull, _) -> NumFull
  (_, NumFull) -> NumFull
  (NumAbsent, x) -> x
  (x, NumAbsent) -> x
  (NumLits s1, NumLits s2) -> NumLits (Set.union s1 s2)

unionString :: Maybe StringKind -> Maybe StringKind -> Maybe StringKind
unionString a b = case (a, b) of
  (Nothing, x) -> x
  (x, Nothing) -> x
  (Just StringFull, _) -> Just StringFull
  (_, Just StringFull) -> Just StringFull
  (Just (StringLits s1), Just (StringLits s2)) -> Just (StringLits (Set.union s1 s2))

unionArr :: Maybe NormalizedType -> Maybe NormalizedType -> Maybe NormalizedType
unionArr a b = case (a, b) of
  (Nothing, x) -> x
  (x, Nothing) -> x
  (Just t1, Just t2) -> Just (unionNT t1 t2)

unionObj :: Maybe ObjectFields -> Maybe ObjectFields -> Maybe ObjectFields
unionObj a b = case (a, b) of
  -- Nothing = no objects in this set; union with the other side.
  (Nothing, x) -> x
  (x, Nothing) -> x
  (Just o1, Just o2) ->
    -- keep only common fields, with union types (widening).
    let common = Map.intersectionWith mergeField (ofFields o1) (ofFields o2)
     in Just (ObjectFields common)
  where
    mergeField fi1 fi2 =
      FieldInfo
        { fiType = unionNT (fiType fi1) (fiType fi2),
          fiOptional = fiOptional fi1 || fiOptional fi2,
          fiAnnot = fiAnnot fi1
        }

-- ---------------------------------------------------------------------------
-- Intersection
-- ---------------------------------------------------------------------------

intersectNT :: NormalizedType -> NormalizedType -> NormalizedType
intersectNT a b = case (a, b) of
  (NTUnknown, t) -> t
  (t, NTUnknown) -> t
  (NTDISC d1, NTDISC d2)
    | discField d1 == discField d2 ->
        let merged = Map.intersectionWith intersectFields (discMapping d1) (discMapping d2)
            alive = Map.filter (not . isNeverFields) merged
         in if Map.null alive then ntNever else NTDISC d1 {discMapping = alive}
    | otherwise -> NTFields (intersectFields (discToFields d1) (discToFields d2))
  (NTDISC d, NTFields nf) ->
    let merged = Map.map (`intersectFields` nf) (discMapping d)
        alive = Map.filter (not . isNeverFields) merged
     in if Map.null alive then ntNever else NTDISC d {discMapping = alive}
  (NTFields nf, NTDISC d) -> intersectNT (NTDISC d) (NTFields nf)
  (NTFields f1, NTFields f2) -> NTFields (intersectFields f1 f2)

intersectFields :: NormalFields -> NormalFields -> NormalFields
intersectFields f1 f2 =
  let result =
        NormalFields
          { nfNull = nfNull f1 && nfNull f2,
            nfBoolean = intersectBool (nfBoolean f1) (nfBoolean f2),
            nfNumeric = intersectNumeric (nfNumeric f1) (nfNumeric f2),
            nfString = intersectString (nfString f1) (nfString f2),
            nfArray = intersectArr (nfArray f1) (nfArray f2),
            nfObject = intersectObj (nfObject f1) (nfObject f2)
          }
   in result

intersectBool :: Maybe BoolKind -> Maybe BoolKind -> Maybe BoolKind
intersectBool a b = case (a, b) of
  (Nothing, _) -> Nothing
  (_, Nothing) -> Nothing
  (Just BoolFull, x) -> x
  (x, Just BoolFull) -> x
  (Just (BoolLits s1), Just (BoolLits s2)) ->
    let s = Set.intersection s1 s2
     in if Set.null s then Nothing else Just (BoolLits s)

intersectNumeric :: Maybe NumericKind -> Maybe NumericKind -> Maybe NumericKind
intersectNumeric a b = case (a, b) of
  (Nothing, _) -> Nothing
  (_, Nothing) -> Nothing
  (Just n1, Just n2) ->
    let ip = intersectIntPart (nkInt n1) (nkInt n2)
        np = intersectNumPart (nkNum n1) (nkNum n2)
        nk = NumericKind ip np
     in if isNeverNumeric nk then Nothing else Just nk

intersectIntPart :: IntPart -> IntPart -> IntPart
intersectIntPart a b = case (a, b) of
  (IntFull, x) -> x
  (x, IntFull) -> x
  (IntAbsent, _) -> IntAbsent
  (_, IntAbsent) -> IntAbsent
  (IntLits s1, IntLits s2) ->
    let s = Set.intersection s1 s2
     in if Set.null s then IntAbsent else IntLits s

intersectNumPart :: NumPart -> NumPart -> NumPart
intersectNumPart a b = case (a, b) of
  (NumFull, x) -> x
  (x, NumFull) -> x
  (NumAbsent, _) -> NumAbsent
  (_, NumAbsent) -> NumAbsent
  (NumLits s1, NumLits s2) ->
    let s = Set.intersection s1 s2
     in if Set.null s then NumAbsent else NumLits s

intersectString :: Maybe StringKind -> Maybe StringKind -> Maybe StringKind
intersectString a b = case (a, b) of
  (Nothing, _) -> Nothing
  (_, Nothing) -> Nothing
  (Just StringFull, x) -> x
  (x, Just StringFull) -> x
  (Just (StringLits s1), Just (StringLits s2)) ->
    let s = Set.intersection s1 s2
     in if Set.null s then Nothing else Just (StringLits s)

intersectArr :: Maybe NormalizedType -> Maybe NormalizedType -> Maybe NormalizedType
intersectArr a b = case (a, b) of
  (Nothing, _) -> Nothing
  (_, Nothing) -> Nothing
  (Just t1, Just t2) -> Just (intersectNT t1 t2)

intersectObj :: Maybe ObjectFields -> Maybe ObjectFields -> Maybe ObjectFields
intersectObj a b = case (a, b) of
  -- Nothing = no objects in the set; intersection with anything = Nothing.
  (Nothing, _) -> Nothing
  (_, Nothing) -> Nothing
  (Just o1, Just o2) ->
    let -- For common fields, also check optional
        common = Map.intersectionWith mergeCommon (ofFields o1) (ofFields o2)
        onlyIn1 = Map.difference (ofFields o1) (ofFields o2)
        onlyIn2 = Map.difference (ofFields o2) (ofFields o1)
        all_ = Map.unions [common, onlyIn1, onlyIn2]
        -- If any required field is never, the whole object is never
        neverProp = any (\fi -> not (fiOptional fi) && isNeverNT (fiType fi)) (Map.elems all_)
     in if neverProp
          then Nothing -- propagate never
          else Just (ObjectFields all_)
  where
    mergeCommon fi1 fi2 =
      FieldInfo
        { fiType = intersectNT (fiType fi1) (fiType fi2),
          fiOptional = fiOptional fi1 && fiOptional fi2,
          fiAnnot = fiAnnot fi1
        }

-- ---------------------------------------------------------------------------
-- Subtyping
-- ---------------------------------------------------------------------------

subtypeNT :: NormalizedType -> NormalizedType -> Bool
subtypeNT a b = case (a, b) of
  (_, NTUnknown) -> True
  (NTUnknown, _) -> False -- Unknown <: T only if T = Unknown
  (NTDISC d, NTDISC d2)
    | discField d == discField d2 ->
        all
          ( \(k, nf) -> case Map.lookup k (discMapping d2) of
              Just nf2 -> subtypeFieldsNT nf nf2
              Nothing -> False
          )
          (Map.toList (discMapping d))
    | otherwise -> subtypeFieldsNT (discToFields d) (discToFields d2)
  (NTDISC d, NTFields nf2) ->
    all (`subtypeFieldsNT` nf2) (Map.elems (discMapping d))
  (NTFields nf, NTDISC d) ->
    any (subtypeFieldsNT nf) (Map.elems (discMapping d))
  (NTFields f1, NTFields f2) -> subtypeFieldsNT f1 f2

subtypeFieldsNT :: NormalFields -> NormalFields -> Bool
subtypeFieldsNT f1 f2 =
  subtypeNull (nfNull f1) (nfNull f2)
    && subtypeBool (nfBoolean f1) (nfBoolean f2)
    && subtypeNum (nfNumeric f1) (nfNumeric f2)
    && subtypeStr (nfString f1) (nfString f2)
    && subtypeArr (nfArray f1) (nfArray f2)
    && subtypeObj (nfObject f1) (nfObject f2)

subtypeNull :: Bool -> Bool -> Bool
subtypeNull a b = case (a, b) of
  (True, False) -> False
  _ -> True

subtypeBool :: Maybe BoolKind -> Maybe BoolKind -> Bool
subtypeBool a b = case (a, b) of
  (Nothing, _) -> True -- never <: anything
  (_, Nothing) -> False
  (Just BoolFull, Just BoolFull) -> True
  (Just BoolFull, _) -> False
  (Just (BoolLits _), Just BoolFull) -> True
  (Just (BoolLits s1), Just (BoolLits s2)) -> Set.isSubsetOf s1 s2

subtypeNum :: Maybe NumericKind -> Maybe NumericKind -> Bool
subtypeNum a b = case (a, b) of
  (Nothing, _) -> True
  (_, Nothing) -> False
  (Just n1, Just n2) ->
    subtypeIntInNum (nkInt n1) n2
      && subtypeNumPart (nkNum n1) (nkNum n2)

-- Integer subtype check: integers can be in intPart OR numPart of target
subtypeIntInNum :: IntPart -> NumericKind -> Bool
subtypeIntInNum ip n2 = case ip of
  IntAbsent -> True
  IntFull -> nkInt n2 == IntFull || nkNum n2 == NumFull
  IntLits s -> case nkInt n2 of
    IntFull -> True
    IntLits s2 -> Set.isSubsetOf s s2
    IntAbsent -> case nkNum n2 of
      NumFull -> True
      _ -> False -- can't check individual ints against float lits

subtypeNumPart :: NumPart -> NumPart -> Bool
subtypeNumPart a b = case (a, b) of
  (NumAbsent, _) -> True
  (_, NumAbsent) -> False
  (NumFull, NumFull) -> True
  (NumFull, _) -> False
  (_, NumFull) -> True
  (NumLits s1, NumLits s2) -> Set.isSubsetOf s1 s2

subtypeStr :: Maybe StringKind -> Maybe StringKind -> Bool
subtypeStr a b = case (a, b) of
  (Nothing, _) -> True
  (_, Nothing) -> False
  (Just StringFull, Just StringFull) -> True
  (Just StringFull, _) -> False
  (Just (StringLits _), Just StringFull) -> True
  (Just (StringLits s1), Just (StringLits s2)) -> Set.isSubsetOf s1 s2

subtypeArr :: Maybe NormalizedType -> Maybe NormalizedType -> Bool
subtypeArr a b = case (a, b) of
  (Nothing, _) -> True
  (_, Nothing) -> False
  (Just t1, Just t2) -> subtypeNT t1 t2

subtypeObj :: Maybe ObjectFields -> Maybe ObjectFields -> Bool
subtypeObj a b = case (a, b) of
  (Nothing, _) -> True
  (_, Nothing) -> False
  (Just o1, Just o2) ->
    -- For every field in o2 it must be present in o1 (with a compatible
    -- type), unless the field is optional in o2 in which case its absence
    -- from o1 is fine too.
    all (checkField o1) (Map.toList (ofFields o2))
  where
    checkField o1 (name, fi2) =
      case Map.lookup name (ofFields o1) of
        Nothing -> fiOptional fi2
        Just fi1 ->
          subtypeNT (fiType fi1) (fiType fi2)
            && (fiOptional fi2 || not (fiOptional fi1))

-- ---------------------------------------------------------------------------
-- Subtraction (for exhaustiveness checking)
-- ---------------------------------------------------------------------------

subtractNT :: NormalizedType -> NormalizedType -> NormalizedType
subtractNT a b = case (a, b) of
  (_, NTUnknown) -> ntNever
  (NTUnknown, _) -> NTUnknown
  (NTDISC d1, NTDISC d2)
    | discField d1 == discField d2 ->
        let subtractVariant k nf =
              case Map.lookup k (discMapping d2) of
                Nothing -> nf
                Just nf2 -> subtractFields nf nf2
            mapping' = Map.mapWithKey subtractVariant (discMapping d1)
            alive = Map.filter (not . isNeverFields) mapping'
         in if Map.null alive then ntNever else NTDISC d1 {discMapping = alive}
    | otherwise -> NTFields (subtractFields (discToFields d1) (discToFields d2))
  (NTDISC d, NTFields nf2) ->
    NTFields (subtractFields (discToFields d) nf2)
  (NTFields nf1, NTDISC d) ->
    NTFields (subtractFields nf1 (discToFields d))
  (NTFields f1, NTFields f2) -> NTFields (subtractFields f1 f2)

subtractFields :: NormalFields -> NormalFields -> NormalFields
subtractFields f1 f2 =
  NormalFields
    { nfNull = not (nfNull f2) && nfNull f1,
      nfBoolean = subtractBool (nfBoolean f1) (nfBoolean f2),
      nfNumeric = subtractNum (nfNumeric f1) (nfNumeric f2),
      nfString = subtractStr (nfString f1) (nfString f2),
      nfArray = subtractArrField (nfArray f1) (nfArray f2),
      nfObject = subtractObjField (nfObject f1) (nfObject f2)
    }

subtractBool :: Maybe BoolKind -> Maybe BoolKind -> Maybe BoolKind
subtractBool a b = case (a, b) of
  (Nothing, _) -> Nothing
  (x, Nothing) -> x
  (Just BoolFull, Just BoolFull) -> Nothing
  (Just BoolFull, Just (BoolLits s)) ->
    let remaining = Set.difference (Set.fromList [True, False]) s
     in if Set.null remaining then Nothing else Just (BoolLits remaining)
  (Just (BoolLits _), Just BoolFull) -> Nothing
  (Just (BoolLits s1), Just (BoolLits s2)) ->
    let s = Set.difference s1 s2
     in if Set.null s then Nothing else Just (BoolLits s)

subtractNum :: Maybe NumericKind -> Maybe NumericKind -> Maybe NumericKind
subtractNum a b = case (a, b) of
  (Nothing, _) -> Nothing
  (x, Nothing) -> x
  (Just n1, Just n2) ->
    let ip = subtractIntPart (nkInt n1) (nkInt n2) (nkNum n2)
        np = subtractNumPart (nkNum n1) (nkNum n2)
        nk = NumericKind ip np
     in if isNeverNumeric nk then Nothing else Just nk

-- Integer subtype: if target numPart is Full, integers are consumed
subtractIntPart :: IntPart -> IntPart -> NumPart -> IntPart
subtractIntPart i tgtI tgtN = case (i, tgtI, tgtN) of
  (IntAbsent, _, _) -> IntAbsent
  (_, IntFull, _) -> IntAbsent
  (_, _, NumFull) -> IntAbsent -- number includes integers
  (IntFull, IntLits _, _) -> IntFull -- conservative
  (IntLits s1, IntLits s2, _) ->
    let s = Set.difference s1 s2
     in if Set.null s then IntAbsent else IntLits s
  (x, _, _) -> x

subtractNumPart :: NumPart -> NumPart -> NumPart
subtractNumPart a b = case (a, b) of
  (NumAbsent, _) -> NumAbsent
  (n, NumAbsent) -> n
  (NumFull, NumFull) -> NumAbsent
  (NumFull, NumLits _) -> NumFull -- conservative
  (NumLits _, NumFull) -> NumAbsent
  (NumLits s1, NumLits s2) ->
    let s = Set.difference s1 s2
     in if Set.null s then NumAbsent else NumLits s

subtractStr :: Maybe StringKind -> Maybe StringKind -> Maybe StringKind
subtractStr a b = case (a, b) of
  (Nothing, _) -> Nothing
  (x, Nothing) -> x
  (Just StringFull, Just StringFull) -> Nothing
  (Just StringFull, Just (StringLits _)) -> Just StringFull -- conservative
  (Just (StringLits _), Just StringFull) -> Nothing
  (Just (StringLits s1), Just (StringLits s2)) ->
    let s = Set.difference s1 s2
     in if Set.null s then Nothing else Just (StringLits s)

-- Arrays: can't distinguish by element type at runtime → remove all
subtractArrField :: Maybe NormalizedType -> Maybe NormalizedType -> Maybe NormalizedType
subtractArrField a b = case (a, b) of
  (Nothing, _) -> Nothing
  (x, Nothing) -> x
  _ -> Nothing -- conservative: array patterns consume all arrays

-- Object subtraction
subtractObjField :: Maybe ObjectFields -> Maybe ObjectFields -> Maybe ObjectFields
subtractObjField a b = case (a, b) of
  (Nothing, _) -> Nothing
  (o, Nothing) -> o
  (Just o1, Just o2) ->
    -- Subtract: if all common fields' types subtract to never, the whole object is never
    let subtractFld (name, fi2) =
          case Map.lookup name (ofFields o1) of
            Nothing -> Nothing -- field in pattern not in type, no subtraction
            Just fi1 -> Just (subtractNT (fiType fi1) (fiType fi2))
        go = map subtractFld (Map.toList (ofFields o2))
     in if null (catMaybes go)
          then Just o1 -- no common fields
          else
            if all isNeverNT (catMaybes go)
              then Nothing -- all common fields subtracted to never
              else Just o1 -- conservative: keep

-- ---------------------------------------------------------------------------
-- Pattern type generation
-- ---------------------------------------------------------------------------

patternTypeNT :: Pat -> NormalizedType
patternTypeNT = \case
  PVar _ -> NTUnknown
  PTyped _ t -> normalize t Map.empty
  PLit lit -> patternLitType lit
  PTag tag _ -> case tag of
    TagBoolean -> ntBool
    TagInteger -> ntInteger
    TagNumber -> ntNumber
    TagString -> ntString
  PArr _ -> NTFields emptyFields {nfArray = Just NTUnknown}
  PObj fields ->
    -- Check for DISC (exactly one uniq field with literal pattern)
    let objFields =
          Map.fromList
            [ (n, FieldInfo (patternTypeNT p) False Nothing)
              | (n, _, p) <- fields
            ]
     in case [(name, pat) | (name, True, pat) <- fields] of
          [(discName, PLit lit)] ->
            let lv = litToLV lit
                nf =
                  NormalFields
                    { nfNull = False,
                      nfBoolean = Nothing,
                      nfNumeric = Nothing,
                      nfString = Nothing,
                      nfArray = Nothing,
                      nfObject = Just (ObjectFields objFields)
                    }
             in NTDISC (Discriminator discName (Map.singleton lv nf))
          _ -> NTFields emptyFields {nfObject = Just (ObjectFields objFields)}

patternLitType :: Lit -> NormalizedType
patternLitType = \case
  LNull -> ntNull
  LBool b -> NTFields emptyFields {nfBoolean = Just (BoolLits (Set.singleton b))}
  LInt i -> NTFields emptyFields {nfNumeric = Just (NumericKind (IntLits (Set.singleton i)) NumAbsent)}
  LNum n -> NTFields emptyFields {nfNumeric = Just (NumericKind IntAbsent (NumLits (Set.singleton n)))}
  LStr s -> NTFields emptyFields {nfString = Just (StringLits (Set.singleton s))}

litToLV :: Lit -> LitVal
litToLV = \case
  LBool b -> LVBool b
  LInt i -> LVInt i
  LNum n -> LVNum n
  LStr s -> LVStr s
  LNull -> LVStr "null" -- shouldn't happen for DISC
