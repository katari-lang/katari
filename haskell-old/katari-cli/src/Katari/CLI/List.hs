module Katari.CLI.List
  ( runList,
  )
where

import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KM
import Data.Text (Text)
import Data.Text qualified as T
import Katari.CLI.Api (getSchemaAgents)
import Katari.CLI.Config (resolveRuntimeUrlFromCwd)
import Katari.CLI.Types (ListOpts (..))
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

runList :: ListOpts -> IO ()
runList ListOpts {..} = do
  runtimeUrl <- resolveRuntimeUrlFromCwd liRuntimeUrl
  result <- getSchemaAgents runtimeUrl
  case result of
    Left err -> do
      hPutStrLn stderr ("Failed to fetch agent defs: " ++ show err)
      exitFailure
    Right val -> printAgentDefs val

data AgentDefRow = AgentDefRow
  { adId :: Text,
    adName :: Text,
    adDesc :: Text
  }

printAgentDefs :: Value -> IO ()
printAgentDefs val = case val of
  Array arr -> do
    let rows = [parseRow o | Object o <- foldr (:) [] arr]
    if null rows
      then putStrLn "No agent definitions"
      else do
        putStrLn $ padR 8 "ID" ++ padR 30 "NAME" ++ "DESCRIPTION"
        putStrLn (replicate 70 '-')
        mapM_ printRow rows
  _ -> putStrLn "No agent definitions"
  where
    parseRow o =
      AgentDefRow
        { adId = textField "id" o,
          adName = textField "name" o,
          adDesc = textField "description" o
        }
    textField k o = case KM.lookup k o of
      Just (String t) -> t
      _ -> ""
    printRow AgentDefRow {..} =
      putStrLn $
        padR 8 (T.unpack adId)
          ++ padR 30 (T.unpack adName)
          ++ T.unpack adDesc

padR :: Int -> String -> String
padR n s
  | length s >= n = take n s
  | otherwise = s ++ replicate (n - length s) ' '
