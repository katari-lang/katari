module Katari.CLI.Stop
  ( runStop,
  )
where

import Data.Aeson (Value (..))
import Data.Aeson.Types (Parser, parseEither, withObject, (.:))
import Data.Text (Text)
import Data.Text qualified as T
import Katari.CLI.Api (listAgents, stopAgent)
import Katari.CLI.Config (resolveRuntimeUrlFromCwd)
import Katari.CLI.Interactive (selectFromList)
import Katari.CLI.Types (StopOpts (..))
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

runStop :: StopOpts -> IO ()
runStop StopOpts {..} = do
  runtimeUrl <- resolveRuntimeUrlFromCwd soRuntimeUrl
  agentId <- case soAgentId of
    Just aid -> return (T.pack aid)
    Nothing -> selectRunningAgent runtimeUrl
  result <- stopAgent runtimeUrl agentId
  case result of
    Left err -> do
      hPutStrLn stderr ("Failed: " ++ show err)
      exitFailure
    Right _ -> putStrLn ("Stopped agent: " ++ T.unpack agentId)

selectRunningAgent :: Text -> IO Text
selectRunningAgent runtimeUrl = do
  result <- listAgents runtimeUrl
  case result of
    Left err -> do
      hPutStrLn stderr ("Failed to fetch agents: " ++ show err)
      exitFailure
    Right val -> do
      let agents = parseAgentRows "running" val
      if null agents
        then do
          hPutStrLn stderr "No running agents"
          exitFailure
        else do
          selection <- selectFromList "Select an agent to stop:" agents
          case selection of
            Nothing -> do
              hPutStrLn stderr "Cancelled"
              exitFailure
            Just aid -> return aid

-- | Parse agent rows from GET /agents response, optionally filtering by status.
parseAgentRows :: Text -> Value -> [(Text, Text)]
parseAgentRows statusFilter val = case parseEither parser val of
  Left _ -> []
  Right rows -> rows
  where
    parser = withObject "root" $ \o -> do
      agents <- o .: "agents" :: Parser [Value]
      rows <- mapM parseRow agents
      return [r | Just r <- rows]
    parseRow = withObject "agent" $ \o -> do
      aid <- o .: "id" :: Parser Text
      name <- o .: "agentDefName" :: Parser Text
      status <- o .: "status" :: Parser Text
      if status == statusFilter
        then return (Just (aid <> " (" <> name <> ")", aid))
        else return Nothing
