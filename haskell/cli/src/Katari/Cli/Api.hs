-- | HTTP client for the Katari runtime.
--
-- The runtime mounts its API under @\/api\/v1@ (see @typescript\/runtime\/src\/app.ts@) and wraps
-- every response in a @{ ok, data }@ / @{ ok, error }@ envelope (see @lib\/response.ts@). This module
-- hides both of those conventions: callers see plain decoded payloads, and a non-2xx response or a
-- network failure is raised as a 'RuntimeError' rather than crashing with a raw 'HttpException'.
--
-- Only the surface @katari apply@ needs is implemented: list / create projects, read a project's
-- snapshot head, and deploy a new snapshot. The per-module deploy protocol it speaks to is described
-- in @docs\/2026-06-19-per-module-snapshot.md@.
module Katari.Cli.Api
  ( RuntimeClient (..),
    RuntimeError (..),
    newRuntimeClient,
    runtimeAuthFromEnvironment,
    renderRuntimeError,

    -- * Projects
    ProjectRow (..),
    listProjects,
    createProject,

    -- * Snapshots
    ModuleUpload (..),
    listHeadModules,
    deploySnapshot,
  )
where

import Control.Exception (Exception, throwIO, try)
import Data.Aeson (FromJSON (..), ToJSON (..), Value, object, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
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
    httpLbs,
    method,
    parseRequest,
    requestBody,
    requestHeaders,
    responseBody,
    responseStatus,
  )
import Network.HTTP.Client qualified as HttpClient
import Network.HTTP.Types.Status (statusCode)
import System.Environment (lookupEnv)

-- ===========================================================================
-- Client + errors
-- ===========================================================================

-- | Everything one runtime call needs: the @[runtime].url@ base (trailing slash stripped), the
-- optional bearer token, and a shared connection manager.
data RuntimeClient = RuntimeClient
  { baseUrl :: Text,
    authToken :: Maybe Text,
    manager :: Manager
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
  RuntimeClient {baseUrl = stripTrailingSlash base, authToken = token, manager = manager}
  where
    stripTrailingSlash text = case Text.unsnoc text of
      Just (rest, '/') -> rest
      _ -> text

-- | Read the bearer token from @KATARI_API_KEY@, treating unset / empty as 'Nothing'. The runtime
-- does not require auth today, so this is sent only when present.
runtimeAuthFromEnvironment :: IO (Maybe Text)
runtimeAuthFromEnvironment = do
  value <- lookupEnv "KATARI_API_KEY"
  pure $ case value of
    Just text | not (null text) -> Just (Text.pack text)
    _ -> Nothing

-- ===========================================================================
-- Response envelope
-- ===========================================================================

-- | The success half of the runtime's @{ ok, data }@ envelope; only @data@ is kept.
newtype SuccessEnvelope a = SuccessEnvelope
  { payload :: a
  }

instance (FromJSON a) => FromJSON (SuccessEnvelope a) where
  parseJSON = withObject "SuccessEnvelope" $ \object' -> SuccessEnvelope <$> object' .: "data"

-- ===========================================================================
-- Projects
-- ===========================================================================

-- | One project as returned by the runtime. Other columns (description, readme, head, timestamps)
-- exist on the wire but are not needed here, so they are ignored.
data ProjectRow = ProjectRow
  { id :: Text,
    name :: Text
  }
  deriving stock (Show)

instance FromJSON ProjectRow where
  parseJSON = withObject "ProjectRow" $ \object' ->
    ProjectRow <$> object' .: "id" <*> object' .: "name"

listProjects :: RuntimeClient -> IO (List ProjectRow)
listProjects client = do
  SuccessEnvelope projects <- requestJson client "GET" "/projects" Nothing
  pure projects

-- | Create a project with the given name and optional description. Fails with a 'RuntimeHttpError'
-- (409) if a project of that name already exists.
createProject :: RuntimeClient -> Text -> Maybe Text -> IO ProjectRow
createProject client name description = do
  let body = object (["name" .= name] <> maybe [] (\value -> ["description" .= value]) description)
  SuccessEnvelope project <- requestJson client "POST" "/projects" (Just (Aeson.encode body))
  pure project

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

-- | Deploy a new snapshot from the complete desired manifest, returning the new snapshot's id.
deploySnapshot :: RuntimeClient -> Text -> Text -> Map Text ModuleUpload -> IO Text
deploySnapshot client projectId message modules = do
  let body = object ["message" .= message, "modules" .= modules]
  SuccessEnvelope (response :: DeployResponse) <-
    requestJson client "POST" ("/projects/" <> projectId <> "/snapshots") (Just (Aeson.encode body))
  pure response.id

-- ===========================================================================
-- HTTP primitives
-- ===========================================================================

-- | Perform a request and decode its 2xx JSON body, translating every failure mode into a
-- 'RuntimeError'.
requestJson :: (FromJSON a) => RuntimeClient -> Text -> Text -> Maybe LazyByteString.ByteString -> IO a
requestJson client httpMethod path body = do
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
