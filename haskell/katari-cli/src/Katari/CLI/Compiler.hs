module Katari.CLI.Compiler
  ( buildGeOrDie,
    buildOrDie,
    buildAllOrDie,
    buildExternalAgents,
    schemasToValue,
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Katari.IR (IRModule (..), NameTable (..))
import Katari.Lowering (LowerError (..), lowerModules)
import Katari.Module (AgentInfo (..), GlobalEnv (..), buildGlobalEnv)
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

-- | Build the external_agents map:
--   IR agent_id (numeric string) -> { "agent_def_id": remoteName, "agent_def_where": serverUrl }
--
-- Iterates all agents in the name table (which includes external agents),
-- uses the 'aiExtFrom' field ("server_key:remote_name") from GlobalEnv to
-- resolve the server URL via the [servers] config.
buildExternalAgents :: GlobalEnv -> IRModule -> Map Text Text -> Map Text Value
buildExternalAgents ge irMod servers =
  Map.fromList
    [ ( T.pack (show aid),
        object
          [ "agent_def_id" .= remoteName,
            "agent_def_where" .= serverUrl
          ]
      )
      | (aid, name) <- Map.toList (ntAgents (irmNameTable irMod)),
        Just ai <- [Map.lookup name (geAgents ge)],
        Just fromStr <- [aiExtFrom ai],
        let (serverKey, rest) = T.breakOn ":" fromStr,
        not (T.null rest),
        let remoteName = T.drop 1 rest,
        Just serverUrl <- [Map.lookup serverKey servers]
    ]

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
