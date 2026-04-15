module Katari.CLI.Api
  ( ApiError (..),
    postApply,
    getSchemaAgents,
    listAgents,
    createAgent,
    getAgent,
    stopAgent,
  )
where

import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Client
  ( RequestBody (..),
    httpLbs,
    method,
    newManager,
    parseRequest,
    requestBody,
    requestHeaders,
    responseBody,
    responseStatus,
  )
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)

data ApiError = ApiError
  { aeStatusCode :: Int,
    aeBody :: BL.ByteString
  }
  deriving (Show)

-- ---------------------------------------------------------------------------
-- Low-level helpers
-- ---------------------------------------------------------------------------

getJson :: Text -> IO (Either ApiError Value)
getJson url = do
  manager <- newManager tlsManagerSettings
  req <- parseRequest (T.unpack url)
  resp <- httpLbs req manager
  let status = statusCode (responseStatus resp)
  if status >= 200 && status < 300
    then case Aeson.decode (responseBody resp) of
      Just v -> return (Right v)
      Nothing -> return (Left (ApiError status (responseBody resp)))
    else return (Left (ApiError status (responseBody resp)))

postJson :: Text -> Value -> IO (Either ApiError Value)
postJson url body = do
  manager <- newManager tlsManagerSettings
  req <- parseRequest (T.unpack url)
  let req' =
        req
          { method = "POST",
            requestBody = RequestBodyLBS (Aeson.encode body),
            requestHeaders = [("Content-Type", "application/json")]
          }
  resp <- httpLbs req' manager
  let status = statusCode (responseStatus resp)
  if status >= 200 && status < 300
    then case Aeson.decode (responseBody resp) of
      Just v -> return (Right v)
      Nothing -> return (Left (ApiError status (responseBody resp)))
    else return (Left (ApiError status (responseBody resp)))

-- ---------------------------------------------------------------------------
-- High-level API
-- ---------------------------------------------------------------------------

postApply :: Text -> Value -> IO (Either ApiError Value)
postApply baseUrl = postJson (baseUrl <> "/apply")

getSchemaAgents :: Text -> IO (Either ApiError Value)
getSchemaAgents baseUrl = getJson (baseUrl <> "/katari/agent_definitions")

listAgents :: Text -> IO (Either ApiError Value)
listAgents baseUrl = getJson (baseUrl <> "/agents")

createAgent :: Text -> Value -> IO (Either ApiError Value)
createAgent baseUrl = postJson (baseUrl <> "/agents")

getAgent :: Text -> Text -> IO (Either ApiError Value)
getAgent baseUrl agentId = getJson (baseUrl <> "/agents/" <> agentId)

stopAgent :: Text -> Text -> IO (Either ApiError Value)
stopAgent baseUrl agentId = postJson (baseUrl <> "/agents/" <> agentId <> "/stop") (Aeson.object [])
