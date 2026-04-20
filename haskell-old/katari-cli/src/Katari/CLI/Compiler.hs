module Katari.CLI.Compiler
  ( buildGeOrDie,
    buildOrDie,
    buildAllOrDie,
    buildAgentMetadata,
    buildRequestMetadata,
    buildAliasEndpoints,
    schemasToValue,
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Katari.IR (IRModule (..), NameTable (..))
import Katari.Lowering (LowerError (..), lowerModules)
import Katari.Module (AgentInfo (..), GlobalEnv (..), RequestInfo (..), buildGlobalEnv, primModuleName)
import Katari.Schema (SchemaKind (..), SchemaOutput (..))
import Katari.Syntax (Module)
import Katari.Typechecker (typecheck)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- | Build global env and typecheck modules.
buildGeOrDie :: [Module] -> IO GlobalEnv
buildGeOrDie modules = do
  ge <- case buildGlobalEnv modules of
    Left err -> do
      hPutStrLn stderr ("Module error: " ++ show err)
      exitFailure
    Right ge -> return ge
  case typecheck ge modules of
    Left err -> do
      hPutStrLn stderr ("Type error: " ++ show err)
      exitFailure
    Right () -> return ge

-- | Build global env, typecheck, and lower modules to IR.
buildOrDie :: [Module] -> IO IRModule
buildOrDie modules = snd <$> buildAllOrDie modules

-- | Build global env, typecheck, and lower to IR. Returns both.
buildAllOrDie :: [Module] -> IO (GlobalEnv, IRModule)
buildAllOrDie modules = do
  ge <- buildGeOrDie modules
  case lowerModules ge modules of
    Left (LowerError msg) -> do
      hPutStrLn stderr ("Lowering error: " ++ msg)
      exitFailure
    Right ir -> return (ge, ir)

-- | Build agent metadata: list of { name, block_id, kind, alias? }
--
-- Uses the name table (ntAgents) which contains ALL agent block_ids:
-- internal (user-defined), external (from other servers), and prim (built-in).
buildAgentMetadata :: GlobalEnv -> IRModule -> [Value]
buildAgentMetadata ge irMod =
  [ classify aid name
    | (aid, name) <- Map.toList (ntAgents (irmNameTable irMod))
  ]
  where
    classify aid name = case Map.lookup name (geAgents ge) of
      Just ai
        | aiHomeModule ai == primModuleName ->
            object
              [ "name" .= name,
                "block_id" .= aid,
                "kind" .= ("prim" :: Text)
              ]
        | Just fromStr <- aiExtFrom ai ->
            object
              [ "name" .= name,
                "block_id" .= aid,
                "kind" .= ("external" :: Text),
                "alias" .= fromStr
              ]
        | otherwise ->
            object
              [ "name" .= name,
                "block_id" .= aid,
                "kind" .= ("internal" :: Text)
              ]
      Nothing ->
        object
          [ "name" .= name,
            "block_id" .= aid,
            "kind" .= ("internal" :: Text)
          ]

-- | Build request metadata: list of { name, request_id, kind, alias? }
buildRequestMetadata :: GlobalEnv -> IRModule -> [Value]
buildRequestMetadata ge irMod =
  [ case Map.lookup name (geRequests ge) >>= riExtFrom of
      Nothing ->
        object
          [ "name" .= name,
            "request_id" .= rid,
            "kind" .= ("internal" :: Text)
          ]
      Just fromStr ->
        object
          [ "name" .= name,
            "request_id" .= rid,
            "kind" .= ("external" :: Text),
            "alias" .= fromStr
          ]
    | (rid, name) <- Map.toList (ntRequests (irmNameTable irMod))
  ]

-- | Build alias_endpoints: alias -> endpoint URL from [servers] config
buildAliasEndpoints :: Map Text Text -> Value
buildAliasEndpoints servers =
  Aeson.object [Key.fromText k .= v | (k, v) <- Map.toList servers]

-- | Convert schema outputs to a JSON map:
--   { "module.name": { "kind": "agent"|"request"|"type", "description": "...",
--                       "arg_type": {...}, "return_type": {...}, "with_effects": [...] } }
schemasToValue :: [SchemaOutput] -> Value
schemasToValue outs =
  Aeson.object
    [ Key.fromText (soName o)
        .= object
          ( [ "kind" .= kindText (soKind o),
              "arg_type" .= soArgType o,
              "return_type" .= soReturnType o
            ]
              ++ maybe [] (\d -> ["description" .= d]) (soDescription o)
              ++ if null (soWithEffects o)
                then []
                else ["with_effects" .= soWithEffects o]
          )
      | o <- outs
    ]

kindText :: SchemaKind -> Text
kindText = \case
  SKAgent -> "agent"
  SKRequest -> "request"
  SKType -> "type"
