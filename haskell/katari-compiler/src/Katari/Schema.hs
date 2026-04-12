module Katari.Schema
  ( SchemaKind (..),
    SchemaOutput (..),
    moduleSchemas,
    typeAliasSchema,
    typeToSchema,
    normalizedToSchema,
    encodeSchema,
  )
where

import Data.Aeson
  ( KeyValue (..),
    Value (..),
    encode,
    object,
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy (ByteString)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Katari.Module
  ( AgentInfo (..),
    GlobalEnv (..),
    RequestInfo (..),
    TypeInfo,
    aliasesFor,
    primModuleName,
  )
import Katari.Syntax (ObjField (..), RequestEffect (..), Type (..))
import Katari.Types
  ( BoolKind (..),
    Discriminator (..),
    FieldInfo (..),
    IntPart (..),
    NormalFields (..),
    NormalizedType (..),
    NumPart (..),
    NumericKind (..),
    ObjectFields (..),
    StringKind (..),
    boolFull,
    normalize,
  )

-- ----------------------------------------------------------------------------
-- Public API types
-- ----------------------------------------------------------------------------

data SchemaKind = SKAgent | SKRequest | SKType
  deriving (Show, Eq)

data SchemaOutput = SchemaOutput
  { soName :: Text,
    soKind :: SchemaKind,
    soDescription :: Maybe Text,
    soArgType :: Value,
    soReturnType :: Value,
    soWithEffects :: [Text]
  }
  deriving (Show)

-- | Build schemas for every user-defined agent, request and type in the
--   global environment. prim module entries are filtered out.
moduleSchemas :: GlobalEnv -> [SchemaOutput]
moduleSchemas ge =
  let agents =
        [ SchemaOutput
            { soName = qname,
              soKind = SKAgent,
              soDescription = aiAnnot ai,
              soArgType = paramsToInputSchema ge (aiHomeModule ai) (aiParams ai),
              soReturnType = typeToSchema ge (aiHomeModule ai) (aiRet ai),
              soWithEffects = effectNames ge ai
            }
          | (qname, ai) <- Map.toList (geAgents ge),
            not (isPrimQname qname)
        ]
      reqs =
        [ SchemaOutput
            { soName = qname,
              soKind = SKRequest,
              soDescription = riAnnot ri,
              soArgType = paramsToInputSchema ge (riHomeModule ri) (riParams ri),
              soReturnType = typeToSchema ge (riHomeModule ri) (riRet ri),
              soWithEffects = []
            }
          | (qname, ri) <- Map.toList (geRequests ge),
            not (isPrimQname qname)
        ]
      tys =
        [ SchemaOutput
            { soName = qname,
              soKind = SKType,
              soDescription = Nothing,
              soArgType = typeAliasSchema ge qname ti,
              soReturnType = Null,
              soWithEffects = []
            }
          | (qname, ti) <- Map.toList (geTypes ge),
            not (isPrimQname qname)
        ]
   in agents ++ reqs ++ tys

-- | Extract qualified request names from an agent's with clause.
effectNames :: GlobalEnv -> AgentInfo -> [Text]
effectNames ge ai = case aiWith ai of
  Just (RENames ns) ->
    let modAliases = aliasesFor ge (aiHomeModule ai)
     in map (\n -> fromMaybe n (Map.lookup n modAliases)) ns
  _ -> []

isPrimQname :: Text -> Bool
isPrimQname q =
  q == primModuleName
    || (primModuleName <> ".") `T.isPrefixOf` q

-- | Encode a schema Value as a JSON bytestring.
encodeSchema :: Value -> ByteString
encodeSchema = encode

-- ----------------------------------------------------------------------------
-- Type schema generation
-- ----------------------------------------------------------------------------

typeAliasSchema :: GlobalEnv -> Text -> TypeInfo -> Value
typeAliasSchema ge qname _ti =
  case Map.lookup qname (geTypeEnv ge) of
    Just nt -> normalizedToSchema nt
    Nothing -> object []

-- | Build the "input" object schema from a parameter list.
paramsToInputSchema ::
  GlobalEnv ->
  Text ->
  [(Text, Type, Maybe Text)] ->
  Value
paramsToInputSchema ge mname params =
  let propPairs =
        [ ( Key.fromText pname,
            applyDescription pann (typeToSchema ge mname pty)
          )
          | (pname, pty, pann) <- params
        ]
   in object
        [ "type" .= ("object" :: Text),
          "properties" .= object propPairs,
          "required" .= [pname | (pname, _, _) <- params]
        ]

-- | Convert a source-level 'Type' (possibly containing unqualified TAlias
--   references) into a JSON Schema 'Value'. Aliases are resolved via the
--   specified module's alias table.
typeToSchema :: GlobalEnv -> Text -> Type -> Value
typeToSchema ge mname ty =
  let qty = qualifyType ge mname ty
      nt = normalize qty (geTypeEnv ge)
   in normalizedToSchema nt

-- | Walk a 'Type' and rewrite each TAlias to its fully-qualified form using
--   the given module's alias table.
qualifyType :: GlobalEnv -> Text -> Type -> Type
qualifyType ge mname = go
  where
    aliases = aliasesFor ge mname
    go t = case t of
      TNull -> t
      TBoolean -> t
      TInteger -> t
      TNumber -> t
      TString -> t
      TNever -> t
      TUnknown -> t
      TLitBool _ -> t
      TLitInt _ -> t
      TLitNum _ -> t
      TLitStr _ -> t
      TArray inner -> TArray (go inner)
      TUnion ts -> TUnion (map go ts)
      TInter ts -> TInter (map go ts)
      TAlias n -> TAlias (fromMaybe n (Map.lookup n aliases))
      TObj flds -> TObj [f {ofType = go (ofType f)} | f <- flds]

-- ----------------------------------------------------------------------------
-- NormalizedType → JSON Schema Value
-- ----------------------------------------------------------------------------

normalizedToSchema :: NormalizedType -> Value
normalizedToSchema = \case
  NTUnknown -> object []
  NTDISC d -> discSchema d
  NTFields nf -> fieldsSchema nf

discSchema :: Discriminator -> Value
discSchema d =
  let variants =
        [ normalizedToSchema (NTFields nf)
          | nf <- Map.elems (discMapping d)
        ]
   in object
        [ "oneOf" .= variants,
          "discriminator"
            .= object ["propertyName" .= discField d]
        ]

fieldsSchema :: NormalFields -> Value
fieldsSchema nf = case collectParts nf of
  [] -> object ["not" .= object []]
  [single] -> single
  many -> object ["oneOf" .= many]

collectParts :: NormalFields -> [Value]
collectParts NormalFields {..} =
  catMaybes
    [ if nfNull then Just (typeKeyword "null") else Nothing,
      boolSchema <$> nfBoolean,
      numericSchema <$> nfNumeric,
      stringSchema <$> nfString,
      arraySchema <$> nfArray,
      objectSchema <$> nfObject
    ]

typeKeyword :: Text -> Value
typeKeyword t = object ["type" .= t]

boolSchema :: BoolKind -> Value
boolSchema (BoolLits s)
  | s == boolFull = typeKeyword "boolean"
  | otherwise = case Set.toList s of
      [b] -> object ["const" .= b]
      bs -> object ["oneOf" .= [object ["const" .= b] | b <- bs]]

numericSchema :: NumericKind -> Value
numericSchema (NumericKind IntFull NumFull) = typeKeyword "number"
numericSchema (NumericKind IntAbsent NumFull) = typeKeyword "number"
numericSchema (NumericKind IntFull NumAbsent) = typeKeyword "integer"
numericSchema (NumericKind ip np) =
  let intParts = case ip of
        IntAbsent -> []
        IntFull -> [typeKeyword "integer"]
        IntLits s -> [object ["const" .= i] | i <- Set.toList s]
      numParts = case np of
        NumAbsent -> []
        NumFull -> [typeKeyword "number"]
        NumLits s -> [object ["const" .= n] | n <- Set.toList s]
      parts = intParts ++ numParts
   in case parts of
        [] -> object ["not" .= object []]
        [single] -> single
        _ -> object ["oneOf" .= parts]

stringSchema :: StringKind -> Value
stringSchema StringFull = typeKeyword "string"
stringSchema (StringLits s) = case Set.toList s of
  [x] -> object ["const" .= x]
  xs -> object ["oneOf" .= [object ["const" .= x] | x <- xs]]

arraySchema :: NormalizedType -> Value
arraySchema inner =
  object
    [ "type" .= ("array" :: Text),
      "items" .= normalizedToSchema inner
    ]

objectSchema :: ObjectFields -> Value
objectSchema (ObjectFields flds) =
  let entries = Map.toList flds
      propPairs =
        [ (Key.fromText name, fieldSchema info)
          | (name, info) <- entries
        ]
      requiredNames = [name | (name, info) <- entries, not (fiOptional info)]
   in object
        [ "type" .= ("object" :: Text),
          "properties" .= object propPairs,
          "required" .= requiredNames
        ]

fieldSchema :: FieldInfo -> Value
fieldSchema fi =
  applyDescription (fiAnnot fi) (normalizedToSchema (fiType fi))

-- ----------------------------------------------------------------------------
-- helpers
-- ----------------------------------------------------------------------------

-- | Inject a "description" field into an object schema. If the value is not
--   an object (shouldn't happen in practice), it is returned unchanged.
applyDescription :: Maybe Text -> Value -> Value
applyDescription Nothing v = v
applyDescription (Just desc) (Object o) =
  Object (KM.insert (Key.fromText "description") (String desc) o)
applyDescription (Just _) v = v
