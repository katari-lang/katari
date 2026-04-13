module Katari.CLI.Run
  ( runRun,
  )
where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy.Char8 qualified as BLC
import Data.Text (Text)
import Data.Text qualified as T
import Katari.CLI.Api (createAgent, getSchemaAgents)
import Katari.CLI.Config (resolveRuntimeUrlFromCwd)
import Katari.CLI.Interactive (selectFromList)
import Katari.CLI.Types (RunOpts (..))
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

runRun :: RunOpts -> IO ()
runRun RunOpts {..} = do
  runtimeUrl <- resolveRuntimeUrlFromCwd roRuntimeUrl
  agentName <- case roAgentName of
    Just name -> return (T.pack name)
    Nothing -> selectAgent runtimeUrl
  let args :: Maybe Value
      args = roInputJson >>= Aeson.decode . BLC.pack
      body =
        object $
          ["agent_name" .= agentName]
            ++ maybe [] (\a -> ["args" .= a]) args
  result <- createAgent runtimeUrl body
  case result of
    Left err -> do
      hPutStrLn stderr ("Failed: " ++ show err)
      exitFailure
    Right val -> do
      putStrLn ("Agent started: " ++ showField "agent_id" val)
      putStrLn ("Status: " ++ showField "status" val)

selectAgent :: Text -> IO Text
selectAgent runtimeUrl = do
  result <- getSchemaAgents runtimeUrl
  case result of
    Left err -> do
      hPutStrLn stderr ("Failed to fetch agents: " ++ show err)
      exitFailure
    Right val -> do
      let agents = parseAgentNames val
      if null agents
        then do
          hPutStrLn stderr "No agents available"
          exitFailure
        else do
          selection <- selectFromList "Select an agent:" [(n, n) | n <- agents]
          case selection of
            Nothing -> do
              hPutStrLn stderr "Cancelled"
              exitFailure
            Just name -> return name

parseAgentNames :: Value -> [Text]
parseAgentNames val = case val of
  Array arr -> [n | Object o <- toList arr, String n <- maybe [] pure (KM.lookup "name" o)]
  _ -> []
  where
    toList = foldr (:) []

showField :: Text -> Value -> String
showField key val = case val of
  Object obj -> case KM.lookup (Key.fromText key) obj of
    Just (String t) -> T.unpack t
    Just (Number n) -> show n
    Just v -> BLC.unpack (Aeson.encode v)
    Nothing -> "?"
  _ -> "?"
