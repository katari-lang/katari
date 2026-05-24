-- | @katari cancel \<runId\>@ — cancel a running run.
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
import Katari.Cli.Common (resolveApiClient)
import Options.Applicative

data Options = Options
  { optRunId :: Text,
    optApiUrl :: Maybe Text
  }
  deriving (Show)

optionsParser :: Parser Options
optionsParser =
  Options
    <$> argument str (metavar "RUN_ID" <> help "Run id to cancel")
    <*> optional (strOption (long "api-url" <> metavar "URL" <> help "Override [runtime].url"))

run :: Options -> IO ()
run opts = do
  client <- resolveApiClient "cancel" opts.optApiUrl
  row <- Api.cancelRun client opts.optRunId
  putStrLn
    ( "Cancelled "
        <> Text.unpack row.id
        <> " ("
        <> Text.unpack row.qualifiedName
        <> ", now "
        <> show row.state
        <> ")"
    )
