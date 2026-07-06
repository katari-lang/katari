-- | HTTP client for the Katari runtime.
--
-- The runtime mounts its API under @\/api\/v1@ (see @typescript\/runtime\/src\/app.ts@) and wraps
-- every response in a @{ ok, data }@ / @{ ok, error }@ envelope (see @lib\/response.ts@). This module
-- hides both of those conventions: callers see plain decoded payloads, and a non-2xx response or a
-- network failure is raised as a 'RuntimeError' rather than crashing with a raw 'HttpException'.
--
-- Reads that back a @--json@ flag come as a pair via 'getWithRaw' — the raw envelope payload for
-- verbatim machine output next to the typed view the human rendering uses — so one request serves
-- both output modes. The file download is the one endpoint outside the envelope (raw bytes); it gets
-- its own streaming primitive.
module Katari.Cli.Api
  ( RuntimeClient (..),
    RuntimeError (..),
    newRuntimeClient,
    withTrace,
    runtimeAuthFromEnvironment,
    renderRuntimeError,

    -- * Projects
    ProjectRow (..),
    listProjects,
    createProject,
    updateProject,
    deleteProject,

    -- * Snapshots
    ModuleUpload (..),
    SnapshotRow (..),
    listHeadModules,
    listSnapshots,
    deploySnapshot,
    setSnapshotHead,

    -- * Agents
    AgentView (..),
    AgentsResponse (..),
    listAgents,
    getAgent,

    -- * Runs
    StartRunRequest (..),
    RunView (..),
    RunDetail (..),
    RunListQuery (..),
    RunEventView (..),
    RunEventsResponse (..),
    startRun,
    getRun,
    getRunDetail,
    listRuns,
    listRunEvents,
    listAllRunEvents,
    cancelRun,

    -- * Escalations
    EscalationView (..),
    listEscalations,
    answerEscalation,

    -- * Env entries
    EnvEntry (..),
    listEnv,
    getEnv,
    setEnv,
    unsetEnv,

    -- * Files
    FileRow (..),
    UploadedFile (..),
    listFiles,
    uploadFile,
    downloadFileTo,
    deleteFile,
  )
where

import Control.Exception (Exception, throwIO, try)
import Data.Aeson (FromJSON (..), ToJSON (..), Value, object, withObject, (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Map.Strict (Map)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import GHC.List (List)
import Network.HTTP.Client
  ( HttpException (..),
    Manager,
    Request,
    RequestBody (..),
    brRead,
    httpLbs,
    method,
    parseRequest,
    requestBody,
    requestHeaders,
    responseBody,
    responseStatus,
    streamFile,
    withResponse,
  )
import Network.HTTP.Client qualified as HttpClient
import Network.HTTP.Types.Status (statusCode)
import Network.HTTP.Types.URI (urlEncode)
import System.Environment (lookupEnv)
import System.IO (Handle)

-- ===========================================================================
-- Client + errors
-- ===========================================================================

-- | Everything one runtime call needs: the @[runtime].url@ base (trailing slash stripped), the
-- optional bearer token, a shared connection manager, and the @--verbose@ trace sink (a no-op by
-- default).
data RuntimeClient = RuntimeClient
  { baseUrl :: Text,
    authToken :: Maybe Text,
    manager :: Manager,
    trace :: Text -> IO ()
  }

-- | A runtime call that did not return a decodable 2xx payload.
data RuntimeError
  = -- | The request never produced an HTTP status (connection refused, DNS failure, …).
    RuntimeNetworkError Text
  | -- | A non-2xx status. The runtime answers with @{ ok: false, error: { message } }@, so the text
    -- is that message when present, otherwise the raw body.
    RuntimeHttpError Int Text
  | -- | A 2xx body that did not match the expected shape.
    RuntimeDecodeError Text
  deriving stock (Show)

instance Exception RuntimeError

-- | A one-line, user-facing rendering of a 'RuntimeError'.
renderRuntimeError :: RuntimeError -> Text
renderRuntimeError = \case
  RuntimeNetworkError message -> "network error: " <> message
  RuntimeHttpError status body -> "runtime returned HTTP " <> Text.pack (show status) <> ": " <> body
  RuntimeDecodeError message -> "could not decode runtime response: " <> message

-- | The fixed path prefix every runtime endpoint lives under.
apiPrefix :: Text
apiPrefix = "/api/v1"

-- | Build a 'RuntimeClient' over a caller-supplied connection 'Manager' (shared with dependency
-- resolution so a single @apply@ does not spin up two TLS pools). The trailing slash (if any) is
-- dropped so paths join cleanly.
newRuntimeClient :: Manager -> Text -> Maybe Text -> RuntimeClient
newRuntimeClient manager base token =
  RuntimeClient {baseUrl = stripTrailingSlash base, authToken = token, manager = manager, trace = \_ -> pure ()}
  where
    stripTrailingSlash text = case Text.unsnoc text of
      Just (rest, '/') -> rest
      _ -> text

-- | Attach a @--verbose@ trace sink; every request and response status flows through it.
withTrace :: (Text -> IO ()) -> RuntimeClient -> RuntimeClient
withTrace sink client = client {trace = sink}

-- | Read the bearer token from @KATARI_API_KEY@, treating unset / empty as 'Nothing'. The runtime
-- requires this on every request, so callers enforce presence (see @requireRuntimeAuth@) rather than
-- send an unauthenticated request that the server rejects with a 401.
runtimeAuthFromEnvironment :: IO (Maybe Text)
runtimeAuthFromEnvironment = do
  value <- lookupEnv "KATARI_API_KEY"
  pure $ case value of
    Just text | not (null text) -> Just (Text.pack text)
    _ -> Nothing

-- ===========================================================================
-- Response envelope
-- ===========================================================================

-- | The success half of the runtime's @{ ok, data }@ envelope; only @data@ is kept (consumers
-- pattern-match the wrapped value, so it is a plain newtype rather than a record).
newtype SuccessEnvelope a = SuccessEnvelope a

instance (FromJSON a) => FromJSON (SuccessEnvelope a) where
  parseJSON = withObject "SuccessEnvelope" $ \object' -> SuccessEnvelope <$> object' .: "data"

-- | A GET whose payload both machine output (@--json@, verbatim) and human rendering (typed) read:
-- one request, decoded twice.
getWithRaw :: (FromJSON a) => RuntimeClient -> Text -> IO (Value, a)
getWithRaw client path = do
  SuccessEnvelope raw <- requestJson client "GET" path Nothing
  case Aeson.fromJSON raw of
    Aeson.Success typed -> pure (raw, typed)
    Aeson.Error message -> throwIO (RuntimeDecodeError (Text.pack message))

-- | Render optional query parameters, dropping the absent ones. Values here are ids, enum words and
-- numbers — nothing needing percent-escaping.
queryString :: List (Text, Maybe Text) -> Text
queryString parameters = case [name <> "=" <> value | (name, Just value) <- parameters] of
  [] -> ""
  pairs -> "?" <> Text.intercalate "&" pairs

-- | Percent-encode one user-supplied path segment so it survives intact as a single segment. Without
-- this a space raises an @InvalidUrlException@ (surfacing as a misleading "network error") and a @/@
-- or @#@ silently retargets the request; encoding reserved characters (the @True@) keeps an env key
-- or a qualified agent name that contains any of them addressing the row it names.
encodePathSegment :: Text -> Text
encodePathSegment = TextEncoding.decodeUtf8Lenient . urlEncode True . TextEncoding.encodeUtf8

-- ===========================================================================
-- Projects
-- ===========================================================================

-- | One project as returned by the runtime. @readme@ / @head@ exist on the wire but are not needed
-- here, so they are ignored.
data ProjectRow = ProjectRow
  { id :: Text,
    name :: Text,
    description :: Maybe Text,
    createdAt :: Maybe Text
  }
  deriving stock (Show)

instance FromJSON ProjectRow where
  parseJSON = withObject "ProjectRow" $ \object' ->
    ProjectRow
      <$> object' .: "id"
      <*> object' .: "name"
      <*> object' .:? "description"
      <*> object' .:? "createdAt"

listProjects :: RuntimeClient -> IO (Value, List ProjectRow)
listProjects client = getWithRaw client "/projects"

-- | Create a project with the given name, optional description and optional README. Fails with a
-- 'RuntimeHttpError' (409) if a project of that name already exists.
createProject :: RuntimeClient -> Text -> Maybe Text -> Maybe Text -> IO ProjectRow
createProject client name description readme = do
  let body =
        object
          ( ["name" .= name]
              <> maybe [] (\value -> ["description" .= value]) description
              <> maybe [] (\value -> ["readme" .= value]) readme
          )
  SuccessEnvelope project <- requestJson client "POST" "/projects" (Just (Aeson.encode body))
  pure project

-- | Update an existing project's description / README. Both fields are sent explicitly (a @null@
-- clears the column), so @katari apply@ keeps them in sync with the source on every deploy.
updateProject :: RuntimeClient -> Text -> Maybe Text -> Maybe Text -> IO ProjectRow
updateProject client projectId description readme = do
  let body = object ["description" .= description, "readme" .= readme]
  SuccessEnvelope project <- requestJson client "PATCH" ("/projects/" <> projectId) (Just (Aeson.encode body))
  pure project

deleteProject :: RuntimeClient -> Text -> IO ()
deleteProject client projectId = do
  SuccessEnvelope (_ :: Value) <- requestJson client "DELETE" ("/projects/" <> projectId) Nothing
  pure ()

-- ===========================================================================
-- Snapshots
-- ===========================================================================

-- | One module's contribution to a deploy manifest: its content hash, and the lowered IR — present
-- only for a module the runtime does not already hold (its hash is new or changed).
data ModuleUpload = ModuleUpload
  { hash :: Text,
    ir :: Maybe Value
  }
  deriving stock (Show)

-- | Drop the @ir@ field entirely when absent, matching the runtime's @{ hash, ir? }@ schema.
instance ToJSON ModuleUpload where
  toJSON upload = object (["hash" .= upload.hash] <> maybe [] (\value -> ["ir" .= value]) upload.ir)

-- | One deployed snapshot's listing row.
data SnapshotRow = SnapshotRow
  { id :: Text,
    message :: Maybe Text,
    createdAt :: Text
  }
  deriving stock (Show)

instance FromJSON SnapshotRow where
  parseJSON = withObject "SnapshotRow" $ \object' ->
    SnapshotRow <$> object' .: "id" <*> object' .:? "message" <*> object' .: "createdAt"

-- | The snapshot head's manifest: module name -> the content hash the runtime currently holds for
-- it. Only @modules@ is read from the head response (the placeholder head, before any deploy, is an
-- empty map).
newtype HeadResponse = HeadResponse
  { modules :: Map Text Text
  }

instance FromJSON HeadResponse where
  parseJSON = withObject "HeadResponse" $ \object' -> HeadResponse <$> object' .: "modules"

-- | The deploy response: the new snapshot's id.
newtype DeployResponse = DeployResponse
  { id :: Text
  }

instance FromJSON DeployResponse where
  parseJSON = withObject "DeployResponse" $ \object' -> DeployResponse <$> object' .: "id"

-- | The module hashes the live (head) snapshot of a project currently holds, keyed by module name.
-- Empty when nothing is deployed yet. The CLI diffs its fresh build against this.
listHeadModules :: RuntimeClient -> Text -> IO (Map Text Text)
listHeadModules client projectId = do
  SuccessEnvelope (head' :: HeadResponse) <-
    requestJson client "GET" ("/projects/" <> projectId <> "/snapshots/head") Nothing
  pure head'.modules

listSnapshots :: RuntimeClient -> Text -> IO (Value, List SnapshotRow)
listSnapshots client projectId = getWithRaw client ("/projects/" <> projectId <> "/snapshots")

-- | Move the project's live head to an existing snapshot (a rollback / roll-forward). Only new runs
-- follow the moved head — a run pins the snapshot it started on.
setSnapshotHead :: RuntimeClient -> Text -> Text -> IO ()
setSnapshotHead client projectId snapshotId = do
  let body = object ["snapshotId" .= snapshotId]
  SuccessEnvelope (_ :: Value) <-
    requestJson client "PUT" ("/projects/" <> projectId <> "/snapshots/head") (Just (Aeson.encode body))
  pure ()

-- | Deploy a new snapshot from the complete desired manifest, returning the new snapshot's id. The
-- compiled FFI sidecar bundle (the bundler's opaque JSON, or 'Nothing' when the project has no external
-- handlers) rides along; it is omitted from the body when absent, matching the runtime's optional field.
deploySnapshot :: RuntimeClient -> Text -> Text -> Maybe Value -> Map Text ModuleUpload -> IO Text
deploySnapshot client projectId message sidecarBundle modules = do
  let body =
        object
          ( ["message" .= message, "modules" .= modules]
              <> maybe [] (\value -> ["sidecarBundle" .= value]) sidecarBundle
          )
  SuccessEnvelope (response :: DeployResponse) <-
    requestJson client "POST" ("/projects/" <> projectId <> "/snapshots") (Just (Aeson.encode body))
  pure response.id

-- ===========================================================================
-- Agents
-- ===========================================================================

-- | One callable's schema slice, as the runtime reads it out of the snapshot IR. The schemas stay
-- raw 'Value's here; the prompt layer decodes them into the compiler's typed 'JSONSchema' when it
-- actually walks them.
data AgentView = AgentView
  { qualifiedName :: Text,
    input :: Value,
    output :: Value
  }
  deriving stock (Show)

instance FromJSON AgentView where
  parseJSON = withObject "AgentView" $ \object' ->
    AgentView <$> object' .: "qualifiedName" <*> object' .: "input" <*> object' .: "output"

-- | The agents listing: which snapshot was read (the head, unless pinned) and its callables.
data AgentsResponse = AgentsResponse
  { snapshotId :: Text,
    agents :: List AgentView
  }
  deriving stock (Show)

instance FromJSON AgentsResponse where
  parseJSON = withObject "AgentsResponse" $ \object' ->
    AgentsResponse <$> object' .: "snapshotId" <*> object' .: "agents"

listAgents :: RuntimeClient -> Text -> Maybe Text -> IO (Value, AgentsResponse)
listAgents client projectId snapshotId =
  getWithRaw client ("/projects/" <> projectId <> "/agents" <> queryString [("snapshotId", snapshotId)])

getAgent :: RuntimeClient -> Text -> Text -> Maybe Text -> IO AgentView
getAgent client projectId qualifiedName snapshotId = do
  SuccessEnvelope agent <-
    requestJson
      client
      "GET"
      ("/projects/" <> projectId <> "/agents/" <> encodePathSegment qualifiedName <> queryString [("snapshotId", snapshotId)])
      Nothing
  pure agent

-- ===========================================================================
-- Runs
-- ===========================================================================

-- | Start an agent run: the agent to run, an optional human label / pinned snapshot, and the run argument
-- as JSON (the runtime lifts it into a value at its boundary).
data StartRunRequest = StartRunRequest
  { qualifiedName :: Text,
    name :: Maybe Text,
    snapshotId :: Maybe Text,
    argument :: Maybe Value
  }
  deriving stock (Show)

-- | Drop the optional fields when absent, matching the runtime's @{ qualifiedName, name?, snapshotId?,
-- argument? }@ schema.
instance ToJSON StartRunRequest where
  toJSON request =
    object
      ( ["qualifiedName" .= request.qualifiedName]
          <> maybe [] (\value -> ["name" .= value]) request.name
          <> maybe [] (\value -> ["snapshotId" .= value]) request.snapshotId
          <> maybe [] (\value -> ["argument" .= value]) request.argument
      )

-- | The run's id, returned by the start endpoint.
newtype RunStarted = RunStarted {id :: Text}

instance FromJSON RunStarted where
  parseJSON = withObject "RunStarted" $ \object' -> RunStarted <$> object' .: "id"

-- | The slice of a run's view the wait loop needs: the lifecycle @state@ (running / cancelling / done /
-- cancelled / error), the @result@ JSON (present once @done@), and the @errorMessage@ (present once
-- @error@). The other view fields are ignored.
data RunView = RunView
  { state :: Text,
    result :: Maybe Value,
    errorMessage :: Maybe Text
  }
  deriving stock (Show)

instance FromJSON RunView where
  parseJSON = withObject "RunView" $ \object' ->
    RunView <$> object' .: "state" <*> object' .:? "result" <*> object' .:? "errorMessage"

-- | A run's full management view, for @status@ and the runs listing.
data RunDetail = RunDetail
  { id :: Text,
    name :: Text,
    qualifiedName :: Text,
    snapshotId :: Maybe Text,
    state :: Text,
    argument :: Maybe Value,
    result :: Maybe Value,
    errorMessage :: Maybe Text,
    cancelReason :: Maybe Text,
    createdAt :: Text,
    completedAt :: Maybe Text
  }
  deriving stock (Show)

instance FromJSON RunDetail where
  parseJSON = withObject "RunDetail" $ \object' ->
    RunDetail
      <$> object' .: "id"
      <*> object' .: "name"
      <*> object' .: "qualifiedName"
      <*> object' .:? "snapshotId"
      <*> object' .: "state"
      <*> object' .:? "argument"
      <*> object' .:? "result"
      <*> object' .:? "errorMessage"
      <*> object' .:? "cancelReason"
      <*> object' .: "createdAt"
      <*> object' .:? "completedAt"

-- | Listing filters, mirroring the runtime's query parameters.
data RunListQuery = RunListQuery
  { state :: Maybe Text,
    limit :: Maybe Int
  }
  deriving stock (Show)

-- | Start a run, returning its id (the durable run handle).
startRun :: RuntimeClient -> Text -> StartRunRequest -> IO Text
startRun client projectId request = do
  SuccessEnvelope (started :: RunStarted) <-
    requestJson client "POST" ("/projects/" <> projectId <> "/runs") (Just (Aeson.encode request))
  pure started.id

-- | Fetch a run's current view (state + outcome), for the wait loop.
getRun :: RuntimeClient -> Text -> Text -> IO RunView
getRun client projectId runId = do
  SuccessEnvelope (view :: RunView) <-
    requestJson client "GET" ("/projects/" <> projectId <> "/runs/" <> runId) Nothing
  pure view

getRunDetail :: RuntimeClient -> Text -> Text -> IO (Value, RunDetail)
getRunDetail client projectId runId = getWithRaw client ("/projects/" <> projectId <> "/runs/" <> runId)

listRuns :: RuntimeClient -> Text -> RunListQuery -> IO (Value, List RunDetail)
listRuns client projectId query =
  getWithRaw
    client
    ( "/projects/"
        <> projectId
        <> "/runs"
        <> queryString [("state", query.state), ("limit", fmap (Text.pack . show) query.limit)]
    )

-- | One event of a run's execution trace, as the events endpoint presents it — the slice the CLI
-- renders: the journal position (@seq@, the tail cursor), the event kind, and the server-rendered
-- one-line @summary@. The structured payload fields exist on the wire but the CLI prints summaries.
data RunEventView = RunEventView
  { seq :: Int,
    kind :: Text,
    summary :: Text,
    createdAt :: Text
  }
  deriving stock (Show)

instance FromJSON RunEventView where
  parseJSON = withObject "RunEventView" $ \object' ->
    RunEventView
      <$> object' .: "seq"
      <*> object' .: "kind"
      <*> object' .: "summary"
      <*> object' .: "createdAt"

-- | One page of a run's execution trace. The run's lifecycle @state@ rides along so a watcher's single
-- poll both extends the trace and answers "is it still running".
data RunEventsResponse = RunEventsResponse
  { state :: Text,
    events :: List RunEventView
  }
  deriving stock (Show)

instance FromJSON RunEventsResponse where
  parseJSON = withObject "RunEventsResponse" $ \object' ->
    RunEventsResponse <$> object' .: "state" <*> object' .: "events"

-- | Tail a run's execution trace: the journaled events after @after@ (exclusive; 0 for the start),
-- oldest first, one server-capped page per call.
listRunEvents :: RuntimeClient -> Text -> Text -> Int -> IO (Value, RunEventsResponse)
listRunEvents client projectId runId after =
  getWithRaw
    client
    ( "/projects/"
        <> projectId
        <> "/runs/"
        <> runId
        <> "/events"
        <> queryString [("after", Just (Text.pack (show after)))]
    )

-- | A run's whole trace, following pages until the tail is drained (the endpoint returns at most one
-- page per call). Returns the run's state as of the last page.
listAllRunEvents :: RuntimeClient -> Text -> Text -> IO (Text, List RunEventView)
listAllRunEvents client projectId runId = go 0 []
  where
    go after collected = do
      (_, response) <- listRunEvents client projectId runId after
      case response.events of
        [] -> pure (response.state, collected)
        events -> go (maximum (map (.seq) events)) (collected <> events)

-- | Ask the runtime to cancel a run (it transitions to @cancelling@ and winds down asynchronously).
cancelRun :: RuntimeClient -> Text -> Text -> Maybe Text -> IO ()
cancelRun client projectId runId reason = do
  let body = object (maybe [] (\text -> ["reason" .= text]) reason)
  SuccessEnvelope (_ :: Value) <-
    requestJson client "POST" ("/projects/" <> projectId <> "/runs/" <> runId <> "/cancel") (Just (Aeson.encode body))
  pure ()

-- ===========================================================================
-- Escalations
-- ===========================================================================

-- | One open escalation: which request is being asked, its question (already secret-redacted by the
-- runtime), the run waiting on it, and the schema an answer must satisfy ('Nothing' when the runtime
-- could not derive one — the prompt falls back to raw JSON input).
data EscalationView = EscalationView
  { id :: Text,
    request :: Text,
    argument :: Maybe Value,
    runId :: Text,
    createdAt :: Text,
    answerSchema :: Maybe Value
  }
  deriving stock (Show)

instance FromJSON EscalationView where
  parseJSON = withObject "EscalationView" $ \object' ->
    EscalationView
      <$> object' .: "id"
      <*> object' .: "request"
      <*> object' .:? "argument"
      <*> object' .: "runId"
      <*> object' .: "createdAt"
      <*> object' .:? "answerSchema"

listEscalations :: RuntimeClient -> Text -> IO (Value, List EscalationView)
listEscalations client projectId = getWithRaw client ("/projects/" <> projectId <> "/escalations")

answerEscalation :: RuntimeClient -> Text -> Text -> Value -> IO ()
answerEscalation client projectId escalationId value = do
  SuccessEnvelope (_ :: Value) <-
    requestJson
      client
      "POST"
      ("/projects/" <> projectId <> "/escalations/" <> escalationId <> "/answer")
      (Just (Aeson.encode (object ["value" .= value])))
  pure ()

-- ===========================================================================
-- Env entries
-- ===========================================================================

-- | One env entry. The runtime withholds a secret's value on every read (it is write-only over the
-- API; programs read it via @env.get_secret@), so @value@ is present only for non-secret entries.
data EnvEntry = EnvEntry
  { key :: Text,
    isSecret :: Bool,
    value :: Maybe Text,
    updatedAt :: Maybe Text
  }
  deriving stock (Show)

instance FromJSON EnvEntry where
  parseJSON = withObject "EnvEntry" $ \object' ->
    EnvEntry
      <$> object' .: "key"
      <*> object' .: "isSecret"
      <*> object' .:? "value"
      <*> object' .:? "updatedAt"

listEnv :: RuntimeClient -> Text -> IO (Value, List EnvEntry)
listEnv client projectId = getWithRaw client ("/projects/" <> projectId <> "/env")

getEnv :: RuntimeClient -> Text -> Text -> IO EnvEntry
getEnv client projectId key = do
  SuccessEnvelope entry <- requestJson client "GET" ("/projects/" <> projectId <> "/env/" <> encodePathSegment key) Nothing
  pure entry

setEnv :: RuntimeClient -> Text -> Text -> Text -> Bool -> IO ()
setEnv client projectId key value isSecret = do
  let body = object ["value" .= value, "isSecret" .= isSecret]
  SuccessEnvelope (_ :: Value) <-
    requestJson client "PUT" ("/projects/" <> projectId <> "/env/" <> encodePathSegment key) (Just (Aeson.encode body))
  pure ()

unsetEnv :: RuntimeClient -> Text -> Text -> IO ()
unsetEnv client projectId key = do
  SuccessEnvelope (_ :: Value) <-
    requestJson client "DELETE" ("/projects/" <> projectId <> "/env/" <> encodePathSegment key) Nothing
  pure ()

-- ===========================================================================
-- Files
-- ===========================================================================

-- | One stored file's metadata row.
data FileRow = FileRow
  { id :: Text,
    hash :: Text,
    size :: Int,
    contentType :: Maybe Text,
    semanticKind :: Maybe Text
  }
  deriving stock (Show)

instance FromJSON FileRow where
  parseJSON = withObject "FileRow" $ \object' ->
    FileRow
      <$> object' .: "id"
      <*> object' .: "hash"
      <*> object' .: "size"
      <*> object' .:? "contentType"
      <*> object' .:? "semanticKind"

-- | The upload response: the stored blob's handle.
data UploadedFile = UploadedFile
  { id :: Text,
    hash :: Text,
    size :: Int
  }
  deriving stock (Show)

instance FromJSON UploadedFile where
  parseJSON = withObject "UploadedFile" $ \object' ->
    UploadedFile <$> object' .: "id" <*> object' .: "hash" <*> object' .: "size"

listFiles :: RuntimeClient -> Text -> IO (Value, List FileRow)
listFiles client projectId = getWithRaw client ("/projects/" <> projectId <> "/files")

-- | Delete a stored file (its blob row now, its bytes after the runtime's commit).
deleteFile :: RuntimeClient -> Text -> Text -> IO ()
deleteFile client projectId fileId = do
  SuccessEnvelope (_ :: Value) <-
    requestJson client "DELETE" ("/projects/" <> projectId <> "/files/" <> fileId) Nothing
  pure ()

-- | Upload a file's bytes (streamed from disk, not buffered) under the given content type.
uploadFile :: RuntimeClient -> Text -> FilePath -> Text -> IO UploadedFile
uploadFile client projectId path contentType = do
  streamedBody <- streamFile path
  request <- buildRequest client "POST" ("/projects/" <> projectId <> "/files") Nothing
  let uploadRequest =
        request
          { requestBody = streamedBody,
            requestHeaders =
              ("Content-Type", TextEncoding.encodeUtf8 contentType)
                : [header | header <- requestHeaders request, fst header /= "Content-Type"]
          }
  client.trace ("POST /projects/" <> projectId <> "/files (streaming " <> Text.pack path <> ")")
  response <- httpLbs uploadRequest client.manager
  let status = statusCode (responseStatus response)
      responseBytes = responseBody response
  client.trace ("-> " <> Text.pack (show status))
  if status >= 200 && status < 300
    then case Aeson.eitherDecode responseBytes of
      Right (SuccessEnvelope uploaded) -> pure uploaded
      Left message -> throwIO (RuntimeDecodeError (Text.pack message))
    else throwIO (RuntimeHttpError status (extractErrorMessage responseBytes))

-- | Stream a file's bytes to the given handle. This endpoint returns raw bytes with no envelope, so
-- it bypasses 'requestJson'; a non-2xx still carries the JSON error envelope and is raised as usual.
downloadFileTo :: RuntimeClient -> Text -> Text -> Handle -> IO ()
downloadFileTo client projectId fileId sink = do
  request <- buildRequest client "GET" ("/projects/" <> projectId <> "/files/" <> fileId) Nothing
  client.trace ("GET /projects/" <> projectId <> "/files/" <> fileId <> " (streaming)")
  withResponse request client.manager $ \response -> do
    let status = statusCode (responseStatus response)
    client.trace ("-> " <> Text.pack (show status))
    if status >= 200 && status < 300
      then
        let copyChunks = do
              chunk <- brRead (responseBody response)
              if ByteString.null chunk
                then pure ()
                else ByteString.hPut sink chunk >> copyChunks
         in copyChunks
      else do
        body <- brReadAll (responseBody response)
        throwIO (RuntimeHttpError status (extractErrorMessage (LazyByteString.fromStrict body)))
  where
    brReadAll reader = go []
      where
        go accumulated = do
          chunk <- brRead reader
          if ByteString.null chunk
            then pure (ByteString.concat (reverse accumulated))
            else go (chunk : accumulated)

-- ===========================================================================
-- HTTP primitives
-- ===========================================================================

-- | Perform a request and decode its 2xx JSON body, translating every failure mode into a
-- 'RuntimeError'.
requestJson :: (FromJSON a) => RuntimeClient -> Text -> Text -> Maybe LazyByteString.ByteString -> IO a
requestJson client httpMethod path body = do
  client.trace (httpMethod <> " " <> path)
  -- 'buildRequest' runs inside the 'try': 'parseRequest' throws an 'HttpException' (InvalidUrlException)
  -- on a malformed URL, and we want that surfaced as a 'RuntimeError' too — not as an uncaught crash.
  result <- try $ do
    request <- buildRequest client httpMethod path body
    httpLbs request client.manager
  response <- case result of
    Left exception -> throwIO (RuntimeNetworkError (formatHttpException exception))
    Right response -> pure response
  let status = statusCode (responseStatus response)
      responseBytes = responseBody response
  client.trace ("-> " <> Text.pack (show status) <> " (" <> Text.pack (show (LazyByteString.length responseBytes)) <> " bytes)")
  if status >= 200 && status < 300
    then case Aeson.eitherDecode responseBytes of
      Right value -> pure value
      Left message -> throwIO (RuntimeDecodeError (Text.pack message))
    else throwIO (RuntimeHttpError status (extractErrorMessage responseBytes))

-- | Assemble the underlying 'Request': base URL + API prefix + path, the JSON body when given, and
-- the @Content-Type@ / @Authorization@ headers.
buildRequest :: RuntimeClient -> Text -> Text -> Maybe LazyByteString.ByteString -> IO Request
buildRequest client httpMethod path body = do
  request <- parseRequest (Text.unpack (client.baseUrl <> apiPrefix <> path))
  let headers =
        [("Content-Type", "application/json") | hasBody]
          <> [("Authorization", TextEncoding.encodeUtf8 ("Bearer " <> token)) | Just token <- [client.authToken]]
  pure
    request
      { method = TextEncoding.encodeUtf8 httpMethod,
        requestHeaders = headers,
        requestBody = RequestBodyLBS (fromMaybe "" body)
      }
  where
    hasBody = case body of
      Just _ -> True
      Nothing -> False

-- | Pull the @error.message@ out of the runtime's error envelope, falling back to the raw (UTF-8
-- decoded) body when it is not in that shape.
extractErrorMessage :: LazyByteString.ByteString -> Text
extractErrorMessage responseBytes = case Aeson.decode responseBytes of
  Just (ErrorEnvelope message) -> message
  Nothing -> TextEncoding.decodeUtf8Lenient (LazyByteString.toStrict responseBytes)

-- | The @{ ok: false, error: { message } }@ shape, for surfacing a readable failure message.
newtype ErrorEnvelope = ErrorEnvelope Text

instance FromJSON ErrorEnvelope where
  parseJSON = withObject "ErrorEnvelope" $ \object' -> do
    errorObject <- object' .: "error"
    ErrorEnvelope <$> errorObject .: "message"

-- | Render an 'HttpException' without leaking the @Authorization@ header that 'show' on the raw
-- 'Request' would dump.
formatHttpException :: HttpException -> Text
formatHttpException = \case
  HttpExceptionRequest request content ->
    Text.pack ("request to " <> show (HttpClient.host request) <> " failed: " <> show content)
  InvalidUrlException url reason -> Text.pack ("invalid URL " <> show url <> ": " <> reason)
