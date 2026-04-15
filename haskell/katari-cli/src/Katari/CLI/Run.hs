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
import Katari.CLI.Interactive (promptParam, selectFromList)
import Katari.CLI.Types (RunOpts (..))
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

runRun :: RunOpts -> IO ()
runRun RunOpts {..} = do
  runtimeUrl <- resolveRuntimeUrlFromCwd roRuntimeUrl

  -- Fetch agent defs from runtime
  defsResult <- getSchemaAgents runtimeUrl
  defs <- case defsResult of
    Left err -> do
      hPutStrLn stderr ("Failed to fetch agents: " ++ show err)
      exitFailure
    Right val -> return (parseAgentDefs val)

  when (null defs) $ do
    hPutStrLn stderr "No agents available"
    exitFailure

  -- Select agent
  (agentName, argType) <- case roAgentName of
    Just name -> do
      let t = T.pack name
      case lookup t [(adName d, (adName d, adArgType d)) | d <- defs] of
        Just pair -> return pair
        Nothing -> do
          hPutStrLn stderr ("Agent not found: " ++ name)
          exitFailure
    Nothing -> do
      selection <- selectFromList "Select an agent:" [(adName d, adName d) | d <- defs]
      case selection of
        Nothing -> do
          hPutStrLn stderr "Cancelled"
          exitFailure
        Just name ->
          case lookup name [(adName d, (adName d, adArgType d)) | d <- defs] of
            Just pair -> return pair
            Nothing -> do
              hPutStrLn stderr "Agent not found"
              exitFailure

  -- Build args
  args <- case roInputJson of
    Just jsonStr -> case Aeson.decode (BLC.pack jsonStr) of
      Just v -> return v
      Nothing -> do
        hPutStrLn stderr "Invalid JSON input"
        exitFailure
    Nothing -> promptArgs argType

  let body = object ["agent_name" .= agentName, "args" .= args]
  result <- createAgent runtimeUrl body
  case result of
    Left err -> do
      hPutStrLn stderr ("Failed: " ++ show err)
      exitFailure
    Right val -> do
      putStrLn ("Agent started: " ++ showField "agent_id" val)
      putStrLn ("Status: " ++ showField "status" val)

-- | Agent def info parsed from /katari/agent_def
data AgentDef = AgentDef
  { adName :: Text,
    adArgType :: Value -- JSON Schema for args
  }

parseAgentDefs :: Value -> [AgentDef]
parseAgentDefs = \case
  Array arr -> [ad | Just ad <- map parseOne (foldr (:) [] arr)]
  _ -> []
  where
    parseOne = \case
      Object o -> do
        String name <- KM.lookup "name" o
        let argType = maybe Null id (KM.lookup "input_schema" o)
        Just (AgentDef name argType)
      _ -> Nothing

-- | Prompt for each property in the arg_type schema
promptArgs :: Value -> IO Value
promptArgs argType = case argType of
  Object o
    | Just (Object props) <- KM.lookup "properties" o -> do
        pairs <- mapM promptProp (KM.toList props)
        return (object pairs)
  _ -> return (object [])
  where
    promptProp (key, schema) = do
      let name = Key.toText key
          desc = case schema of
            Object so -> case KM.lookup "description" so of
              Just (String d) -> d
              _ -> ""
            _ -> ""
      input <- promptParam name desc
      let val = case Aeson.decode (BLC.pack (T.unpack input)) of
            Just v -> v
            Nothing -> String input -- Treat as string if not valid JSON
      return (key .= (val :: Value))

when :: Bool -> IO () -> IO ()
when True a = a
when False _ = return ()

showField :: Text -> Value -> String
showField key = \case
  Object obj -> case KM.lookup (Key.fromText key) obj of
    Just (String t) -> T.unpack t
    Just (Number n) -> show n
    Just v -> BLC.unpack (Aeson.encode v)
    Nothing -> "?"
  _ -> "?"
