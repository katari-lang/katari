-- | Resolving "which run / which escalation" from partial input — the shared front half of
-- @status@, @cancel@ and @answer@. An explicit argument may be a unique id prefix (resolved against
-- a generous listing, not a display page); an omitted argument becomes an interactive picker on a
-- terminal and a specific exit-2 error otherwise.
module Katari.Cli.Pick
  ( resolveRunId,
    resolveEscalation,
  )
where

import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as Text
import Katari.Cli.Api
  ( EscalationView (..),
    RunDetail (..),
    RunListQuery (..),
    listEscalations,
    listRuns,
  )
import Katari.Cli.Common (RuntimeContext (..), dieIn, renderPrefixError, resolveIdPrefix)
import Katari.Cli.Output (OutputContext (..), compactTimestamp)
import Katari.Cli.Prompt (compactJson, select)

-- | How many candidates an interactive picker shows. Prefix resolution never uses this page size —
-- it resolves against the full fetch below.
pickerPageSize :: Int
pickerPageSize = 20

-- | How many ids a prefix resolves against. Far above any interactive page so a short prefix keeps
-- working as history grows.
prefixResolutionLimit :: Int
prefixResolutionLimit = 500

-- | Resolve the run a command targets. @stateFilter@ narrows the interactive picker (e.g. @cancel@
-- offers only running runs); an explicit prefix resolves against every state.
resolveRunId :: Text -> RuntimeContext -> Maybe Text -> Maybe Text -> IO Text
resolveRunId subcommand context given stateFilter = case given of
  Just prefix -> do
    (_, runs) <- listRuns context.client context.projectId RunListQuery {state = Nothing, limit = Just prefixResolutionLimit}
    either (dieIn subcommand . renderPrefixError prefix) pure (resolveIdPrefix prefix (map (\run -> run.id) runs))
  Nothing
    | context.output.interactive -> do
        (_, runs) <- listRuns context.client context.projectId RunListQuery {state = stateFilter, limit = Just pickerPageSize}
        case runs of
          [] -> dieIn subcommand ("no " <> maybe "" (<> " ") stateFilter <> "runs to pick from")
          _ -> do
            chosen <- select context.output "Which run?" [(runLabel run, run.id) | run <- runs]
            case chosen of
              Just runId -> pure runId
              Nothing -> dieIn subcommand "cancelled"
    | otherwise -> dieIn subcommand "no run id given (pass one, or run interactively)"

runLabel :: RunDetail -> Text
runLabel run =
  Text.intercalate "  " [Text.take 8 run.id, padState run.state, run.qualifiedName, compactTimestamp run.createdAt]
  where
    -- The longest state is `cancelling` (10); padding keeps picker rows scannable.
    padState state = state <> Text.replicate (10 - Text.length state) " "

-- | Resolve the escalation a command targets, returning the full view (the caller needs the question
-- and the answer schema, not just the id).
resolveEscalation :: Text -> RuntimeContext -> Maybe Text -> IO EscalationView
resolveEscalation subcommand context given = do
  (_, escalations) <- listEscalations context.client context.projectId
  case given of
    Just prefix ->
      case resolveIdPrefix prefix (map (\escalation -> escalation.id) escalations) of
        Left prefixError -> dieIn subcommand (renderPrefixError prefix prefixError)
        Right resolved -> case filter (\escalation -> escalation.id == resolved) escalations of
          (found : _) -> pure found
          [] -> dieIn subcommand ("escalation " <> resolved <> " vanished (already answered?)")
    Nothing
      | context.output.interactive -> case escalations of
          [] -> dieIn subcommand "no open escalations"
          _ -> do
            chosen <- select context.output "Answer which escalation?" [(escalationLabel escalation, escalation) | escalation <- escalations]
            case chosen of
              Just escalation -> pure escalation
              Nothing -> dieIn subcommand "cancelled"
      | otherwise -> dieIn subcommand "no escalation id given (pass one, or run interactively)"

escalationLabel :: EscalationView -> Text
escalationLabel escalation =
  Text.intercalate
    "  "
    [ Text.take 8 escalation.id,
      escalation.request,
      previewArgument escalation.argument,
      compactTimestamp escalation.createdAt
    ]

-- | The question, compact and truncated so one bulky argument does not wreck the picker layout.
previewArgument :: Maybe Aeson.Value -> Text
previewArgument = \case
  Nothing -> ""
  Just value ->
    let rendered = compactJson value
     in if Text.length rendered > 40 then Text.take 37 rendered <> "..." else rendered
