module Katari.Types
  ( NormalizedType (..)
  , NormalFields (..)
  , BoolKind (..)
  , NumericKind (..)
  , IntPart (..)
  , NumPart (..)
  , StringKind (..)
  , ObjectFields (..)
  , FieldInfo (..)
  , Discriminator (..)
  , LitVal (..)
  -- * Smart constructors
  , ntNever
  , ntNull
  , ntBool
  , ntInteger
  , ntNumber
  , ntString
  -- * Operations
  , isNeverNT
  , normalize
  , unionNT
  , intersectNT
  , subtypeNT
  , subtractNT
  , patternTypeNT
  ) where

import Data.Text (Text)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Katari.Syntax

-- ---------------------------------------------------------------------------
-- NormalizedType
-- ---------------------------------------------------------------------------

data NormalizedType
  = NTUnknown
  | NTDISC    Discriminator
  | NTFields  NormalFields
  deriving (Show, Eq)

data NormalFields = NormalFields
  { nfNull    :: Bool
  , nfBoolean :: Maybe BoolKind
  , nfNumeric :: Maybe NumericKind
  , nfString  :: Maybe StringKind
  , nfArray   :: Maybe NormalizedType
  , nfObject  :: Maybe ObjectFields
  } deriving (Show, Eq)

data BoolKind = BoolFull | BoolLits (Set Bool)
  deriving (Show, Eq)

data NumericKind = NumericKind
  { nkInt :: IntPart
  , nkNum :: NumPart
  } deriving (Show, Eq)

data IntPart = IntAbsent | IntFull | IntLits (Set Integer)
  deriving (Show, Eq)

data NumPart = NumAbsent | NumFull | NumLits (Set Double)
  deriving (Show, Eq)

data StringKind = StringFull | StringLits (Set Text)
  deriving (Show, Eq)

data ObjectFields = ObjectFields
  { ofFields :: Map Text FieldInfo
  } deriving (Show, Eq)

data FieldInfo = FieldInfo
  { fiType     :: NormalizedType
  , fiOptional :: Bool
  } deriving (Show, Eq)

-- Discriminated union
data Discriminator = Discriminator
  { discField   :: Text
  , discMapping :: Map LitVal NormalFields
  } deriving (Show, Eq)

-- Discriminator literal value (key in disc mapping)
data LitVal
  = LVBool   Bool
  | LVInt    Integer
  | LVNum    Double
  | LVStr    Text
  deriving (Show, Eq, Ord)

-- ---------------------------------------------------------------------------
-- Smart constructors
-- ---------------------------------------------------------------------------

emptyFields :: NormalFields
emptyFields = NormalFields False Nothing Nothing Nothing Nothing Nothing

ntNever :: NormalizedType
ntNever = NTFields emptyFields

ntNull :: NormalizedType
ntNull = NTFields emptyFields { nfNull = True }

ntBool :: NormalizedType
ntBool = NTFields emptyFields { nfBoolean = Just BoolFull }

ntInteger :: NormalizedType
ntInteger = NTFields emptyFields { nfNumeric = Just (NumericKind IntFull NumAbsent) }

ntNumber :: NormalizedType
ntNumber = NTFields emptyFields { nfNumeric = Just (NumericKind IntFull NumFull) }

ntString :: NormalizedType
ntString = NTFields emptyFields { nfString = Just StringFull }

-- ---------------------------------------------------------------------------
-- isNever
-- ---------------------------------------------------------------------------

isNeverNT :: NormalizedType -> Bool
isNeverNT (NTFields nf) = isNeverFields nf
isNeverNT _             = False

isNeverFields :: NormalFields -> Bool
isNeverFields NormalFields{..} =
  not nfNull &&
  null nfBoolean &&
  null nfNumeric &&
  null nfString &&
  null nfArray &&
  null nfObject

isNeverNumeric :: NumericKind -> Bool
isNeverNumeric (NumericKind IntAbsent NumAbsent) = True
isNeverNumeric _ = False

-- ---------------------------------------------------------------------------
-- normalize
-- ---------------------------------------------------------------------------

normalize :: Type -> Map Text NormalizedType -> NormalizedType
normalize TNull            _env = ntNull
normalize TBoolean         _env = ntBool
normalize TInteger         _env = ntInteger
normalize TNumber          _env = ntNumber
normalize TString          _env = ntString
normalize TNever           _env = ntNever
normalize TUnknown         _env = NTUnknown
normalize (TLitBool b)     _env = NTFields emptyFields { nfBoolean = Just (BoolLits (Set.singleton b)) }
normalize (TLitInt  i)     _env = NTFields emptyFields { nfNumeric = Just (NumericKind (IntLits (Set.singleton i)) NumAbsent) }
normalize (TLitNum  n)     _env = NTFields emptyFields { nfNumeric = Just (NumericKind IntAbsent (NumLits (Set.singleton n))) }
normalize (TLitStr  s)     _env = NTFields emptyFields { nfString = Just (StringLits (Set.singleton s)) }
normalize (TArray   t)     env  = NTFields emptyFields { nfArray = Just (normalize t env) }
normalize (TUnion   ts)    env  = foldr unionNT ntNever (map (`normalize` env) ts)
normalize (TInter   ts)    env  = foldr intersectNT NTUnknown (map (`normalize` env) ts)
normalize (TAlias   name)  env  = case Map.lookup name env of
                                    Just nt -> nt
                                    Nothing -> ntNever  -- unknown alias → never
normalize (TObj fields)    env  =
  let ofields = Map.fromList
        [ (ofName f, FieldInfo { fiType = normalize (ofType f) env
                                , fiOptional = ofOptional f })
        | f <- fields ]
      -- Check if any required field is never
      neverPropagated = any (\fi -> not (fiOptional fi) && isNeverNT (fiType fi))
                            (Map.elems ofields)
  in if neverPropagated
     then ntNever
     else case tryMakeDISC fields ofields env of
            Just disc -> NTDISC disc
            Nothing   -> NTFields emptyFields { nfObject = Just (ObjectFields ofields) }

-- Try to build a DISC from object fields
-- Requires exactly one 'uniq' field with a literal type
tryMakeDISC :: [ObjField] -> Map Text FieldInfo -> Map Text NormalizedType -> Maybe Discriminator
tryMakeDISC fields ofields _env =
  case filter ofUniq fields of
    [f] -> case ofType f of
             TLitBool b -> Just $ Discriminator
               { discField = ofName f
               , discMapping = Map.singleton (LVBool b)
                   (NormalFields { nfNull = False, nfBoolean = Nothing, nfNumeric = Nothing
                                 , nfString = Nothing, nfArray = Nothing
                                 , nfObject = Just (ObjectFields ofields) })
               }
             TLitInt i -> Just $ Discriminator
               { discField = ofName f
               , discMapping = Map.singleton (LVInt i)
                   (NormalFields { nfNull = False, nfBoolean = Nothing, nfNumeric = Nothing
                                 , nfString = Nothing, nfArray = Nothing
                                 , nfObject = Just (ObjectFields ofields) })
               }
             TLitStr s -> Just $ Discriminator
               { discField = ofName f
               , discMapping = Map.singleton (LVStr s)
                   (NormalFields { nfNull = False, nfBoolean = Nothing, nfNumeric = Nothing
                                 , nfString = Nothing, nfArray = Nothing
                                 , nfObject = Just (ObjectFields ofields) })
               }
             _ -> Nothing
    _ -> Nothing

-- ---------------------------------------------------------------------------
-- Union
-- ---------------------------------------------------------------------------

unionNT :: NormalizedType -> NormalizedType -> NormalizedType
unionNT NTUnknown _         = NTUnknown
unionNT _         NTUnknown = NTUnknown
unionNT (NTDISC d1) (NTDISC d2)
  | discField d1 == discField d2 = NTDISC (unionDisc d1 d2)
  | otherwise =
      let nf1 = discToFields d1
          nf2 = discToFields d2
      in NTFields (unionFields nf1 nf2)
unionNT (NTDISC d) (NTFields nf) =
  let nfd = discToFields d
  in NTFields (unionFields nfd nf)
unionNT (NTFields nf) (NTDISC d) =
  let nfd = discToFields d
  in NTFields (unionFields nf nfd)
unionNT (NTFields f1) (NTFields f2) = NTFields (unionFields f1 f2)

unionDisc :: Discriminator -> Discriminator -> Discriminator
unionDisc d1 d2 =
  let merged = Map.unionWith unionFields (discMapping d1) (discMapping d2)
  in d1 { discMapping = merged }

discToFields :: Discriminator -> NormalFields
discToFields disc =
  let nfs = Map.elems (discMapping disc)
  in foldl unionFields emptyFields nfs

unionFields :: NormalFields -> NormalFields -> NormalFields
unionFields f1 f2 = NormalFields
  { nfNull    = nfNull f1 || nfNull f2
  , nfBoolean = unionBool (nfBoolean f1) (nfBoolean f2)
  , nfNumeric = unionNumeric (nfNumeric f1) (nfNumeric f2)
  , nfString  = unionString (nfString f1) (nfString f2)
  , nfArray   = unionArr (nfArray f1) (nfArray f2)
  , nfObject  = unionObj (nfObject f1) (nfObject f2)
  }

unionBool :: Maybe BoolKind -> Maybe BoolKind -> Maybe BoolKind
unionBool Nothing  b        = b
unionBool b        Nothing  = b
unionBool (Just BoolFull) _ = Just BoolFull
unionBool _ (Just BoolFull) = Just BoolFull
unionBool (Just (BoolLits s1)) (Just (BoolLits s2)) =
  let s = Set.union s1 s2
  in if s == Set.fromList [True, False] then Just BoolFull else Just (BoolLits s)

unionNumeric :: Maybe NumericKind -> Maybe NumericKind -> Maybe NumericKind
unionNumeric Nothing  b = b
unionNumeric b Nothing  = b
unionNumeric (Just n1) (Just n2) =
  let ip = unionIntPart (nkInt n1) (nkInt n2)
      np = unionNumPart (nkNum n1) (nkNum n2)
      nk = NumericKind ip np
  in if isNeverNumeric nk then Nothing else Just nk

unionIntPart :: IntPart -> IntPart -> IntPart
unionIntPart IntFull _               = IntFull
unionIntPart _       IntFull         = IntFull
unionIntPart IntAbsent b             = b
unionIntPart b         IntAbsent     = b
unionIntPart (IntLits s1) (IntLits s2) = IntLits (Set.union s1 s2)

unionNumPart :: NumPart -> NumPart -> NumPart
unionNumPart NumFull _               = NumFull
unionNumPart _       NumFull         = NumFull
unionNumPart NumAbsent b             = b
unionNumPart b         NumAbsent     = b
unionNumPart (NumLits s1) (NumLits s2) = NumLits (Set.union s1 s2)

unionString :: Maybe StringKind -> Maybe StringKind -> Maybe StringKind
unionString Nothing b = b
unionString b Nothing = b
unionString (Just StringFull) _ = Just StringFull
unionString _ (Just StringFull) = Just StringFull
unionString (Just (StringLits s1)) (Just (StringLits s2)) = Just (StringLits (Set.union s1 s2))

unionArr :: Maybe NormalizedType -> Maybe NormalizedType -> Maybe NormalizedType
unionArr Nothing b = b
unionArr b Nothing = b
unionArr (Just t1) (Just t2) = Just (unionNT t1 t2)

unionObj :: Maybe ObjectFields -> Maybe ObjectFields -> Maybe ObjectFields
unionObj Nothing  _        = Nothing
unionObj _        Nothing  = Nothing
unionObj (Just o1) (Just o2) =
  -- keep only common fields, with union types
  let common = Map.intersectionWith mergeField (ofFields o1) (ofFields o2)
  in Just (ObjectFields common)
  where
    mergeField fi1 fi2 = FieldInfo
      { fiType     = unionNT (fiType fi1) (fiType fi2)
      , fiOptional = fiOptional fi1 || fiOptional fi2
      }

-- ---------------------------------------------------------------------------
-- Intersection
-- ---------------------------------------------------------------------------

intersectNT :: NormalizedType -> NormalizedType -> NormalizedType
intersectNT NTUnknown t = t
intersectNT t NTUnknown = t
intersectNT (NTDISC d1) (NTDISC d2)
  | discField d1 == discField d2 =
      let merged = Map.intersectionWith intersectFields (discMapping d1) (discMapping d2)
          alive  = Map.filter (not . isNeverFields) merged
      in if Map.null alive then ntNever else NTDISC d1 { discMapping = alive }
  | otherwise =
      let nf1 = discToFields d1
          nf2 = discToFields d2
      in NTFields (intersectFields nf1 nf2)
intersectNT (NTDISC d) (NTFields nf) =
  let merged = Map.map (\v -> intersectFields v nf) (discMapping d)
      alive  = Map.filter (not . isNeverFields) merged
  in if Map.null alive then ntNever else NTDISC d { discMapping = alive }
intersectNT (NTFields nf) (NTDISC d) = intersectNT (NTDISC d) (NTFields nf)
intersectNT (NTFields f1) (NTFields f2) = NTFields (intersectFields f1 f2)

intersectFields :: NormalFields -> NormalFields -> NormalFields
intersectFields f1 f2 =
  let result = NormalFields
        { nfNull    = nfNull f1 && nfNull f2
        , nfBoolean = intersectBool (nfBoolean f1) (nfBoolean f2)
        , nfNumeric = intersectNumeric (nfNumeric f1) (nfNumeric f2)
        , nfString  = intersectString (nfString f1) (nfString f2)
        , nfArray   = intersectArr (nfArray f1) (nfArray f2)
        , nfObject  = intersectObj (nfObject f1) (nfObject f2)
        }
  in result

intersectBool :: Maybe BoolKind -> Maybe BoolKind -> Maybe BoolKind
intersectBool Nothing  _        = Nothing
intersectBool _        Nothing  = Nothing
intersectBool (Just BoolFull) b = b
intersectBool b (Just BoolFull) = b
intersectBool (Just (BoolLits s1)) (Just (BoolLits s2)) =
  let s = Set.intersection s1 s2
  in if Set.null s then Nothing else Just (BoolLits s)

intersectNumeric :: Maybe NumericKind -> Maybe NumericKind -> Maybe NumericKind
intersectNumeric Nothing _ = Nothing
intersectNumeric _ Nothing = Nothing
intersectNumeric (Just n1) (Just n2) =
  let ip = intersectIntPart (nkInt n1) (nkInt n2)
      np = intersectNumPart (nkNum n1) (nkNum n2)
      nk = NumericKind ip np
  in if isNeverNumeric nk then Nothing else Just nk

intersectIntPart :: IntPart -> IntPart -> IntPart
intersectIntPart IntFull b                = b
intersectIntPart b       IntFull          = b
intersectIntPart IntAbsent _              = IntAbsent
intersectIntPart _ IntAbsent              = IntAbsent
intersectIntPart (IntLits s1) (IntLits s2) =
  let s = Set.intersection s1 s2
  in if Set.null s then IntAbsent else IntLits s

intersectNumPart :: NumPart -> NumPart -> NumPart
intersectNumPart NumFull b               = b
intersectNumPart b       NumFull         = b
intersectNumPart NumAbsent _             = NumAbsent
intersectNumPart _ NumAbsent             = NumAbsent
intersectNumPart (NumLits s1) (NumLits s2) =
  let s = Set.intersection s1 s2
  in if Set.null s then NumAbsent else NumLits s

intersectString :: Maybe StringKind -> Maybe StringKind -> Maybe StringKind
intersectString Nothing _ = Nothing
intersectString _ Nothing = Nothing
intersectString (Just StringFull) b = b
intersectString b (Just StringFull) = b
intersectString (Just (StringLits s1)) (Just (StringLits s2)) =
  let s = Set.intersection s1 s2
  in if Set.null s then Nothing else Just (StringLits s)

intersectArr :: Maybe NormalizedType -> Maybe NormalizedType -> Maybe NormalizedType
intersectArr Nothing _ = Nothing
intersectArr _ Nothing = Nothing
intersectArr (Just t1) (Just t2) = Just (intersectNT t1 t2)

intersectObj :: Maybe ObjectFields -> Maybe ObjectFields -> Maybe ObjectFields
intersectObj Nothing b = b
intersectObj b Nothing = b
intersectObj (Just o1) (Just o2) =
  let -- All fields from both, common fields get intersected
      merged = Map.unionWith mergeCommon (ofFields o1) (ofFields o2)
      -- For common fields, also check optional
      common = Map.intersectionWith mergeCommon (ofFields o1) (ofFields o2)
      onlyIn1 = Map.difference (ofFields o1) (ofFields o2)
      onlyIn2 = Map.difference (ofFields o2) (ofFields o1)
      all_ = Map.unions [common, onlyIn1, onlyIn2]
      -- If any required field is never, the whole object is never
      neverProp = any (\fi -> not (fiOptional fi) && isNeverNT (fiType fi)) (Map.elems all_)
  in if neverProp
     then Nothing  -- propagate never
     else Just (ObjectFields all_)
  where
    mergeCommon fi1 fi2 = FieldInfo
      { fiType     = intersectNT (fiType fi1) (fiType fi2)
      , fiOptional = fiOptional fi1 && fiOptional fi2
      }

-- ---------------------------------------------------------------------------
-- Subtyping
-- ---------------------------------------------------------------------------

subtypeNT :: NormalizedType -> NormalizedType -> Bool
subtypeNT _          NTUnknown = True
subtypeNT NTUnknown  _         = False   -- Unknown <: T only if T = Unknown
subtypeNT (NTDISC d) (NTDISC d2)
  | discField d == discField d2 =
      all (\(k, nf) -> case Map.lookup k (discMapping d2) of
             Just nf2 -> subtypeFieldsNT nf nf2
             Nothing  -> False)
          (Map.toList (discMapping d))
  | otherwise =
      let nf = discToFields d
      in subtypeFieldsNT nf (discToFields d2)
subtypeNT (NTDISC d) (NTFields nf2) =
  all (`subtypeFieldsNT` nf2) (Map.elems (discMapping d))
subtypeNT (NTFields nf) (NTDISC d) =
  any (subtypeFieldsNT nf) (Map.elems (discMapping d))
subtypeNT (NTFields f1) (NTFields f2) = subtypeFieldsNT f1 f2

subtypeFieldsNT :: NormalFields -> NormalFields -> Bool
subtypeFieldsNT f1 f2 =
  subtypeNull  (nfNull f1)    (nfNull f2)    &&
  subtypeBool  (nfBoolean f1) (nfBoolean f2) &&
  subtypeNum   (nfNumeric f1) (nfNumeric f2) &&
  subtypeStr   (nfString f1)  (nfString f2)  &&
  subtypeArr   (nfArray f1)   (nfArray f2)   &&
  subtypeObj   (nfObject f1)  (nfObject f2)

subtypeNull :: Bool -> Bool -> Bool
subtypeNull True False = False
subtypeNull _    _     = True

subtypeBool :: Maybe BoolKind -> Maybe BoolKind -> Bool
subtypeBool Nothing  _       = True   -- never <: anything
subtypeBool _        Nothing  = False
subtypeBool (Just BoolFull) (Just BoolFull) = True
subtypeBool (Just BoolFull) _              = False
subtypeBool (Just (BoolLits s1)) (Just BoolFull)        = True
subtypeBool (Just (BoolLits s1)) (Just (BoolLits s2))  = Set.isSubsetOf s1 s2

subtypeNum :: Maybe NumericKind -> Maybe NumericKind -> Bool
subtypeNum Nothing _  = True
subtypeNum _  Nothing = False
subtypeNum (Just n1) (Just n2) =
  subtypeIntInNum (nkInt n1) n2 &&
  subtypeNumPart  (nkNum n1)  (nkNum n2)

-- Integer subtype check: integers can be in intPart OR numPart of target
subtypeIntInNum :: IntPart -> NumericKind -> Bool
subtypeIntInNum IntAbsent _  = True
subtypeIntInNum IntFull   n2 = nkInt n2 == IntFull || nkNum n2 == NumFull
subtypeIntInNum (IntLits s) n2 =
  case nkInt n2 of
    IntFull      -> True
    IntLits s2   -> Set.isSubsetOf s s2
    IntAbsent    -> case nkNum n2 of
                      NumFull -> True
                      _       -> False  -- can't check individual ints against float lits

subtypeNumPart :: NumPart -> NumPart -> Bool
subtypeNumPart NumAbsent _       = True
subtypeNumPart _         NumAbsent = False
subtypeNumPart NumFull   NumFull  = True
subtypeNumPart NumFull   _        = False
subtypeNumPart _         NumFull  = True
subtypeNumPart (NumLits s1) (NumLits s2) = Set.isSubsetOf s1 s2

subtypeStr :: Maybe StringKind -> Maybe StringKind -> Bool
subtypeStr Nothing _ = True
subtypeStr _ Nothing = False
subtypeStr (Just StringFull) (Just StringFull) = True
subtypeStr (Just StringFull) _ = False
subtypeStr (Just (StringLits s1)) (Just StringFull) = True
subtypeStr (Just (StringLits s1)) (Just (StringLits s2)) = Set.isSubsetOf s1 s2

subtypeArr :: Maybe NormalizedType -> Maybe NormalizedType -> Bool
subtypeArr Nothing _ = True
subtypeArr _ Nothing = False
subtypeArr (Just t1) (Just t2) = subtypeNT t1 t2

subtypeObj :: Maybe ObjectFields -> Maybe ObjectFields -> Bool
subtypeObj Nothing _ = True
subtypeObj _ Nothing = False
subtypeObj (Just o1) (Just o2) =
  -- For every field in o2, it must be in o1 with compatible type
  all checkField (Map.toList (ofFields o2))
  where
    checkField (name, fi2) =
      case Map.lookup name (ofFields o1) of
        Nothing  -> False
        Just fi1 ->
          subtypeNT (fiType fi1) (fiType fi2) &&
          (fiOptional fi2 || not (fiOptional fi1))

-- ---------------------------------------------------------------------------
-- Subtraction (for exhaustiveness checking)
-- ---------------------------------------------------------------------------

subtractNT :: NormalizedType -> NormalizedType -> NormalizedType
subtractNT _ NTUnknown = ntNever
subtractNT NTUnknown _ = NTUnknown
subtractNT (NTDISC d1) (NTDISC d2)
  | discField d1 == discField d2 =
      let mapping' = Map.mapWithKey subtractVariant (discMapping d1)
          subtractVariant k nf =
            case Map.lookup k (discMapping d2) of
              Nothing  -> nf
              Just nf2 -> subtractFields nf nf2
          alive = Map.filter (not . isNeverFields) mapping'
      in if Map.null alive then ntNever else NTDISC d1 { discMapping = alive }
  | otherwise =
      let nf1 = discToFields d1
          nf2 = discToFields d2
      in NTFields (subtractFields nf1 nf2)
subtractNT (NTDISC d) (NTFields nf2) =
  let nf1 = discToFields d
  in NTFields (subtractFields nf1 nf2)
subtractNT (NTFields nf1) (NTDISC d) =
  let nf2 = discToFields d
  in NTFields (subtractFields nf1 nf2)
subtractNT (NTFields f1) (NTFields f2) = NTFields (subtractFields f1 f2)

subtractFields :: NormalFields -> NormalFields -> NormalFields
subtractFields f1 f2 = NormalFields
  { nfNull    = if nfNull f2 then False else nfNull f1
  , nfBoolean = subtractBool (nfBoolean f1) (nfBoolean f2)
  , nfNumeric = subtractNum  (nfNumeric f1) (nfNumeric f2)
  , nfString  = subtractStr  (nfString f1)  (nfString f2)
  , nfArray   = subtractArrField (nfArray f1) (nfArray f2)
  , nfObject  = subtractObjField (nfObject f1) (nfObject f2)
  }

subtractBool :: Maybe BoolKind -> Maybe BoolKind -> Maybe BoolKind
subtractBool Nothing _ = Nothing
subtractBool b Nothing = b
subtractBool (Just BoolFull) (Just BoolFull) = Nothing
subtractBool (Just BoolFull) (Just (BoolLits s)) =
  let remaining = Set.difference (Set.fromList [True,False]) s
  in if Set.null remaining then Nothing else Just (BoolLits remaining)
subtractBool (Just (BoolLits s1)) (Just BoolFull) = Nothing
subtractBool (Just (BoolLits s1)) (Just (BoolLits s2)) =
  let s = Set.difference s1 s2
  in if Set.null s then Nothing else Just (BoolLits s)

subtractNum :: Maybe NumericKind -> Maybe NumericKind -> Maybe NumericKind
subtractNum Nothing _ = Nothing
subtractNum b Nothing = b
subtractNum (Just n1) (Just n2) =
  let ip = subtractIntPart (nkInt n1) (nkInt n2) (nkNum n2)
      np = subtractNumPart (nkNum n1) (nkNum n2)
      nk = NumericKind ip np
  in if isNeverNumeric nk then Nothing else Just nk

-- Integer subtype: if target numPart is Full, integers are consumed
subtractIntPart :: IntPart -> IntPart -> NumPart -> IntPart
subtractIntPart IntAbsent _ _ = IntAbsent
subtractIntPart i IntFull _ = IntAbsent
subtractIntPart i _ NumFull = IntAbsent  -- number includes integers
subtractIntPart IntFull (IntLits _) _ = IntFull  -- conservative
subtractIntPart (IntLits s1) (IntLits s2) _ =
  let s = Set.difference s1 s2
  in if Set.null s then IntAbsent else IntLits s
subtractIntPart i _ _ = i

subtractNumPart :: NumPart -> NumPart -> NumPart
subtractNumPart NumAbsent _ = NumAbsent
subtractNumPart n NumAbsent = n
subtractNumPart NumFull NumFull = NumAbsent
subtractNumPart NumFull (NumLits _) = NumFull  -- conservative
subtractNumPart (NumLits s1) NumFull = NumAbsent
subtractNumPart (NumLits s1) (NumLits s2) =
  let s = Set.difference s1 s2
  in if Set.null s then NumAbsent else NumLits s

subtractStr :: Maybe StringKind -> Maybe StringKind -> Maybe StringKind
subtractStr Nothing _ = Nothing
subtractStr b Nothing = b
subtractStr (Just StringFull) (Just StringFull) = Nothing
subtractStr (Just StringFull) (Just (StringLits _)) = Just StringFull  -- conservative
subtractStr (Just (StringLits s1)) (Just StringFull) = Nothing
subtractStr (Just (StringLits s1)) (Just (StringLits s2)) =
  let s = Set.difference s1 s2
  in if Set.null s then Nothing else Just (StringLits s)

-- Arrays: can't distinguish by element type at runtime → remove all
subtractArrField :: Maybe NormalizedType -> Maybe NormalizedType -> Maybe NormalizedType
subtractArrField Nothing _ = Nothing
subtractArrField a Nothing = a
subtractArrField _ _ = Nothing  -- conservative: array patterns consume all arrays

-- Object subtraction
subtractObjField :: Maybe ObjectFields -> Maybe ObjectFields -> Maybe ObjectFields
subtractObjField Nothing _ = Nothing
subtractObjField o Nothing = o
subtractObjField (Just o1) (Just o2) =
  -- Subtract: if all common fields' types subtract to never, the whole object is never
  let go = map subtractFld (Map.toList (ofFields o2))
      subtractFld (name, fi2) =
        case Map.lookup name (ofFields o1) of
          Nothing  -> Nothing  -- field in pattern not in type, no subtraction
          Just fi1 -> Just (subtractNT (fiType fi1) (fiType fi2))
      results = [r | Just r <- go, not (isNeverNT r)]
  in if null [r | Just r <- go] then Just o1  -- no common fields
     else if all isNeverNT [r | Just r <- go] then Nothing  -- all common fields subtracted to never
     else Just o1  -- conservative: keep

-- ---------------------------------------------------------------------------
-- Pattern type generation
-- ---------------------------------------------------------------------------

patternTypeNT :: Pat -> NormalizedType
patternTypeNT (PVar _)     = NTUnknown
patternTypeNT (PTyped _ t) = normalize t Map.empty
patternTypeNT (PLit lit)   = patternLitType lit
patternTypeNT (PTag tag _) = case tag of
  TagBoolean -> ntBool
  TagInteger -> ntInteger
  TagNumber  -> ntNumber
  TagString  -> ntString
patternTypeNT (PArr _)     =
  NTFields emptyFields { nfArray = Just NTUnknown }
patternTypeNT (PObj fields) =
  -- Check for DISC (exactly one uniq field with literal pattern)
  case [ (name, pat) | (name, True, pat) <- fields ] of
    [(discName, PLit lit)] ->
      let lv = litToLV lit
          objFields = Map.fromList
            [ (n, FieldInfo (patternTypeNT p) False)
            | (n, _, p) <- fields ]
          nf = NormalFields { nfNull = False, nfBoolean = Nothing, nfNumeric = Nothing
                            , nfString = Nothing, nfArray = Nothing
                            , nfObject = Just (ObjectFields objFields) }
      in NTDISC (Discriminator discName (Map.singleton lv nf))
    _ ->
      let objFields = Map.fromList
            [ (n, FieldInfo (patternTypeNT p) False)
            | (n, _, p) <- fields ]
      in NTFields emptyFields { nfObject = Just (ObjectFields objFields) }

patternLitType :: Lit -> NormalizedType
patternLitType LNull      = ntNull
patternLitType (LBool b)  = NTFields emptyFields { nfBoolean = Just (BoolLits (Set.singleton b)) }
patternLitType (LInt  i)  = NTFields emptyFields { nfNumeric = Just (NumericKind (IntLits (Set.singleton i)) NumAbsent) }
patternLitType (LNum  n)  = NTFields emptyFields { nfNumeric = Just (NumericKind IntAbsent (NumLits (Set.singleton n))) }
patternLitType (LStr  s)  = NTFields emptyFields { nfString = Just (StringLits (Set.singleton s)) }

litToLV :: Lit -> LitVal
litToLV (LBool b) = LVBool b
litToLV (LInt  i) = LVInt  i
litToLV (LNum  n) = LVNum  n
litToLV (LStr  s) = LVStr  s
litToLV LNull     = LVStr "null"  -- shouldn't happen for DISC
