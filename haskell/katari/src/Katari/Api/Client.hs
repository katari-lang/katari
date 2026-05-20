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
    -- * Agents
    startAgent,
    listAgents,
    getAgent,
    cancelAgent,
    -- * Agent definitions
    listAgentDefinitions,
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
  ( HttpException,
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
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types.Status (statusCode)

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

upsertProject :: ApiClient -> Text -> IO Project
upsertProject c projectName = do
  r :: UpsertProjectResponse <- post c "/project" (UpsertProjectRequest {name = projectName})
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
-- Agents
-- ---------------------------------------------------------------------------

startAgent :: ApiClient -> StartAgentRequest -> IO Text
startAgent c req = do
  r :: StartAgentResponse <- post c "/agent" req
  pure r.agentId

listAgents :: ApiClient -> Maybe Text -> Maybe Text -> IO [AgentRow]
listAgents c projectId snapshotId = do
  let q = buildQuery [("projectId", projectId), ("snapshotId", snapshotId)]
  r :: ListAgentsResponse <- get c ("/agent" <> q)
  pure r.agents

getAgent :: ApiClient -> Text -> IO AgentRow
getAgent c agentId = do
  r :: GetAgentResponse <- get c ("/agent/" <> agentId)
  pure r.agent

cancelAgent :: ApiClient -> Text -> IO AgentRow
cancelAgent c agentId = do
  r :: CancelAgentResponse <- post c ("/agent/" <> agentId <> "/cancel") emptyObject
  pure r.agent

-- ---------------------------------------------------------------------------
-- Agent definitions
-- ---------------------------------------------------------------------------

listAgentDefinitions :: ApiClient -> Text -> Maybe Text -> IO ([AgentDefinition], Text)
listAgentDefinitions c projectId snapshotId = do
  let q =
        buildQuery
          [ ("projectId", Just projectId),
            ("snapshotId", snapshotId)
          ]
  r :: ListAgentDefinitionsResponse <- get c ("/agent-definition" <> q)
  pure (r.definitions, r.snapshotId)

-- ---------------------------------------------------------------------------
-- Escalations
-- ---------------------------------------------------------------------------

listEscalations ::
  ApiClient -> Maybe Text -> Maybe Text -> Maybe EscalationState -> IO [EscalationRow]
listEscalations c projectId snapshotId stateF = do
  let q =
        buildQuery
          [ ("projectId", projectId),
            ("snapshotId", snapshotId),
            ("state", fmap escalationStateLit stateF)
          ]
  r :: ListEscalationsResponse <- get c ("/escalation" <> q)
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
    Left (e :: HttpException) -> throwIO (ApiNetworkError (show e))
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

-- | Minimal percent-encoder. The api-server only uses identifiers /
-- UUIDs in query params so this is mostly identity in practice.
percentEncode :: Text -> Text
percentEncode = Text.concatMap esc
  where
    esc c
      | isUnreserved c = Text.singleton c
      | otherwise = Text.pack ('%' : pad (showHex (fromEnum c)))
    isUnreserved c =
      (c >= 'A' && c <= 'Z')
        || (c >= 'a' && c <= 'z')
        || (c >= '0' && c <= '9')
        || c `elem` ("-_.~" :: String)
    showHex n = case toHex n of
      "" -> "00"
      s -> s
    pad s = if length s == 1 then '0' : s else s
    toHex 0 = ""
    toHex n =
      let (q, r) = n `divMod` 16
          d = "0123456789ABCDEF" !! r
       in toHex q <> [d]

emptyObject :: Aeson.Value
emptyObject = Aeson.Object mempty
