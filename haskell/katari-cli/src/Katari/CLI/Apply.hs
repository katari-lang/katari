module Katari.CLI.Apply
  ( runApply,
  )
where

import Data.Aeson (object, (.=))
import Data.ByteString.Base64 qualified as B64
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Katari.CLI.Api (postApply)
import Katari.CLI.Compiler (agentSchemasObject, buildAllOrDie, buildExternalAgents)
import Katari.CLI.Config (loadConfig, resolveRuntimeUrl)
import Katari.CLI.Project (loadProjectOrDie)
import Katari.CLI.Types (ApplyOpts (..), ProjectConfig (..))
import Katari.Emit (emitModule)
import Katari.IR (IRAgentDef (..), IRModule (..))
import Katari.Schema (moduleSchemas)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

runApply :: ApplyOpts -> IO ()
runApply ApplyOpts {..} = do
  let root = fromMaybe "." aoDir
  config <- loadConfig root
  let runtimeUrl = resolveRuntimeUrl aoRuntimeUrl config
  modules <- loadProjectOrDie root
  (ge, irModule) <- buildAllOrDie modules
  let binary = emitModule irModule
      agentMap =
        Map.fromList
          [(iadName a, fromIntegral @_ @Int (iadId a)) | a <- irmAgents irModule]
      schemas = agentSchemasObject (moduleSchemas ge)
      extAgents = buildExternalAgents (irmAgents irModule) (pcServers config)
      bodyJson =
        object
          [ "ir_binary" .= TE.decodeUtf8 (B64.encode binary),
            "agents" .= agentMap,
            "schemas" .= schemas,
            "servers" .= pcServers config,
            "external_agents" .= extAgents
          ]
  result <- postApply runtimeUrl bodyJson
  case result of
    Left err -> do
      hPutStrLn stderr ("Apply failed: " ++ show err)
      exitFailure
    Right _ -> putStrLn ("Applied to " ++ T.unpack runtimeUrl)
