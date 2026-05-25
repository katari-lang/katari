-- | Thin Haskell HTTP wrapper around the katari-api-server.
--
-- Mirrors the TypeScript SSoT at
-- @typescript/packages/katari-cli/src/services/api-client.ts@. Builds
-- on @http-client@ + @aeson@; HTTPS is handled by @http-client-tls@.
--
-- Errors are surfaced as 'ApiError'. The HTTP status is included so
-- callers can distinguish (404 → "not found") from (5xx → "server
-- problem") without parsing the message string.
module Katari.Api.Client
  ( ApiClient (..),
    ApiError (..),
    newApiClient,
    apiAuthFromEnv,
    -- * Projects
    upsertProject,
    listProjects,
    -- * Snapshots
    uploadSnapshot,
    listSnapshots,
    -- * Runs
    startRun,
    listRuns,
    getRun,
    cancelRun,
    -- * Agents
    listAgents,
    -- * Escalations
    listEscalations,
    answerEscalation,
  )
where

import Control.Exception (Exception, throwIO, try)
import System.Environment (lookupEnv)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as AesonKey
import qualified Data.Aeson.KeyMap as AesonKM
import qualified Data.ByteString.Lazy as LBS
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEnc
import GHC.Generics (Generic)
import Katari.Api.Types
import Network.HTTP.Client
  ( HttpException (..),
    Manager,
    Request,
    RequestBody (..),
    httpLbs,
    method,
    parseRequest,
    requestBody,
    requestHeaders,
    responseBody,
    responseStatus,
  )
import qualified Network.HTTP.Client as HC
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types.Status (statusCode)
import qualified Network.HTTP.Types.URI as HttpUri

-- ---------------------------------------------------------------------------
-- Client + errors
-- ---------------------------------------------------------------------------

data ApiClient = ApiClient
  { baseUrl :: Text,
    authToken :: Maybe Text,
    manager :: Manager
  }

data ApiError
  = -- | Network / parse problem before we got an HTTP status back.
    ApiNetworkError String
  | -- | The server responded but with a non-2xx status code. @body@
    -- is whatever the server returned; in practice api-server
    -- responds with @{ "error": "..." }@.
    ApiHttpError Int Text
  | -- | We got a 2xx response but the body did not match the expected
    -- shape.
    ApiDecodeError String
  deriving (Show)

instance Exception ApiError

-- | Build an 'ApiClient' with a fresh TLS-capable HTTP manager.
newApiClient :: Text -> Maybe Text -> IO ApiClient
newApiClient base tok = do
  m <- newTlsManager
  pure ApiClient {baseUrl = stripSlash base, authToken = tok, manager = m}
  where
    stripSlash t = case Text.unsnoc t of
      Just (rest, '/') -> rest
      _ -> t

-- | Read the API key from @KATARI_API_KEY@. Returns 'Nothing' if unset
-- or empty. The @katari.toml@ no longer holds the secret — env var is
-- the only sanctioned source.
apiAuthFromEnv :: IO (Maybe Text)
apiAuthFromEnv = do
  v <- lookupEnv "KATARI_API_KEY"
  pure $ case v of
    Just s | not (null s) -> Just (Text.pack s)
    _ -> Nothing

-- ---------------------------------------------------------------------------
-- Projects
-- ---------------------------------------------------------------------------

upsertProject :: ApiClient -> UpsertProjectRequest -> IO Project
upsertProject c req = do
  r :: UpsertProjectResponse <- post c "/project" req
  pure r.project

listProjects :: ApiClient -> IO [Project]
listProjects c = do
  r :: ListProjectsResponse <- get c "/project"
  pure r.projects

-- ---------------------------------------------------------------------------
-- Snapshots
-- ---------------------------------------------------------------------------

uploadSnapshot :: ApiClient -> Text -> UploadSnapshotRequest -> IO Text
uploadSnapshot c projectId req = do
  r :: UploadSnapshotResponse <- post c ("/project/" <> projectId <> "/snapshot") req
  pure r.snapshotId

listSnapshots :: ApiClient -> Text -> IO [SnapshotSummary]
listSnapshots c projectId = do
  r :: ListSnapshotsResponse <- get c ("/project/" <> projectId <> "/snapshot")
  pure r.snapshots

newtype ListSnapshotsResponse = ListSnapshotsResponse {snapshots :: [SnapshotSummary]}
  deriving stock (Show, Generic)
  deriving anyclass (Aeson.FromJSON)

-- ---------------------------------------------------------------------------
-- Runs (= operator-launched root delegations)
-- ---------------------------------------------------------------------------

-- Runs / escalations are project-scoped at the URL level
-- (`/project/:projectId/...`); single-entity GET / POST-cancel also
-- have flat `/run/:id` aliases since the CLI typically holds a globally-
-- unique UUID without needing project context (e.g. `katari status <runId>`).

startRun :: ApiClient -> StartRunRequest -> IO Text
startRun c req = do
  r :: StartRunResponse <-
    post c ("/project/" <> req.projectId <> "/run") req
  pure r.runId

listRuns :: ApiClient -> Text -> Maybe Text -> IO [RunRow]
listRuns c projectId snapshotId = do
  let q = buildQuery [("snapshotId", snapshotId)]
  r :: ListRunsResponse <- get c ("/project/" <> projectId <> "/run" <> q)
  pure r.runs

getRun :: ApiClient -> Text -> IO RunRow
getRun c runId = do
  r :: GetRunResponse <- get c ("/run/" <> runId)
  pure r.run

cancelRun :: ApiClient -> Text -> IO RunRow
cancelRun c runId = do
  r :: CancelRunResponse <- post c ("/run/" <> runId <> "/cancel") emptyObject
  pure r.run

-- ---------------------------------------------------------------------------
-- Agents
-- ---------------------------------------------------------------------------

listAgents :: ApiClient -> Text -> Maybe Text -> IO ([AgentDefinition], Text)
listAgents c projectId snapshotId = do
  let sid = maybe "latest" id snapshotId
  r :: ListAgentsResponse <-
    get c ("/project/" <> projectId <> "/snapshot/" <> sid <> "/agent")
  pure (r.agents, r.snapshotId)

-- ---------------------------------------------------------------------------
-- Escalations
-- ---------------------------------------------------------------------------

listEscalations ::
  ApiClient -> Text -> Maybe Text -> Maybe EscalationState -> IO [EscalationRow]
listEscalations c projectId snapshotId stateF = do
  let q =
        buildQuery
          [ ("snapshotId", snapshotId),
            ("state", fmap escalationStateLit stateF)
          ]
  r :: ListEscalationsResponse <-
    get c ("/project/" <> projectId <> "/escalation" <> q)
  pure r.escalations
  where
    escalationStateLit = \case
      EscalationOpen -> "open"
      EscalationAnswered -> "answered"
      EscalationCancelled -> "cancelled"

answerEscalation :: ApiClient -> Text -> Aeson.Value -> IO Bool
answerEscalation c escalationId v = do
  r :: AnswerEscalationResponse <-
    post c ("/escalation/" <> escalationId <> "/ack") AnswerEscalationRequest {value = v}
  pure r.ok

-- ---------------------------------------------------------------------------
-- HTTP primitives
-- ---------------------------------------------------------------------------

get :: Aeson.FromJSON a => ApiClient -> Text -> IO a
get c path = request c "GET" path Nothing

post :: (Aeson.ToJSON req, Aeson.FromJSON res) => ApiClient -> Text -> req -> IO res
post c path req = request c "POST" path (Just (Aeson.encode req))

request ::
  Aeson.FromJSON res =>
  ApiClient -> -- client
  Text -> -- HTTP method
  Text -> -- request path (with leading '/')
  Maybe LBS.ByteString -> -- optional JSON body
  IO res
request c httpMethod path body = do
  rq0 <- mkRequest c httpMethod path body
  resE <- try (httpLbs rq0 c.manager)
  res <- case resE of
    Left (e :: HttpException) -> throwIO (ApiNetworkError (formatHttpException e))
    Right ok -> pure ok
  let status = statusCode (responseStatus res)
      bs = responseBody res
  if status >= 200 && status < 300
    then case Aeson.eitherDecode bs of
      Right v -> pure v
      Left err -> throwIO (ApiDecodeError err)
    else
      let msg = case Aeson.eitherDecode bs of
            Right (Aeson.Object o)
              | Just (Aeson.String s) <- AesonKM.lookup (AesonKey.fromString "error") o -> s
            _ -> TextEnc.decodeUtf8Lenient (LBS.toStrict bs)
       in throwIO (ApiHttpError status msg)

mkRequest :: ApiClient -> Text -> Text -> Maybe LBS.ByteString -> IO Request
mkRequest c httpMethod path body = do
  let url = Text.unpack (c.baseUrl <> path)
  rq <- parseRequest url
  let headers =
        [("Content-Type", "application/json") | hasBody]
          <> [("Authorization", TextEnc.encodeUtf8 ("Bearer " <> tok)) | Just tok <- [c.authToken]]
      hasBody = case body of
        Just _ -> True
        Nothing -> False
  pure
    rq
      { method = TextEnc.encodeUtf8 httpMethod,
        requestHeaders = headers,
        requestBody = case body of
          Just b -> RequestBodyLBS b
          Nothing -> RequestBodyLBS ""
      }

-- | Build a @?k1=v1&k2=v2@ query string from a list of @Maybe@-valued
-- pairs. Drops 'Nothing' entries.
buildQuery :: [(Text, Maybe Text)] -> Text
buildQuery pairs =
  let kept = [k <> "=" <> percentEncode v | (k, Just v) <- pairs]
   in if null kept then "" else "?" <> Text.intercalate "&" kept

-- | Percent-encode a query-string value as UTF-8 bytes (RFC 3986).
-- Delegates to 'Network.HTTP.Types.URI.urlEncode' so non-ASCII code
-- points are correctly encoded as multi-byte UTF-8 sequences rather
-- than the previous hand-rolled per-char `fromEnum` (which emitted a
-- single `%XYZW` for a >0xFF code point — wrong on the wire).
percentEncode :: Text -> Text
percentEncode =
  TextEnc.decodeUtf8
    . HttpUri.urlEncode False
    . TextEnc.encodeUtf8

emptyObject :: Aeson.Value
emptyObject = Aeson.Object mempty

-- | Render an 'HttpException' without leaking sensitive request headers.
-- 'show' on the raw exception dumps the full 'Request', which includes
-- the @Authorization: Bearer ...@ header on every authenticated call.
-- We redact that header before formatting.
formatHttpException :: HttpException -> String
formatHttpException = \case
  HttpExceptionRequest req content ->
    "HttpExceptionRequest "
      <> show (redactRequest req)
      <> " "
      <> show content
  e@(InvalidUrlException _ _) -> show e
  where
    redactRequest r =
      r {requestHeaders = map redactHeader (HC.requestHeaders r)}
    redactHeader (name, value)
      | name == "Authorization" = (name, "<redacted>")
      | name == "Cookie" = (name, "<redacted>")
      | otherwise = (name, value)
