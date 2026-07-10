-- | @katari mcp login@ — establish a named OAuth credential for an MCP server, out-of-band of any
-- program. Programs then reference it as @auth = mcp.oauth(name = "...")@; the runtime injects (and
-- refreshes) the tokens itself, so no token material ever appears in Katari source.
--
-- The OAuth flow itself (authorization-code + PKCE, dynamic client registration, the loopback
-- redirect listener) lives in the @katari-mcp@ node helper — spawned like @katari-bundle@ during
-- apply, with stderr inherited so the user sees the authorization URL and stdout piped so the
-- credential JSON never touches the terminal. This command's own job is placement: it stores the
-- helper's blob via the runtime env API as the project secret @mcp.oauth.\<name\>@ (encrypted at
-- rest, write-only over the API — exactly where the runtime's credential store reads and where a
-- token refresh writes back).
module Katari.Cli.Command.Mcp
  ( Options (..),
    optionsParser,
    run,
  )
where

import Data.Aeson (FromJSON (..), Value, withObject, (.:))
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as TextIO
import GHC.List (List)
import Katari.Cli.Api (setEnv)
import Katari.Cli.Common (RuntimeContext (..), dieIn, resolveNodeHelperInvocation, withRuntimeContext)
import Katari.Cli.Options (GlobalOptions, globalOptionsParser)
import Katari.Cli.Output (OutputContext (..), progress)
import Options.Applicative
import System.Directory (getCurrentDirectory)
import System.Exit (ExitCode (..))
import System.IO (hClose)
import System.Process (CreateProcess (..), StdStream (..), proc, waitForProcess, withCreateProcess)

-- | The one verb so far; a group so future verbs (@logout@, @status@) slot in beside it.
newtype Action
  = ActionLogin LoginOptions
  deriving stock (Show)

data LoginOptions = LoginOptions
  { url :: Text,
    name :: Text,
    scope :: Maybe Text
  }
  deriving stock (Show)

data Options = Options
  { global :: GlobalOptions,
    projectName :: Maybe Text,
    action :: Action
  }
  deriving stock (Show)

optionsParser :: Parser Options
optionsParser =
  Options
    <$> globalOptionsParser
    <*> optional
      ( strOption
          ( long "project"
              <> metavar "NAME"
              <> help "Project the credential belongs to (default: the surrounding katari.toml's [package].name)"
          )
      )
    <*> hsubparser
      ( command "login" (info (ActionLogin <$> loginParser) (progDesc "Run an OAuth login against an MCP server and store the credential as a project secret"))
      )
  where
    loginParser =
      LoginOptions
        <$> strOption (long "url" <> metavar "URL" <> help "The MCP server to authorize against (the url programs pass to mcp.tools)")
        <*> strOption (long "name" <> metavar "NAME" <> help "Credential name programs reference as mcp.oauth(name = ...); stored as the secret mcp.oauth.<NAME>")
        <*> optional (strOption (long "scope" <> metavar "SCOPE" <> help "OAuth scope(s) to request (space-separated, per the server's documentation)"))

run :: Options -> IO ()
run options = do
  context <- withRuntimeContext "mcp" options.global options.projectName
  case options.action of
    ActionLogin loginOptions -> runLogin context loginOptions

runLogin :: RuntimeContext -> LoginOptions -> IO ()
runLogin context loginOptions = do
  -- The credential name becomes part of an env key; an empty one would store an unreferenceable
  -- `mcp.oauth.` entry, so refuse it before any interaction happens.
  case Text.strip loginOptions.name of
    "" -> dieIn "mcp" "--name must not be empty"
    _ -> pure ()
  credentialJson <- runKatariMcpLogin loginOptions
  let key = "mcp.oauth." <> loginOptions.name
  setEnv context.client context.projectId key credentialJson True
  progress context.output ("Stored OAuth credential " <> key <> " (secret) in project " <> context.projectName)
  progress context.output ("Programs reference it as: auth = mcp.oauth(name = \"" <> loginOptions.name <> "\")")

-- | Spawn @katari-mcp login@ with stderr inherited (the user must see the authorization URL and any
-- progress) and stdout piped (the credential JSON is data, not conversation), wait out the
-- interactive flow, and return the raw credential text — stored VERBATIM, so nothing the helper
-- captured is lost to a decode/re-encode round-trip. The JSON is still parsed once here, as a
-- shape check with an actionable error instead of a runtime-side decode failure much later.
runKatariMcpLogin :: LoginOptions -> IO Text
runKatariMcpLogin loginOptions = do
  startDirectory <- getCurrentDirectory
  (helperCommand, prefixArguments) <-
    resolveNodeHelperInvocation "KATARI_MCP_BIN" "katari-mcp" startDirectory >>= \case
      Just invocation -> pure invocation
      Nothing ->
        dieIn
          "mcp"
          ( "the OAuth login helper (katari-mcp) was not found.\n"
              <> "Install it with `pnpm add @katari-lang/mcp` (or `npm i @katari-lang/mcp`),\n"
              <> "or set KATARI_MCP_BIN to its cli.mjs."
          )
  let arguments =
        prefixArguments
          <> ["login", "--url", Text.unpack loginOptions.url]
          <> maybe [] (\scope -> ["--scope", Text.unpack scope]) loginOptions.scope
      process = (proc helperCommand arguments) {std_in = NoStream, std_out = CreatePipe, std_err = Inherit}
  (exitCode, output) <- withCreateProcess process $ \_ stdoutHandle _ processHandle ->
    case stdoutHandle of
      Nothing -> dieIn "mcp" "could not open a pipe to katari-mcp's stdout"
      Just handle -> do
        -- Drain stdout to EOF before waiting: the credential is small, but reading first is what
        -- makes the wait deadlock-free by construction.
        output <- TextIO.hGetContents handle
        hClose handle
        exitCode <- waitForProcess processHandle
        pure (exitCode, output)
  case exitCode of
    ExitFailure code ->
      -- The helper already printed its own error to the inherited stderr; add only the outcome.
      dieIn "mcp" ("katari-mcp exited " <> Text.pack (show code) <> "; no credential was stored")
    ExitSuccess -> do
      let raw = Text.strip output
      case Aeson.eitherDecodeStrict' (TextEncoding.encodeUtf8 raw) of
        Left decodeError -> dieIn "mcp" ("katari-mcp returned unparseable JSON: " <> Text.pack decodeError)
        Right (_ :: CredentialBlob) -> pure raw

-- | The shape check for the helper's stdout: the three fields the runtime's credential store decodes
-- (@tokens@ / @clientInformation@ / @resourceUrl@) must be present. Their contents stay opaque — the
-- stored value is the helper's verbatim text, and the runtime is the authority on token shapes.
data CredentialBlob = CredentialBlob
  { tokens :: Value,
    clientInformation :: Value,
    resourceUrl :: Text
  }

instance FromJSON CredentialBlob where
  parseJSON = withObject "CredentialBlob" $ \object' ->
    CredentialBlob
      <$> object' .: "tokens"
      <*> object' .: "clientInformation"
      <*> object' .: "resourceUrl"
