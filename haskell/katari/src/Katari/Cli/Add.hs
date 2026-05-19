-- | @katari add@ — append a path dependency to the current
-- @katari.toml@.
--
-- v1 only handles @path = "..."@ dependencies. Once the registry +
-- lockfile machinery lands (PM-3 / PM-4) this will also know how to
-- write @"\*"@ entries that resolve through the snapshot.
--
-- Append-only: we don't try to round-trip the TOML through a parser,
-- so user formatting and comments survive the edit. Pre-existing
-- dependencies under the same name are rejected with an explicit
-- error rather than silently overwritten.
module Katari.Cli.Add
  ( Options (..),
    optionsParser,
    run,
  )
where

import Control.Monad (unless, when)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import qualified Katari.Project.Config as Project
import qualified Katari.Project.Discovery as Project
import Options.Applicative
import System.Directory (doesDirectoryExist, doesFileExist, getCurrentDirectory)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)

data Options = Options
  { optName :: String,
    optPath :: FilePath,
    optProjectRoot :: Maybe FilePath
  }
  deriving (Show)

optionsParser :: Parser Options
optionsParser =
  Options
    <$> argument str (metavar "NAME" <> help "Dependency name (= what consumers type after `import`)")
    <*> strOption
      ( long "path"
          <> metavar "PATH"
          <> help "Local path to the dependency's package root (the directory containing its katari.toml)"
      )
    <*> optional
      ( strOption
          ( long "project"
              <> short 'p'
              <> metavar "DIR"
              <> help "Project root (defaults to walking up from the current directory)"
          )
      )

run :: Options -> IO ()
run opts = do
  -- Locate the consumer's katari.toml.
  start <- maybe getCurrentDirectory pure opts.optProjectRoot
  mRoot <- Project.findProjectRoot start
  rootDir <- case mRoot of
    Just r -> pure r
    Nothing -> die "no katari.toml found in this or any parent directory"
  let consumerToml = rootDir </> Project.configFilename
  consumerCfg <- loadOrDie consumerToml

  -- Validate the dep name we're about to write (= consumers will type
  -- this after @import@, so it must be a Katari identifier).
  validateIdentifier opts.optName

  -- Reject duplicate dep names so this command is non-destructive.
  when (Map.member (Text.pack opts.optName) consumerCfg.dependencies) $
    die ("dependency '" <> opts.optName <> "' already declared in " <> consumerToml)

  -- Resolve the dep's path + verify it points at a real package.
  depCfg <- verifyDepTarget rootDir opts.optPath opts.optName

  -- Append the entry to the consumer's katari.toml. We write the raw
  -- argument back verbatim so the user's choice (relative vs absolute)
  -- survives the round-trip.
  let entry = renderDepEntry opts.optName opts.optPath
  TextIO.appendFile consumerToml entry
  putStrLn
    ( "Added [dependencies."
        <> opts.optName
        <> "] -> "
        <> opts.optPath
        <> " (package "
        <> Text.unpack depCfg.packageSection.packageName
        <> ") to "
        <> consumerToml
    )

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

die :: String -> IO a
die msg = do
  hPutStrLn stderr ("katari add: " <> msg)
  exitWith (ExitFailure 2)

loadOrDie :: FilePath -> IO Project.ProjectConfig
loadOrDie path = do
  r <- Project.loadKatariToml path
  case r of
    Right cfg -> pure cfg
    Left err -> die (show err)

validateIdentifier :: String -> IO ()
validateIdentifier name = do
  when (null name) $ die "NAME must be non-empty"
  unless (validHead (head name)) $
    die "NAME must start with a letter or underscore"
  unless (all validChar name) $
    die "NAME may only contain letters, digits, and underscores"
  where
    validHead c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
    validChar c = validHead c || (c >= '0' && c <= '9')

verifyDepTarget :: FilePath -> FilePath -> String -> IO Project.ProjectConfig
verifyDepTarget rootDir depPathRaw declaredName = do
  let absDepPath = if isAbs depPathRaw then depPathRaw else rootDir </> depPathRaw
  dirExists <- doesDirectoryExist absDepPath
  unless dirExists $ die ("path does not exist or is not a directory: " <> depPathRaw)
  let depToml = absDepPath </> Project.configFilename
  hasToml <- doesFileExist depToml
  unless hasToml $ die ("no katari.toml at " <> depToml)
  depCfg <- loadOrDie depToml
  let actualName = Text.unpack depCfg.packageSection.packageName
  unless (actualName == declaredName) $
    die
      ( "dep name mismatch: declaring '"
          <> declaredName
          <> "' but the target package is named '"
          <> actualName
          <> "' (per the [package].name in "
          <> depToml
          <> ")"
      )
  pure depCfg
  where
    -- @System.FilePath.isAbsolute@ would do, but importing one helper for one
    -- call would dwarf this module's import list. The Linux assumption is
    -- safe on this codebase.
    isAbs ('/' : _) = True
    isAbs _ = False

renderDepEntry :: String -> FilePath -> Text
renderDepEntry name path =
  Text.pack $
    "\n[dependencies." <> name <> "]\n" <> "path = \"" <> path <> "\"\n"
