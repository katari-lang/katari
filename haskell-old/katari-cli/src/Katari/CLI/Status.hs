module Katari.CLI.Status
  ( runStatus,
  )
where

import Data.Aeson (Value (..))
import Data.Aeson.Types (Parser, parseEither, withObject, (.:), (.:?))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Katari.CLI.Api (listAgents)
import Katari.CLI.Config (resolveRuntimeUrlFromCwd)
import Katari.CLI.Types (StatusOpts (..))
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

runStatus :: StatusOpts -> IO ()
runStatus StatusOpts {..} = do
  runtimeUrl <- resolveRuntimeUrlFromCwd stRuntimeUrl
  result <- listAgents runtimeUrl
  case result of
    Left err -> do
      hPutStrLn stderr ("Failed to fetch agents: " ++ show err)
      exitFailure
    Right val -> printAgentTable val

data AgentRow = AgentRow
  { arId :: Text,
    arName :: Text,
    arStatus :: Text,
    arStartedAt :: Text
  }

printAgentTable :: Value -> IO ()
printAgentTable val = case parseEither parseRows val of
  Left _ -> putStrLn "No agents found"
  Right rows
    | null rows -> putStrLn "No agents"
    | otherwise -> do
        putStrLn $ padR 38 "ID" ++ padR 20 "AGENT" ++ padR 12 "STATUS" ++ "STARTED"
        putStrLn (replicate 80 '-')
        mapM_ printRow rows
  where
    parseRows = withObject "root" $ \o -> do
      agents <- o .: "agents" :: Parser [Value]
      mapM parseAgent agents
    parseAgent = withObject "agent" $ \o ->
      AgentRow
        <$> o .: "id"
        <*> o .: "agentDefName"
        <*> o .: "status"
        <*> (fromMaybe "-" <$> o .:? "startedAt")
    printRow AgentRow {..} =
      putStrLn $
        padR 38 (T.unpack arId)
          ++ padR 20 (T.unpack arName)
          ++ padR 12 (T.unpack arStatus)
          ++ T.unpack arStartedAt

padR :: Int -> String -> String
padR n s
  | length s >= n = take n s
  | otherwise = s ++ replicate (n - length s) ' '
