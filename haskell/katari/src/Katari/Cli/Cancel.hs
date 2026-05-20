-- | @katari cancel <agentId>@ — cancel a running agent.
module Katari.Cli.Cancel
  ( Options (..),
    optionsParser,
    run,
  )
where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Katari.Api.Client as Api
import qualified Katari.Api.Types as Api
import qualified Katari.Project.Config as Project
import qualified Katari.Project.Discovery as Project
import Options.Applicative
import System.Directory (getCurrentDirectory)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)

data Options = Options
  { optAgentId :: Text,
    optApiUrl :: Maybe Text
  }
  deriving (Show)

optionsParser :: Parser Options
optionsParser =
  Options
    <$> argument str (metavar "AGENT_ID" <> help "Agent run id to cancel")
    <*> optional (strOption (long "api-url" <> metavar "URL" <> help "Override [runtime].url"))

run :: Options -> IO ()
run opts = do
  url <- case opts.optApiUrl of
    Just u -> pure u
    Nothing -> tryLoadApiUrl
  auth <- Api.apiAuthFromEnv
  client <- Api.newApiClient url auth
  row <- Api.cancelAgent client opts.optAgentId
  putStrLn
    ( "Cancelled "
        <> Text.unpack row.id
        <> " ("
        <> Text.unpack row.qualifiedName
        <> ", now "
        <> show row.state
        <> ")"
    )

tryLoadApiUrl :: IO Text
tryLoadApiUrl = do
  cwd <- getCurrentDirectory
  mRoot <- Project.findProjectRoot cwd
  case mRoot of
    Nothing -> die "no --api-url and no surrounding katari.toml found"
    Just root -> do
      r <- Project.loadKatariToml (root </> Project.configFilename)
      case r of
        Right cfg -> pure cfg.runtimeSection.runtimeUrl
        Left _ -> die "could not read katari.toml for [runtime].url"

die :: String -> IO a
die msg = do
  hPutStrLn stderr ("katari cancel: " <> msg)
  exitWith (ExitFailure 2)
