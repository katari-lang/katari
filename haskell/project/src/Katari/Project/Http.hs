-- | The one HTTP GET used across the package.
--
-- Both network callers — the registry snapshot download ("Katari.Project.Snapshot") and the git
-- tarball download ("Katari.Project.Fetch") — need the same thing: GET a URL, succeed only on 200,
-- and turn every failure (connection error, non-200 status) into a 'ProjectError'. They differ only
-- in which error constructor they want, so that constructor is injected (the same trick
-- 'Katari.Project.Error.readFileOrError' uses for file IO). Cross-cutting HTTP concerns (timeouts,
-- redirects, headers) then have a single home.
module Katari.Project.Http
  ( httpGetBytes,
  )
where

import Control.Exception (SomeException, try)
import Data.ByteString.Lazy qualified as ByteStringLazy
import Data.Text (Text)
import Data.Text qualified as Text
import Katari.Project.Error
  ( ProjectError,
    UrlErrorInfo (..),
    formatException,
  )
import Network.HTTP.Client (Manager, httpLbs, parseRequest, responseBody, responseStatus)
import Network.HTTP.Types.Status (statusCode)

-- | GET @url@ over @manager@, returning the response body on HTTP 200 or a wrapped error otherwise.
-- @toError@ phrases the failure as the caller's own @*HttpError@ so the diagnostic names the right
-- concern (a snapshot vs a dependency download).
httpGetBytes ::
  Manager ->
  Text ->
  (UrlErrorInfo -> ProjectError) ->
  IO (Either ProjectError ByteStringLazy.ByteString)
httpGetBytes manager url toError = do
  result <- try $ do
    request <- parseRequest (Text.unpack url)
    httpLbs request manager
  pure $ case result of
    Left exception ->
      Left (toError UrlErrorInfo {url = url, message = formatException (exception :: SomeException)})
    Right response ->
      let status = statusCode (responseStatus response)
       in if status == 200
            then Right (responseBody response)
            else Left (toError UrlErrorInfo {url = url, message = "HTTP status " <> Text.pack (show status)})
