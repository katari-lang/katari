-- | @katari status \<run-id>@ — fetch one run row and pretty-print
-- its current state, args, and result. Same shape rendered by
-- @katari run --wait@ when a run finishes, so the two flows feel
-- consistent.
module Katari.Cli.Status
  ( Options (..),
    optionsParser,
    run,
    -- * Reused by Cli.Ls / Cli.Run
    renderRunDetailed,
    renderResultPreview,
  )
where

import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Encode.Pretty as AesonPretty
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Lazy.Char8 as LC8
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Text.Encoding (decodeUtf8)
import qualified Katari.Api.Client as Api
import qualified Katari.Api.Types as Api
import Katari.Cli.Common (resolveApiClient)
import Options.Applicative

data Options = Options
  { optRunId :: Text,
    optApiUrl :: Maybe Text,
    optJson :: Bool
  }

optionsParser :: Parser Options
optionsParser =
  Options
    <$> argument str (metavar "RUN_ID" <> help "Run id (see `katari ls runs`)")
    <*> optional (strOption (long "api-url" <> metavar "URL" <> help "Override [runtime].url"))
    <*> switch (long "json" <> help "Emit raw run JSON instead of the human-readable view")

run :: Options -> IO ()
run opts = do
  client <- resolveApiClient "status" opts.optApiUrl
  row <- Api.getRun client opts.optRunId
  if opts.optJson
    then LC8.putStrLn (AesonPretty.encodePretty row)
    else putStr (Text.unpack (renderRunDetailed row))

-- ---------------------------------------------------------------------------
-- Formatting
-- ---------------------------------------------------------------------------

-- | Multi-line block describing the entire run. Trailing newline so
-- callers can append more sections without splicing.
renderRunDetailed :: Api.RunRow -> Text
renderRunDetailed row =
  Text.unlines
    [ "Run       " <> row.id,
      "Name      " <> maybe "(unnamed)" id row.name,
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

renderState :: Api.RunState -> Text
renderState = \case
  Api.RunRunning -> "running"
  Api.RunCancelling -> "cancelling"
  Api.RunCancelled -> "cancelled"
  Api.RunSucceeded -> "succeeded"
  Api.RunError -> "error"

renderJsonOneLine :: Aeson.Value -> Text
renderJsonOneLine v = decodeUtf8 (LBS.toStrict (Aeson.encode v))
