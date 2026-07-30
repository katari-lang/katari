-- | The one HTTP GET used across the package.
--
-- Both network callers — the registry snapshot download ("Katari.Project.Snapshot") and the git
-- tarball download ("Katari.Project.Fetch") — need the same thing: GET a URL, succeed only on 200,
-- and turn every failure (connection error, non-200 status) into a 'ProjectError'. They differ only
-- in which error constructor they want, so that constructor is injected (the same trick
-- 'Katari.Project.Error.readFileOrError' uses for file IO). Cross-cutting HTTP concerns (timeouts,
-- redirects, headers) then have a single home.
--
-- Everything this module downloads is attacker-controlled until something downstream has hashed it, so
-- the transfer itself is bounded here: a response body larger than 'maximumBodyBytes' is abandoned
-- mid-stream, and a server that accepts the connection then goes quiet hits 'headerTimeoutMicroseconds'
-- instead of hanging the command. Neither bound belongs to a caller — a caller only learns what it got
-- after it has already been paid for.
module Katari.Project.Http
  ( httpGetBytes,
    maximumBodyBytes,
    readBodyWithinCap,
  )
where

import Control.Exception (SomeException, try)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as ByteStringLazy
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.List (List)
import Katari.Project.Error
  ( ProjectError,
    UrlErrorInfo (..),
    formatException,
  )
import Network.HTTP.Client
  ( BodyReader,
    Manager,
    brRead,
    parseRequest,
    responseBody,
    responseStatus,
    responseTimeout,
    responseTimeoutMicro,
    withResponse,
  )
import Network.HTTP.Types.Status (statusCode)

-- | The largest response body this package will hold. Everything it downloads is source code or a
-- small TOML file, so 64 MiB is orders of magnitude above any legitimate payload; the cap exists
-- because a pin is verified /after/ the bytes arrive, so a hostile registry (or a redirect to one) can
-- otherwise fill a developer's or CI runner's disk with a body no hash check will ever get to reject.
maximumBodyBytes :: Int
maximumBodyBytes = 64 * 1024 * 1024

-- | How long to wait for a server to return its status line and headers. This is @http-client@'s
-- 'responseTimeout', which covers connecting and the header exchange but not the body transfer — the
-- body is bounded by 'maximumBodyBytes' instead. Two minutes is far past any real registry's latency
-- while still ending a command that would otherwise wait forever on a black hole.
headerTimeoutMicroseconds :: Int
headerTimeoutMicroseconds = 120 * 1000 * 1000

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
    -- 'withResponse' rather than 'httpLbs': the body has to be read in chunks for the size cap to mean
    -- anything, since httpLbs has already buffered the whole thing by the time it returns.
    withResponse request {responseTimeout = responseTimeoutMicro headerTimeoutMicroseconds} manager $ \response ->
      case statusCode (responseStatus response) of
        200 -> readBodyWithinCap maximumBodyBytes (responseBody response)
        status -> pure (Left ("HTTP status " <> Text.pack (show status)))
  pure $ case result of
    Left exception ->
      Left (toError UrlErrorInfo {url = url, message = formatException (exception :: SomeException)})
    Right (Left message) -> Left (toError UrlErrorInfo {url = url, message = message})
    Right (Right body) -> Right body

-- | Accumulate a response body, stopping as soon as it exceeds @cap@ bytes. Refusing mid-stream is the
-- point: the cost of an over-long body is then the cap and not the whole transfer.
--
-- The cap is an argument rather than a reference to 'maximumBodyBytes' so that this — the part with the
-- off-by-one to get wrong — is exercisable against a handful of bytes instead of against 64 MiB of
-- them. 'httpGetBytes' is the only production caller and passes 'maximumBodyBytes'.
readBodyWithinCap :: Int -> BodyReader -> IO (Either Text ByteStringLazy.ByteString)
readBodyWithinCap cap reader = go 0 []
  where
    go :: Int -> List ByteString.ByteString -> IO (Either Text ByteStringLazy.ByteString)
    go readSoFar chunks = do
      chunk <- brRead reader
      if ByteString.null chunk
        then pure (Right (ByteStringLazy.fromChunks (reverse chunks)))
        else
          let total = readSoFar + ByteString.length chunk
           in if total > cap
                then
                  pure
                    ( Left
                        ( "response body exceeds the "
                            <> Text.pack (show cap)
                            <> " byte limit katari downloads"
                        )
                    )
                else go total (chunk : chunks)
