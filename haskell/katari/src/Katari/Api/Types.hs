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
    -- * Agents
    AgentRow (..),
    AgentState (..),
    StartAgentRequest (..),
    StartAgentResponse (..),
    GetAgentResponse (..),
    ListAgentsResponse (..),
    CancelAgentResponse (..),
    -- * Agent definitions
    AgentDefinition (..),
    ListAgentDefinitionsResponse (..),
    GetAgentDefinitionResponse (..),
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
    createdAt :: Text
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype UpsertProjectRequest = UpsertProjectRequest {name :: Text}
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

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
    schemaBundle :: Value
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype UploadSnapshotResponse = UploadSnapshotResponse
  { snapshotId :: Text
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- ---------------------------------------------------------------------------
-- Agents
-- ---------------------------------------------------------------------------

data AgentState
  = AgentRunning
  | AgentCancelling
  | AgentCancelled
  | AgentSucceeded
  | AgentError
  deriving stock (Show, Eq)

instance FromJSON AgentState where
  parseJSON = withText "AgentState" $ \t -> case t of
    "running" -> pure AgentRunning
    "cancelling" -> pure AgentCancelling
    "cancelled" -> pure AgentCancelled
    "succeeded" -> pure AgentSucceeded
    "error" -> pure AgentError
    _ -> fail ("unknown agent state: " <> Text.unpack t)

instance ToJSON AgentState where
  toJSON = \case
    AgentRunning -> "running"
    AgentCancelling -> "cancelling"
    AgentCancelled -> "cancelled"
    AgentSucceeded -> "succeeded"
    AgentError -> "error"

data AgentRow = AgentRow
  { id :: Text,
    delegationId :: Text,
    snapshotId :: Text,
    qualifiedName :: Text,
    args :: Map Text Value,
    state :: AgentState,
    result :: Maybe Value,
    errorMessage :: Maybe Text,
    createdAt :: Text,
    updatedAt :: Text
  }
  deriving stock (Show, Generic)

instance FromJSON AgentRow where
  parseJSON = genericParseJSON defaultOptions

instance ToJSON AgentRow where
  toJSON = genericToJSON defaultOptions

data StartAgentRequest = StartAgentRequest
  { projectId :: Text,
    snapshotId :: Maybe Text,
    qualifiedName :: Text,
    args :: Map Text Value
  }
  deriving stock (Show, Generic)

instance FromJSON StartAgentRequest where
  parseJSON = genericParseJSON defaultOptions

-- | Drop @snapshotId: null@ when it's 'Nothing' — the api-server's
-- Zod schema accepts the field as @optional()@ (absent) but not as
-- @null@.
instance ToJSON StartAgentRequest where
  toJSON = genericToJSON defaultOptions {omitNothingFields = True}

newtype StartAgentResponse = StartAgentResponse
  { agentId :: Text
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype GetAgentResponse = GetAgentResponse
  { agent :: AgentRow
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype ListAgentsResponse = ListAgentsResponse
  { agents :: [AgentRow]
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype CancelAgentResponse = CancelAgentResponse
  { agent :: AgentRow
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

data ListAgentDefinitionsResponse = ListAgentDefinitionsResponse
  { definitions :: [AgentDefinition],
    snapshotId :: Text
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data GetAgentDefinitionResponse = GetAgentDefinitionResponse
  { definition :: AgentDefinition,
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
