-- | @katari mcp@ — the MCP integration verbs.
--
-- @login@ establishes a named OAuth credential for an MCP server, out-of-band of any program.
-- Programs then reference it as @auth = mcp.oauth(name = "...")@; the runtime injects (and
-- refreshes) the tokens itself, so no token material ever appears in Katari source.
--
-- @pull@ generates a typed binding module from a live server: it lists the server's tools through
-- the same node helper and writes one self-contained @.ktr@ module — a @with_tools@ scoped
-- provider handing its continuation one typed wrapper per tool (see "Katari.Cli.McpCodegen" for
-- the codegen contract). Regeneration overwrites the file, so the module is an artifact, never
-- hand-edited.
--
-- The interactive OAuth flow itself (authorization-code + PKCE, dynamic client registration, the
-- loopback redirect listener) lives in the @katari-mcp@ node helper — spawned like @katari-bundle@
-- during apply, with stderr inherited so the user sees the authorization URL and stdout piped so
-- the JSON payload never touches the terminal. @login@'s own job is placement: it stores the
-- helper's blob via the runtime env API as the project secret @mcp.oauth.\<name\>@ (encrypted at
-- rest, write-only over the API — exactly where the runtime's credential store reads and where a
-- token refresh writes back). @pull --oauth@ runs the same flow but keeps the credential in memory
-- for the one listing — nothing is stored.
module Katari.Cli.Command.Mcp
  ( Options (..),
    optionsParser,
    run,
  )
where

import Control.Monad (unless, when)
import Data.Aeson (FromJSON (..), Value, withObject, (.:))
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as TextIO
import GHC.List (List)
import Katari.Cli.Api (setEnv)
import Katari.Cli.Common (RuntimeContext (..), dieIn, dieProgram, resolveNodeHelperInvocation, withRuntimeContext, writeOrExit)
import Katari.Cli.McpCodegen (McpListing, PullContext (..), renderBindingModule)
import Katari.Cli.Options (GlobalOptions, globalOptionsParser)
import Katari.Cli.Output (newOutputContext, progress)
import Options.Applicative
import System.Directory (createDirectoryIfMissing, getCurrentDirectory)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory)
import System.IO (hClose)
import System.Process (CreateProcess (..), StdStream (..), proc, waitForProcess, withCreateProcess)

-- | The two verbs; a group so future ones (@logout@, @status@) slot in beside them.
data Action
  = ActionLogin LoginOptions
  | ActionPull PullOptions
  deriving stock (Show)

data LoginOptions = LoginOptions
  { url :: Text,
    name :: Text,
    scope :: Maybe Text
  }
  deriving stock (Show)

data PullOptions = PullOptions
  { url :: Text,
    out :: FilePath,
    headers :: List Text,
    oauth :: Bool,
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
              <> help "Project the credential belongs to (default: the surrounding katari.toml's [package].name; login only)"
          )
      )
    <*> hsubparser
      ( command "login" (info (ActionLogin <$> loginParser) (progDesc "Run an OAuth login against an MCP server and store the credential as a project secret"))
          <> command "pull" (info (ActionPull <$> pullParser) (progDesc "Generate a typed .ktr binding module from an MCP server's tool listing"))
      )
  where
    loginParser =
      LoginOptions
        <$> strOption (long "url" <> metavar "URL" <> help "The MCP server to authorize against (the url programs pass to mcp.provide)")
        <*> strOption (long "name" <> metavar "NAME" <> help "Credential name programs reference as mcp.oauth(name = ...); stored as the secret mcp.oauth.<NAME>")
        <*> optional (strOption (long "scope" <> metavar "SCOPE" <> help "OAuth scope(s) to request (space-separated, per the server's documentation)"))
    pullParser =
      PullOptions
        <$> strOption (long "url" <> metavar "URL" <> help "The MCP server to pull the tool listing from")
        <*> strOption (long "out" <> metavar "PATH" <> help "The .ktr file to (over)write with the generated binding module")
        <*> many (strOption (long "header" <> metavar "KEY=VALUE" <> help "A header to send on every request (repeatable; e.g. an authorization bearer key)"))
        <*> switch (long "oauth" <> help "Authorize interactively (the same flow as login), keeping the credential in memory — nothing is stored")
        <*> optional (strOption (long "scope" <> metavar "SCOPE" <> help "OAuth scope(s) to request (only with --oauth)"))

run :: Options -> IO ()
run options = case options.action of
  -- Only login needs the runtime (it stores the credential through the env API); pull is local: it
  -- talks to the MCP server via the helper and writes a file, so it must not demand a deployed
  -- project or an API key.
  ActionLogin loginOptions -> do
    context <- withRuntimeContext "mcp" options.global options.projectName
    runLogin context loginOptions
  ActionPull pullOptions -> runPull options.global pullOptions

---------------------------------------------------------------------------------------------------
-- login
---------------------------------------------------------------------------------------------------

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

-- | Run @katari-mcp login@ and return the raw credential text — stored VERBATIM, so nothing the
-- helper captured is lost to a decode/re-encode round-trip. The JSON is still parsed once here, as
-- a shape check with an actionable error instead of a runtime-side decode failure much later.
runKatariMcpLogin :: LoginOptions -> IO Text
runKatariMcpLogin loginOptions = do
  let arguments =
        ["login", "--url", Text.unpack loginOptions.url]
          <> maybe [] (\scope -> ["--scope", Text.unpack scope]) loginOptions.scope
  raw <- Text.strip <$> runKatariMcpHelper arguments "no credential was stored"
  -- The helper exited 0, so JSON that will not decode is a bad payload, not a mis-invocation: an
  -- operation failure (exit 1), not a usage error (exit 2).
  case Aeson.eitherDecodeStrict' (TextEncoding.encodeUtf8 raw) of
    Left decodeError -> dieProgram "mcp" ("katari-mcp returned unparseable JSON: " <> Text.pack decodeError)
    Right (_ :: CredentialBlob) -> pure raw

-- | The shape check for login's stdout: the three fields the runtime's credential store decodes
-- (@tokens@ / @clientInformation@ / @resourceUrl@) must be present. Their contents stay opaque — the
-- stored value is the helper's verbatim text, and the runtime is the authority on token shapes.
data CredentialBlob = CredentialBlob
  { tokens :: Value,
    clientInformation :: Value,
    resourceUrl :: Text
  }

instance FromJSON CredentialBlob where
  parseJSON = withObject "CredentialBlob" $ \object' -> do
    tokens <- object' .: "tokens"
    clientInformation <- object' .: "clientInformation"
    resourceUrl <- object' .: "resourceUrl"
    pure CredentialBlob {tokens, clientInformation, resourceUrl}

---------------------------------------------------------------------------------------------------
-- pull
---------------------------------------------------------------------------------------------------

runPull :: GlobalOptions -> PullOptions -> IO ()
runPull global pullOptions = do
  output <- newOutputContext global
  -- The helper rejects both of these too, but failing here keeps the message in `katari mcp`
  -- vocabulary and avoids spawning node just to be told off. Auth is a sum, not a bag: a server is
  -- reached with explicit headers OR an OAuth credential, never both, so refuse the combination.
  when (pullOptions.oauth && not (null pullOptions.headers)) $
    dieIn "mcp" "--header cannot be combined with --oauth (auth is one or the other)"
  unless (pullOptions.oauth || null pullOptions.scope) $
    dieIn "mcp" "--scope only applies together with --oauth"
  let arguments =
        ["list-tools", "--url", Text.unpack pullOptions.url]
          <> concatMap (\headerPair -> ["--header", Text.unpack headerPair]) pullOptions.headers
          <> ["--oauth" | pullOptions.oauth]
          <> maybe [] (\scope -> ["--scope", Text.unpack scope]) pullOptions.scope
  raw <- runKatariMcpHelper arguments "no module was written"
  -- The helper exited 0, so a listing that will not decode is a bad payload, not a mis-invocation:
  -- that is an operation failure (exit 1), not a usage error (exit 2).
  listing <- case Aeson.eitherDecodeStrict' (TextEncoding.encodeUtf8 (Text.strip raw)) of
    Left decodeError -> dieProgram "mcp" ("katari-mcp returned an unparseable tool listing: " <> Text.pack decodeError)
    Right (decoded :: McpListing) -> pure decoded
  let context =
        PullContext
          { url = pullOptions.url,
            outPath = Text.pack pullOptions.out
          }
      rendered = renderBindingModule context listing
  writeOrExit "mcp" ("could not write " <> Text.pack pullOptions.out) $ do
    createDirectoryIfMissing True (takeDirectory pullOptions.out)
    TextIO.writeFile pullOptions.out rendered
  progress output ("Wrote " <> Text.pack pullOptions.out <> " — import it and open the typed tools with `let tools : {...} = use with_tools(auth = ...)`")

---------------------------------------------------------------------------------------------------
-- the shared helper spawn
---------------------------------------------------------------------------------------------------

-- | Spawn @katari-mcp@ with stderr inherited (the user must see an authorization URL and progress)
-- and stdout piped (the JSON payload is data, not conversation), wait the run out, and return the
-- raw stdout. @failureNote@ names what did NOT happen on a non-zero exit, since the helper already
-- printed its own error to the inherited stderr.
runKatariMcpHelper :: List String -> Text -> IO Text
runKatariMcpHelper arguments failureNote = do
  startDirectory <- getCurrentDirectory
  (helperCommand, prefixArguments) <-
    resolveNodeHelperInvocation "KATARI_MCP_BIN" "katari-mcp" startDirectory >>= \case
      Just invocation -> pure invocation
      Nothing ->
        dieIn
          "mcp"
          ( "the MCP helper (katari-mcp) was not found.\n"
              <> "Install it with `pnpm add @katari-lang/mcp` (or `npm i @katari-lang/mcp`),\n"
              <> "or set KATARI_MCP_BIN to its cli.mjs."
          )
  let process = (proc helperCommand (prefixArguments <> arguments)) {std_in = NoStream, std_out = CreatePipe, std_err = Inherit}
  (exitCode, output) <- withCreateProcess process $ \_ stdoutHandle _ processHandle ->
    case stdoutHandle of
      Nothing -> dieIn "mcp" "could not open a pipe to katari-mcp's stdout"
      Just handle -> do
        -- Drain stdout to EOF before waiting: the payload is small, but reading first is what
        -- makes the wait deadlock-free by construction.
        output <- TextIO.hGetContents handle
        hClose handle
        exitCode <- waitForProcess processHandle
        pure (exitCode, output)
  -- The helper already printed its own error to the inherited stderr; add only the outcome, and
  -- preserve its exit-code split instead of collapsing every failure to "usage": it exits 2 only on
  -- a usage / setup problem (map to dieIn, exit 2), and any other non-zero exit is the flow or
  -- listing failing on its own terms (map to dieProgram, exit 1) — see Common.hs's convention.
  case exitCode of
    ExitSuccess -> pure output
    ExitFailure 2 -> dieIn "mcp" ("katari-mcp exited 2; " <> failureNote)
    ExitFailure code -> dieProgram "mcp" ("katari-mcp exited " <> Text.pack (show code) <> "; " <> failureNote)
