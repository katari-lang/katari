module Katari.CLI.Compiler
  ( buildGeOrDie,
    buildOrDie,
    buildAllOrDie,
    buildExternalAgents,
    schemasToValue,
    agentSchemasObject,
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Katari.IR (IRAgentDef (..), IRModule)
import Katari.Lowering (LowerError (..), lowerModules)
import Katari.Module (GlobalEnv, buildGlobalEnv)
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

-- | Build the external_agents map: agent_def_id -> "server:localName".
-- An agent is external if the first dot-separated component of its name
-- matches a key in the servers config.
buildExternalAgents :: [IRAgentDef] -> Map Text Text -> Map Text Text
buildExternalAgents agents servers =
  Map.fromList
    [ (T.pack (show (iadId a)), serverName <> ":" <> T.drop 1 rest)
      | a <- agents,
        let (prefix, rest) = T.breakOn "." (iadName a),
        not (T.null rest),
        Map.member prefix servers,
        let serverName = prefix
    ]

-- | Convert schema outputs to a JSON value (array of objects).
schemasToValue :: [SchemaOutput] -> Value
schemasToValue outs =
  Aeson.toJSON
    [ object
        [ "name" .= soName o,
          "kind" .= kindText (soKind o),
          "schema" .= soSchema o
        ]
      | o <- outs
    ]

kindText :: SchemaKind -> Text
kindText = \case
  SKAgent -> "agent"
  SKRequest -> "request"
  SKType -> "type"

-- | Build a JSON object mapping agent names to their schemas (for POST /apply).
agentSchemasObject :: [SchemaOutput] -> Value
agentSchemasObject outs =
  Aeson.object
    [ Key.fromText (soName o) .= soSchema o
      | o <- outs,
        soKind o == SKAgent
    ]
