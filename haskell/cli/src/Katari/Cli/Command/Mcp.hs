-- | @katari mcp@ — the MCP integration verbs.
--
-- @pull@ generates a typed binding module from a live server: it lists the server's tools through a
-- node helper and writes one self-contained @.ktr@ module — a @connect@ scoped provider plus one
-- top-level typed agent per tool, the connection's credentials supplied ambiently through a generated
-- @credentials@ request (see "Katari.Cli.McpCodegen" for the codegen contract). A caller writes
-- @use github.connect(auth = ...)@ once and then calls the tools directly. Regeneration overwrites the
-- file, so the module is an artifact, never hand-edited.
--
-- @credentials@ lists the project's stored MCP OAuth credentials, and @forget NAME@ deletes one (to
-- force re-authorization — e.g. when switching accounts). The credentials themselves are established
-- on demand: a program that references @mcp.oauth(name = "...")@ without a stored credential pauses the
-- run on an OAuth authorization escalation, which the operator completes with @katari answer@ (or from
-- the admin console). Nothing about token material ever passes through the CLI.
--
-- The tool-listing helper (@katari-mcp list-tools@) is spawned like @katari-bundle@ during apply, with
-- stderr inherited so the user sees progress and stdout piped so the JSON payload never touches the
-- terminal. It is the only remaining use of the node helper; the interactive OAuth flow now lives
-- entirely in the runtime.
module Katari.Cli.Command.Mcp
  ( Options (..),
    optionsParser,
    run,
  )
where

import Control.Exception (throwIO, try)
import Control.Monad (unless, when)
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as TextIO
import GHC.List (List)
import Katari.Cli.Api (McpCredentialRow (..), RuntimeError (..), deleteMcpCredential, listMcpCredentials)
import Katari.Cli.Common (RuntimeContext (..), dieIn, dieProgram, resolveNodeHelperInvocation, withRuntimeContext, writeOrExit)
import Katari.Cli.McpCodegen (McpListing, PullContext (..), renderBindingModule)
import Katari.Cli.Options (GlobalOptions, globalOptionsParser)
import Katari.Cli.Output (compactTimestamp, newOutputContext, printText, progress, renderTable)
import Options.Applicative
import System.Directory (createDirectoryIfMissing, getCurrentDirectory)
import System.Exit (ExitCode (..))
import System.FilePath (takeBaseName, takeDirectory)
import System.IO (hClose)
import System.Process (CreateProcess (..), StdStream (..), proc, waitForProcess, withCreateProcess)

-- | The verbs, as a group so future ones slot in beside them. @pull@ is local (it talks to the MCP
-- server and writes a file); @credentials@ and @forget@ reach the runtime's credential store.
data Action
  = ActionPull PullOptions
  | ActionCredentials
  | ActionForget ForgetOptions
  deriving stock (Show)

data PullOptions = PullOptions
  { url :: Text,
    out :: FilePath,
    headers :: List Text,
    oauth :: Bool,
    scope :: Maybe Text
  }
  deriving stock (Show)

newtype ForgetOptions = ForgetOptions
  { name :: Text
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
              <> help "Project the credential belongs to (default: the surrounding katari.toml's [package].name; credentials / forget only)"
          )
      )
    <*> hsubparser
      ( command "pull" (info (ActionPull <$> pullParser) (progDesc "Generate a typed .ktr binding module from an MCP server's tool listing"))
          <> command "credentials" (info (pure ActionCredentials) (progDesc "List the project's stored MCP OAuth credentials"))
          <> command "forget" (info (ActionForget <$> forgetParser) (progDesc "Delete a stored MCP OAuth credential (forces re-authorization on next use)"))
      )
  where
    pullParser =
      PullOptions
        <$> strOption (long "url" <> metavar "URL" <> help "The MCP server to pull the tool listing from")
        <*> strOption (long "out" <> metavar "PATH" <> help "The .ktr file to (over)write with the generated binding module")
        <*> many (strOption (long "header" <> metavar "KEY=VALUE" <> help "A header to send on every request (repeatable; e.g. an authorization bearer key)"))
        <*> switch (long "oauth" <> help "Authorize interactively for the one listing, keeping the credential in memory — nothing is stored")
        <*> optional (strOption (long "scope" <> metavar "SCOPE" <> help "OAuth scope(s) to request (only with --oauth)"))
    forgetParser =
      ForgetOptions
        <$> strArgument (metavar "NAME" <> help "The credential name to delete (as referenced by mcp.oauth(name = ...))")

run :: Options -> IO ()
run options = case options.action of
  -- Only pull is local: it talks to the MCP server via the helper and writes a file, so it must not
  -- demand a deployed project or an API key. The store verbs reach the runtime's credential store.
  ActionPull pullOptions -> runPull options.global pullOptions
  ActionCredentials -> do
    context <- withRuntimeContext "mcp" options.global options.projectName
    runCredentials context
  ActionForget forgetOptions -> do
    context <- withRuntimeContext "mcp" options.global options.projectName
    runForget context forgetOptions

---------------------------------------------------------------------------------------------------
-- credentials
---------------------------------------------------------------------------------------------------

-- | List the project's stored MCP OAuth credentials as an aligned table (the same shape as
-- @katari ls env@): the name programs reference and when it was last written.
runCredentials :: RuntimeContext -> IO ()
runCredentials context = do
  credentials <- listMcpCredentials context.client context.projectId
  printText $
    renderTable
      ["NAME", "UPDATED"]
      [[credential.name, compactTimestamp credential.updatedAt] | credential <- credentials]

---------------------------------------------------------------------------------------------------
-- forget
---------------------------------------------------------------------------------------------------

-- | Delete a stored MCP OAuth credential. The name is stripped once and that form is used throughout —
-- validating a stripped copy but deleting the raw argument would 404 on accidental whitespace. A 404
-- means there was nothing to delete, which is a plain "no such credential" rather than a runtime
-- failure, so it is reworded here (exit 2); any other runtime error propagates to the top-level
-- handler unchanged.
runForget :: RuntimeContext -> ForgetOptions -> IO ()
runForget context forgetOptions = do
  credentialName <- case Text.strip forgetOptions.name of
    "" -> dieIn "mcp" "NAME must not be empty"
    stripped -> pure stripped
  result <- try (deleteMcpCredential context.client context.projectId credentialName)
  case result of
    Right () -> progress context.output ("Forgot MCP credential \"" <> credentialName <> "\" in project " <> context.projectName)
    Left (RuntimeHttpError 404 _) -> dieIn "mcp" ("no credential named \"" <> credentialName <> "\" in project " <> context.projectName)
    Left other -> throwIO other

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
  progress output ("Wrote " <> Text.pack pullOptions.out <> " — import it, open the connection with `use " <> moduleQualifierOf pullOptions.out <> "connect(auth = ...)`, then call the tools directly")

-- | The module qualifier a caller writes, from the out path's base name (a Katari module is named
-- after its file): @"github."@ for @src/github.ktr@, or empty for a degenerate path with no base name.
moduleQualifierOf :: FilePath -> Text
moduleQualifierOf path = case Text.pack (takeBaseName path) of
  "" -> ""
  base -> base <> "."

---------------------------------------------------------------------------------------------------
-- the shared helper spawn
---------------------------------------------------------------------------------------------------

-- | Spawn @katari-mcp@ with stderr inherited (the user must see progress) and stdout piped (the JSON
-- payload is data, not conversation), wait the run out, and return the raw stdout. @failureNote@ names
-- what did NOT happen on a non-zero exit, since the helper already printed its own error to the
-- inherited stderr.
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
  -- a usage / setup problem (map to dieIn, exit 2), and any other non-zero exit is the listing
  -- failing on its own terms (map to dieProgram, exit 1) — see Common.hs's convention.
  case exitCode of
    ExitSuccess -> pure output
    ExitFailure 2 -> dieIn "mcp" ("katari-mcp exited 2; " <> failureNote)
    ExitFailure code -> dieProgram "mcp" ("katari-mcp exited " <> Text.pack (show code) <> "; " <> failureNote)
