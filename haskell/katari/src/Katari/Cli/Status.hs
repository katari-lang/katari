-- | @katari status \<agent-id>@ — fetch one agent row and pretty-print
-- its current state, args, and result. The same shape rendered by
-- @katari run --wait@ when an agent finishes, so the two flows feel
-- consistent.
module Katari.Cli.Status
  ( Options (..),
    optionsParser,
    run,
    -- * Reused by Cli.Ls / Cli.Run
    renderAgentDetailed,
    renderResultPreview,
  )
where

import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Encode.Pretty as AesonPretty
import qualified Data.ByteString.Lazy.Char8 as LC8
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
    optApiUrl :: Maybe Text,
    optJson :: Bool
  }

optionsParser :: Parser Options
optionsParser =
  Options
    <$> argument str (metavar "AGENT_ID" <> help "Agent run id (see `katari ls agents`)")
    <*> optional (strOption (long "api-url" <> metavar "URL" <> help "Override [runtime].url"))
    <*> switch (long "json" <> help "Emit raw agent JSON instead of the human-readable view")

run :: Options -> IO ()
run opts = do
  client <- mkClient opts.optApiUrl
  row <- Api.getAgent client opts.optAgentId
  if opts.optJson
    then LC8.putStrLn (AesonPretty.encodePretty row)
    else putStr (Text.unpack (renderAgentDetailed row))

-- ---------------------------------------------------------------------------
-- Formatting
-- ---------------------------------------------------------------------------

-- | Multi-line block describing the entire agent. Trailing newline so
-- callers can append more sections without splicing.
renderAgentDetailed :: Api.AgentRow -> Text
renderAgentDetailed row =
  Text.unlines
    [ "Agent     " <> row.id,
      "Qname     " <> row.qualifiedName,
      "State     " <> renderState row.state,
      "Args      " <> renderJsonOneLine (Aeson.toJSON row.args),
      resultLine row,
      errorLine row,
      "Created   " <> row.createdAt,
      "Updated   " <> row.updatedAt
    ]
  where
    resultLine r = "Result    " <> maybe "(none)" renderJsonOneLine r.result
    errorLine r = case r.errorMessage of
      Just msg -> "Error     " <> msg
      Nothing -> "Error     (none)"

-- | One-line preview suitable for table columns. Truncates long JSON
-- with an ellipsis so list views stay scannable.
renderResultPreview :: Maybe Aeson.Value -> Text
renderResultPreview = \case
  Nothing -> "—"
  Just v ->
    let s = renderJsonOneLine v
        limit = 40 :: Int
     in if Text.length s <= limit
          then s
          else Text.take (limit - 1) s <> "…"

renderState :: Api.AgentState -> Text
renderState = \case
  Api.AgentRunning -> "running"
  Api.AgentCancelling -> "cancelling"
  Api.AgentCancelled -> "cancelled"
  Api.AgentSucceeded -> "succeeded"
  Api.AgentError -> "error"

renderJsonOneLine :: Aeson.Value -> Text
renderJsonOneLine v =
  -- aeson's compact encoding has no trailing newline and uses ":" + " "
  -- after keys, which is the densest single-line form we ship.
  Text.pack (LC8.unpack (Aeson.encode v))

-- ---------------------------------------------------------------------------
-- Client wiring (mirrors Ls/Cancel)
-- ---------------------------------------------------------------------------

mkClient :: Maybe Text -> IO Api.ApiClient
mkClient mOverride = do
  url <- case mOverride of
    Just u -> pure u
    Nothing -> do
      cwd <- getCurrentDirectory
      mRoot <- Project.findProjectRoot cwd
      case mRoot of
        Just root ->
          Project.loadKatariToml (root </> Project.configFilename) >>= \case
            Right cfg -> pure cfg.runtimeSection.runtimeUrl
            Left _ -> die "could not read katari.toml for [runtime].url"
        Nothing -> die "no --api-url and no surrounding katari.toml found"
  auth <- Api.apiAuthFromEnv
  Api.newApiClient url auth

die :: String -> IO a
die msg = do
  hPutStrLn stderr ("katari status: " <> msg)
  exitWith (ExitFailure 2)
