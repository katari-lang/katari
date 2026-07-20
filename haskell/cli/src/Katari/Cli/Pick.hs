-- | Resolving "which run / which escalation" from partial input — the shared front half of
-- @status@, @cancel@ and @answer@. An explicit argument may be a unique id prefix (resolved against
-- a generous listing, not a display page); an omitted argument becomes an interactive picker on a
-- terminal and a specific exit-2 error otherwise.
module Katari.Cli.Pick
  ( resolveRunId,
    resolveEscalation,
  )
where

import Control.Exception (throwIO, try)
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as Text
import Katari.Cli.Api
  ( EscalationPresentation (..),
    EscalationView (..),
    RunDetail (..),
    RunListQuery (..),
    RuntimeError (..),
    getRun,
    listEscalations,
    listRuns,
    oauthTargetDescription,
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
  Just candidate -> do
    -- A complete id resolves straight against the runtime's per-id endpoint, so a valid full id
    -- always works no matter how much run history has piled up (the listing below is capped). A
    -- prefix — or an unknown id — misses that lookup and falls through to prefix resolution over the
    -- most recent runs.
    directHit <- runExists context candidate
    if directHit
      then pure candidate
      else do
        (_, runs) <- listRuns context.client context.projectId RunListQuery {state = Nothing, limit = Just prefixResolutionLimit}
        either (dieIn subcommand . renderPrefixError candidate) pure (resolveIdPrefix candidate (map (\run -> run.id) runs))
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

-- | Does the runtime hold a run with exactly this id? A 4xx (a missing run, or an id the runtime
-- rejects as malformed — which a short prefix is) answers no, so the caller can fall back to prefix
-- resolution; a network or server failure still propagates rather than being read as "not found".
runExists :: RuntimeContext -> Text -> IO Bool
runExists context candidate = do
  result <- try (getRun context.client context.projectId candidate)
  case result of
    Right _ -> pure True
    Left (RuntimeHttpError status _) | status >= 400 && status < 500 -> pure False
    Left other -> throwIO other

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

-- | A picker row. The middle two columns render per presentation kind: an oauth escalation names the
-- OAuth authorization and the server / credential it needs, a form escalation shows its request and a
-- truncated question preview.
escalationLabel :: EscalationView -> Text
escalationLabel escalation =
  Text.intercalate "  " ([Text.take 8 escalation.id] <> descriptor <> [compactTimestamp escalation.createdAt])
  where
    descriptor = case escalation.presentation of
      PresentationOauth {url, name} -> ["OAuth authorization", oauthTargetDescription url name]
      PresentationForm _ -> [escalation.request, previewArgument escalation.argument]

-- | The question, compact and truncated so one bulky argument does not wreck the picker layout.
previewArgument :: Maybe Aeson.Value -> Text
previewArgument = \case
  Nothing -> ""
  Just value ->
    let rendered = compactJson value
     in if Text.length rendered > 40 then Text.take 37 rendered <> "..." else rendered
