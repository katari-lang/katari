-- | @katari add PKG...@ / @katari remove PKG...@ — edit @[dependencies].packages@ and re-lock.
--
-- The two commands share everything but their direction, so they live in one module under a 'Mode'.
-- The flow guards heavily before touching the file:
--
--   1. Validate the request against the config: @add@ requires every new package to be resolvable
--      (a root override, or present in the pinned registry snapshot); @remove@ requires each name to
--      be declared and not still pinned by an @[overrides]@ entry (removing it would leave a config
--      that no longer validates).
--   2. Rewrite only the @packages@ array via "Katari.Project.Edit" (format-preserving).
--   3. Re-parse the rewritten text and require the decoded list to match — the final gate that turns
--      any editor blind spot into an abort instead of a corrupted @katari.toml@.
--   4. Write, then re-resolve over the network and refresh @katari.lock@.
module Katari.Cli.Command.Add
  ( Mode (..),
    Options (..),
    optionsParser,
    run,
  )
where

import Control.Monad (forM_, unless, when)
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import GHC.List (List)
import Katari.Cli.Common (dieIn, dieInternal, resolveProjectRoot, warnCompilerMismatch, writeOrExit)
import Katari.Cli.Options (GlobalOptions, globalOptionsParser)
import Katari.Cli.Output (newOutputContext, progress)
import Katari.Project.Config (DependenciesSection (..), ProjectConfig (..), loadKatariTomlLenient, parseKatariToml)
import Katari.Project.Discovery (configFilename)
import Katari.Project.Edit (renderEditError, rewritePackages)
import Katari.Project.Error (renderProjectError)
import Katari.Project.Lockfile (lockfileFilename, writeLockfile)
import Katari.Project.Resolve (lockfileFromResolved, resolveProject)
import Katari.Project.Snapshot (Snapshot (..), loadSnapshotFromUrl)
import Network.HTTP.Client (Manager)
import Network.HTTP.Client.TLS (newTlsManager)
import Options.Applicative
import System.FilePath ((</>))

-- | Which direction the edit goes.
data Mode = ModeAdd | ModeRemove
  deriving stock (Show, Eq)

data Options = Options
  { global :: GlobalOptions,
    projectRoot :: Maybe FilePath,
    packages :: List Text
  }
  deriving stock (Show)

optionsParser :: Parser Options
optionsParser =
  Options
    <$> globalOptionsParser
    <*> optional
      ( strOption
          ( long "project"
              <> short 'p'
              <> metavar "DIR"
              <> help "Project root (the directory containing katari.toml). Defaults to walking up from the current directory."
          )
      )
    <*> some (strArgument (metavar "PKG..." <> help "Package name(s) from the pinned registry snapshot (or a root [overrides] entry)"))

run :: Mode -> Options -> IO ()
run mode options = do
  let subcommand = case mode of
        ModeAdd -> "add"
        ModeRemove -> "remove"
  context <- newOutputContext options.global
  root <- resolveProjectRoot subcommand options.projectRoot
  let configPath = root </> configFilename
  -- The lenient load accepts an [overrides.X] whose X is not declared yet — the natural state right
  -- before `katari add X` declares it. Every other path (check/build/apply/resolve) stays strict.
  config <-
    loadKatariTomlLenient configPath >>= \case
      Left projectError -> dieIn subcommand (renderProjectError projectError)
      Right loaded -> pure loaded

  let requested = nub options.packages
      declared = config.dependencies.packages
  manager <- newTlsManager
  newList <- case mode of
    ModeAdd -> do
      let fresh = [name | name <- requested, name `notElem` declared]
      forM_ [name | name <- requested, name `elem` declared] $ \name ->
        progress context (name <> " is already declared")
      requireResolvable subcommand manager config fresh
      pure (declared <> fresh)
    ModeRemove -> do
      forM_ requested $ \name -> do
        unless (name `elem` declared) $
          dieIn subcommand (name <> " is not declared in [dependencies].packages")
        when (Map.member name config.overrides) $
          dieIn subcommand ("remove the [overrides." <> name <> "] entry first (an override may not name an undeclared dependency)")
      pure (filter (`notElem` requested) declared)

  when (newList == declared) $ do
    progress context "nothing to change"
  unless (newList == declared) $ do
    original <- TextIO.readFile configPath
    rewritten <- case rewritePackages original newList of
      Left editError -> dieIn subcommand (renderEditError editError)
      Right text -> pure text
    -- The final gate: the rewritten file must parse and decode to exactly the intended list, or the
    -- edit never lands on disk.
    case parseKatariToml configPath rewritten of
      Left projectError ->
        dieInternal subcommand ("the rewritten katari.toml no longer parses: " <> renderProjectError projectError)
      Right reparsed ->
        unless (reparsed.dependencies.packages == newList) $
          dieInternal subcommand "the rewritten katari.toml decodes to a different package list"
    writeOrExit subcommand "could not write katari.toml" (TextIO.writeFile configPath rewritten)

  -- Re-resolve the (possibly unchanged) closure and refresh the lock, so `check` and `build` see the
  -- new set immediately.
  resolved <-
    resolveProject manager root >>= \case
      Left projectError -> dieIn subcommand (renderProjectError projectError)
      Right loaded -> pure loaded
  writeOrExit subcommand "could not write lockfile" $
    writeLockfile (root </> lockfileFilename) (lockfileFromResolved resolved)
  warnCompilerMismatch context resolved
  case mode of
    ModeAdd -> progress context ("Added: " <> renderNames requested)
    ModeRemove -> progress context ("Removed: " <> renderNames requested)
  where
    renderNames names = case names of
      [] -> "(nothing)"
      _ -> Text.intercalate ", " names

-- | Every package @add@ introduces must come from somewhere: a root override wins, otherwise the
-- pinned registry snapshot must hold it. Checked before the file is touched.
requireResolvable :: Text -> Manager -> ProjectConfig -> List Text -> IO ()
requireResolvable subcommand manager config names = do
  let fromSnapshot = [name | name <- names, not (Map.member name config.overrides)]
  case fromSnapshot of
    [] -> pure ()
    _ -> case config.dependencies.registry of
      Nothing ->
        dieIn subcommand ("no [dependencies].registry configured, and no [overrides] entry for: " <> Text.intercalate ", " fromSnapshot)
      Just registry -> do
        snapshot <-
          loadSnapshotFromUrl manager registry config.dependencies.snapshot >>= \case
            Left projectError -> dieIn subcommand (renderProjectError projectError)
            Right loaded -> pure loaded
        forM_ fromSnapshot $ \name ->
          unless (Map.member name snapshot.packages) $
            dieIn subcommand (name <> " is not in the pinned registry snapshot")
