module Katari.CLI.Apply
  ( runApply,
  )
where

import Data.Aeson (object, (.=))
import Data.ByteString.Base64 qualified as B64
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Katari.CLI.Api (postApply)
import Katari.CLI.Compiler (buildAllOrDie, buildAgentMetadata, buildRequestMetadata, buildAliasEndpoints, schemasToValue)
import Katari.CLI.Config (loadConfig, resolveRuntimeUrl)
import Katari.CLI.Project (loadProjectOrDie)
import Katari.CLI.Types (ApplyOpts (..), ProjectConfig (..))
import Katari.Emit (emitModule)
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
      agents = buildAgentMetadata ge irModule
      requests = buildRequestMetadata ge irModule
      aliasEndpoints = buildAliasEndpoints (pcServers config)
      schemas = schemasToValue (moduleSchemas ge)
      bodyJson =
        object
          [ "ir_binary" .= TE.decodeUtf8 (B64.encode binary),
            "agents" .= agents,
            "requests" .= requests,
            "alias_endpoints" .= aliasEndpoints,
            "schemas" .= schemas
          ]
  result <- postApply runtimeUrl bodyJson
  case result of
    Left err -> do
      hPutStrLn stderr ("Apply failed: " ++ show err)
      exitFailure
    Right _ -> putStrLn ("Applied to " ++ T.unpack runtimeUrl)
