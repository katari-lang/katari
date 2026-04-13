module Katari.CLI.Result
  ( runResult,
  )
where

import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.Types (Parser, parseEither, withObject, (.:))
import Data.ByteString.Lazy.Char8 qualified as BLC
import Data.Text (Text)
import Data.Text qualified as T
import Katari.CLI.Api (getAgent, listAgents)
import Katari.CLI.Config (resolveRuntimeUrlFromCwd)
import Katari.CLI.Interactive (selectFromList)
import Katari.CLI.Types (ResultOpts (..))
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

runResult :: ResultOpts -> IO ()
runResult ResultOpts {..} = do
  runtimeUrl <- resolveRuntimeUrlFromCwd reRuntimeUrl
  agentId <- case reAgentId of
    Just aid -> return (T.pack aid)
    Nothing -> selectCompletedAgent runtimeUrl
  result <- getAgent runtimeUrl agentId
  case result of
    Left err -> do
      hPutStrLn stderr ("Failed: " ++ show err)
      exitFailure
    Right val -> do
      putStrLn ("Agent: " ++ T.unpack agentId)
      putStrLn ("Status: " ++ extractField "status" val)
      putStrLn ("Result: " ++ extractField "result" val)

selectCompletedAgent :: Text -> IO Text
selectCompletedAgent runtimeUrl = do
  result <- listAgents runtimeUrl
  case result of
    Left err -> do
      hPutStrLn stderr ("Failed to fetch agents: " ++ show err)
      exitFailure
    Right val -> do
      let agents = parseCompletedAgents val
      if null agents
        then do
          hPutStrLn stderr "No completed agents"
          exitFailure
        else do
          selection <- selectFromList "Select an agent:" agents
          case selection of
            Nothing -> do
              hPutStrLn stderr "Cancelled"
              exitFailure
            Just aid -> return aid

parseCompletedAgents :: Value -> [(Text, Text)]
parseCompletedAgents val = case parseEither parser val of
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
      if status == "completed"
        then return (Just (aid <> " (" <> name <> ")", aid))
        else return Nothing

extractField :: Text -> Value -> String
extractField key val = case parseEither parser val of
  Left _ -> "?"
  Right v -> formatValue v
  where
    parser = withObject "obj" (.: Key.fromText key)
    formatValue = \case
      String t -> T.unpack t
      Number n -> show n
      Null -> "null"
      v -> BLC.unpack (Aeson.encode v)
