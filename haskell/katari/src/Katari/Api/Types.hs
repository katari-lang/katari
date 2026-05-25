-- | Types mirroring the api-server's JSON shapes.
--
-- Single source of truth on the TypeScript side is
-- @typescript/packages/katari-api-server/src/routes@; this module is
-- the Haskell mirror used by 'Katari.Api.Client'. Field names match
-- the wire format (= camelCase) so Aeson's @genericToJSON@ /
-- @genericParseJSON@ produce the right wire format with the default
-- options.
module Katari.Api.Types
  ( -- * Projects
    Project (..),
    UpsertProjectRequest (..),
    UpsertProjectResponse (..),
    ListProjectsResponse (..),
    -- * Snapshots
    SnapshotSummary (..),
    UploadSnapshotRequest (..),
    UploadSnapshotResponse (..),
    SidecarBundle (..),
    -- * Runs (= operator-launched root delegations)
    RunRow (..),
    RunState (..),
    CancelReason (..),
    StartRunRequest (..),
    StartRunResponse (..),
    GetRunResponse (..),
    ListRunsResponse (..),
    CancelRunResponse (..),
    -- * Agent definitions
    AgentDefinition (..),
    ListAgentsResponse (..),
    GetAgentResponse (..),
    -- * Escalations
    EscalationRow (..),
    EscalationState (..),
    ListEscalationsResponse (..),
    AnswerEscalationRequest (..),
    AnswerEscalationResponse (..),
  )
where

import Data.Aeson
  ( FromJSON (..),
    ToJSON (..),
    Value,
    defaultOptions,
    genericParseJSON,
    genericToJSON,
    omitNothingFields,
    withText,
  )
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Generics (Generic)
import Katari.IR (IRModule)

-- ---------------------------------------------------------------------------
-- Projects
-- ---------------------------------------------------------------------------

data Project = Project
  { id :: Text,
    name :: Text,
    -- | One-line summary from @katari.toml@. 'Nothing' = unset.
    description :: Maybe Text,
    -- | Long-form README (markdown). 'Nothing' = no @README.md@ next to
    -- @katari.toml@ at last @apply@ time.
    readme :: Maybe Text,
    createdAt :: Text
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Body for @POST /project@. Name is the identity key; description /
-- readme are reconciler fields that overwrite the runtime row on every
-- @apply@. 'Nothing' on either field = "clear" (so removing a
-- @description@ from @katari.toml@ propagates).
data UpsertProjectRequest = UpsertProjectRequest
  { name :: Text,
    description :: Maybe Text,
    readme :: Maybe Text
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON)

-- | Always include @description@ / @readme@ on the wire — sending
-- @null@ explicitly clears the field, which is the intended semantics
-- of "this field is unset in katari.toml".
instance ToJSON UpsertProjectRequest where
  toJSON = genericToJSON defaultOptions

newtype UpsertProjectResponse = UpsertProjectResponse {project :: Project}
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype ListProjectsResponse = ListProjectsResponse {projects :: [Project]}
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- ---------------------------------------------------------------------------
-- Snapshots
-- ---------------------------------------------------------------------------

data SnapshotSummary = SnapshotSummary
  { id :: Text,
    projectId :: Text,
    -- | Commit-message-like text supplied by the operator on @apply@.
    -- 'Nothing' = no message attached.
    message :: Maybe Text,
    createdAt :: Text
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The sidecar entry bundle produced by @katari-bundle@. The runtime
-- writes @entry@ to a temp file and launches @node@ on it.
data SidecarBundle = SidecarBundle
  { entry :: Text,
    -- runtime is fixed to "node" on the wire — we just hardcode it.
    runtime :: Text,
    schemaVersion :: Int
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data UploadSnapshotRequest = UploadSnapshotRequest
  { irModule :: IRModule,
    sidecarBundle :: Maybe SidecarBundle,
    -- | @{ schemaVersion, agents: [...] }@ — we don't parse it on the
    -- Haskell side beyond round-tripping bytes, so a raw 'Value' is
    -- enough. Built by 'Katari.Cli.Build.buildBundleJson'.
    schemaBundle :: Value,
    -- | Optional operator-supplied commit-message-like text. 'Nothing'
    -- = no message attached (= the server stores @NULL@).
    message :: Maybe Text
  }
  deriving stock (Show, Generic)

instance FromJSON UploadSnapshotRequest where
  parseJSON = genericParseJSON defaultOptions

-- | Drop @message: null@ when 'Nothing' so the api-server's Zod schema
-- accepts an absent field rather than an explicit null.
instance ToJSON UploadSnapshotRequest where
  toJSON = genericToJSON defaultOptions {omitNothingFields = True}

newtype UploadSnapshotResponse = UploadSnapshotResponse
  { snapshotId :: Text
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- ---------------------------------------------------------------------------
-- Runs (= operator-launched root delegations; the "agent" entry point)
-- ---------------------------------------------------------------------------

data RunState
  = RunRunning
  | RunCancelling
  | RunCancelled
  | RunSucceeded
  | RunError
  deriving stock (Show, Eq)

instance FromJSON RunState where
  parseJSON = withText "RunState" $ \t -> case t of
    "running" -> pure RunRunning
    "cancelling" -> pure RunCancelling
    "cancelled" -> pure RunCancelled
    "succeeded" -> pure RunSucceeded
    "error" -> pure RunError
    _ -> fail ("unknown run state: " <> Text.unpack t)

instance ToJSON RunState where
  toJSON = \case
    RunRunning -> "running"
    RunCancelling -> "cancelling"
    RunCancelled -> "cancelled"
    RunSucceeded -> "succeeded"
    RunError -> "error"

data CancelReason
  = CancelReasonUser
  | CancelReasonError
  deriving stock (Show, Eq)

instance FromJSON CancelReason where
  parseJSON = withText "CancelReason" $ \t -> case t of
    "user" -> pure CancelReasonUser
    "error" -> pure CancelReasonError
    _ -> fail ("unknown cancel reason: " <> Text.unpack t)

instance ToJSON CancelReason where
  toJSON = \case
    CancelReasonUser -> "user"
    CancelReasonError -> "error"

-- | One row from the @runs_audit@ table (= persistent operator-facing
-- log). Survives terminal state so @katari status@ can render the
-- post-run result / error.
data RunRow = RunRow
  { id :: Text,
    snapshotId :: Text,
    name :: Maybe Text,
    qualifiedName :: Text,
    args :: Map Text Value,
    state :: RunState,
    cancelReason :: Maybe CancelReason,
    result :: Maybe Value,
    errorMessage :: Maybe Text,
    createdAt :: Text,
    updatedAt :: Text,
    completedAt :: Maybe Text
  }
  deriving stock (Show, Generic)

instance FromJSON RunRow where
  parseJSON = genericParseJSON defaultOptions

instance ToJSON RunRow where
  toJSON = genericToJSON defaultOptions

data StartRunRequest = StartRunRequest
  { projectId :: Text,
    snapshotId :: Maybe Text,
    qualifiedName :: Text,
    -- | Operator-supplied label. 'Nothing' = unnamed run.
    name :: Maybe Text,
    args :: Map Text Value
  }
  deriving stock (Show, Generic)

instance FromJSON StartRunRequest where
  parseJSON = genericParseJSON defaultOptions

-- | Drop @snapshotId: null@ / @name: null@ when 'Nothing' — the
-- api-server's Zod schema accepts these as @optional()@ (absent) but
-- not as @null@ in some shapes.
instance ToJSON StartRunRequest where
  toJSON = genericToJSON defaultOptions {omitNothingFields = True}

newtype StartRunResponse = StartRunResponse
  { runId :: Text
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype GetRunResponse = GetRunResponse
  { run :: RunRow
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype ListRunsResponse = ListRunsResponse
  { runs :: [RunRow]
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype CancelRunResponse = CancelRunResponse
  { run :: RunRow
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- ---------------------------------------------------------------------------
-- Agent definitions
-- ---------------------------------------------------------------------------

data AgentDefinition = AgentDefinition
  { qualifiedName :: Text,
    parameters :: Value,
    returns :: Value,
    description :: Maybe Text
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data ListAgentsResponse = ListAgentsResponse
  { agents :: [AgentDefinition],
    snapshotId :: Text
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data GetAgentResponse = GetAgentResponse
  { agent :: AgentDefinition,
    snapshotId :: Text
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- ---------------------------------------------------------------------------
-- Escalations
-- ---------------------------------------------------------------------------

data EscalationState
  = EscalationOpen
  | EscalationAnswered
  | EscalationCancelled
  deriving stock (Show, Eq)

instance FromJSON EscalationState where
  parseJSON = withText "EscalationState" $ \t -> case t of
    "open" -> pure EscalationOpen
    "answered" -> pure EscalationAnswered
    "cancelled" -> pure EscalationCancelled
    _ -> fail ("unknown escalation state: " <> Text.unpack t)

instance ToJSON EscalationState where
  toJSON = \case
    EscalationOpen -> "open"
    EscalationAnswered -> "answered"
    EscalationCancelled -> "cancelled"

data EscalationRow = EscalationRow
  { escalationId :: Text,
    delegationId :: Text,
    snapshotId :: Text,
    agentDefId :: Value,
    args :: Map Text Value,
    state :: EscalationState,
    value :: Maybe Value,
    createdAt :: Text
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype ListEscalationsResponse = ListEscalationsResponse
  { escalations :: [EscalationRow]
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype AnswerEscalationRequest = AnswerEscalationRequest
  { value :: Value
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype AnswerEscalationResponse = AnswerEscalationResponse
  { ok :: Bool
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON, ToJSON)
