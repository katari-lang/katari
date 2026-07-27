-- | @katari update [SNAPSHOT]@ — re-pin @[dependencies].snapshot@ and re-lock.
--
-- Moving to a newer package set used to take three steps and one piece of knowledge you had no way
-- to get: find out what the newest snapshot is called, hand-edit @katari.toml@, then re-lock. The
-- name is unguessable on purpose (its @\<8-hex>@ tail is a content hash), so "what is newest" has to
-- come from the registry's index — which is what this reads when no @SNAPSHOT@ is given.
--
-- It sits beside @add@ / @remove@ rather than behind a flag on @lock@ because it does what they do:
-- it edits @katari.toml@. A command that changes the manifest and then reconciles the lock is one
-- kind of thing; @lock@, which only ever reconciles, is another. Naming an explicit @SNAPSHOT@ moves
-- the pin anywhere the registry can serve — including back to an older cut, or to the mutable
-- @staging@ set — so the same mechanism covers rolling forward and rolling back.
module Katari.Cli.Command.Update
  ( Options (..),
    optionsParser,
    run,
  )
where

import Control.Monad (unless)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text.IO qualified as TextIO
import Katari.Cli.Common (dieIn, dieInternal, resolveProjectRoot, warnCompilerMismatch, writeLockOrExit, writeOrExit)
import Katari.Cli.Options (GlobalOptions, directoryOption, globalOptionsParser)
import Katari.Cli.Output (OutputContext, newOutputContext, progress)
import Katari.Project.Config (DependenciesSection (..), ProjectConfig (..), loadKatariToml, parseKatariToml)
import Katari.Project.Discovery (configFilename)
import Katari.Project.Edit (renderEditError, rewriteSnapshot)
import Katari.Project.Error (renderProjectError)
import Katari.Project.Snapshot
  ( Snapshot (..),
    SnapshotIndex,
    SnapshotIndexEntry (..),
    loadSnapshotFromUrl,
    loadSnapshotIndexFromUrl,
    newestSnapshot,
  )
import Network.HTTP.Client (Manager)
import Network.HTTP.Client.TLS (newTlsManager)
import Options.Applicative
import System.FilePath ((</>))

data Options = Options
  { global :: GlobalOptions,
    projectRoot :: Maybe FilePath,
    snapshot :: Maybe Text
  }
  deriving stock (Show)

optionsParser :: Parser Options
optionsParser =
  Options
    <$> globalOptionsParser
    <*> directoryOption
    <*> optional
      ( strArgument
          ( metavar "SNAPSHOT"
              <> help "Snapshot to pin (default: the newest cut in the registry's index; \"staging\" for the mutable candidate set)"
          )
      )

run :: Options -> IO ()
run options = do
  context <- newOutputContext options.global
  root <- resolveProjectRoot "update" options.projectRoot
  let configPath = root </> configFilename
  config <-
    loadKatariToml configPath >>= \case
      Left projectError -> dieIn "update" (renderProjectError projectError)
      Right loaded -> pure loaded
  registry <- case config.dependencies.registry of
    Just registry -> pure registry
    Nothing -> dieIn "update" "no [dependencies].registry configured, so there is no registry to take a snapshot from"

  manager <- newTlsManager
  target <- case options.snapshot of
    Just explicit -> pure explicit
    Nothing -> newestFromIndex manager registry

  if config.dependencies.snapshot == Just target
    then progress context ("Already pinned to " <> target)
    else do
      -- Guard before touching the file, the way `add` does: a pin that names a set the registry
      -- cannot serve would leave katari.toml broken and the closure unresolvable.
      pinned <- requireServable manager registry target
      warnCompilerMismatch context pinned.compilerVersion
      rewritePin context configPath config target

  -- Always re-lock, even when the pin did not move: `staging` is mutable, so re-freezing what it
  -- holds right now is a real change to the closure even though the manifest reads the same.
  _ <- writeLockOrExit "update" context manager root
  pure ()

-- | The newest cut the registry publishes. Reads the index, never the directory: a registry is
-- reached over a plain file base URL that cannot be listed, and the snapshot filenames carry no
-- order to sort on anyway.
newestFromIndex :: Manager -> Text -> IO Text
newestFromIndex manager registry = do
  index <- loadIndexOrExit manager registry
  case newestSnapshot index of
    Just entry -> pure entry.name
    Nothing -> dieIn "update" "the registry's snapshot index lists no cuts; name a snapshot explicitly"

loadIndexOrExit :: Manager -> Text -> IO SnapshotIndex
loadIndexOrExit manager registry =
  loadSnapshotIndexFromUrl manager registry >>= \case
    Left projectError -> dieIn "update" (renderProjectError projectError)
    Right index -> pure index

-- | Load the snapshot the new pin names, proving the registry can serve it before the manifest is
-- edited to point at it.
requireServable :: Manager -> Text -> Text -> IO Snapshot
requireServable manager registry target =
  loadSnapshotFromUrl manager registry (Just target) >>= \case
    Left projectError -> dieIn "update" (renderProjectError projectError)
    Right snapshot -> pure snapshot

-- | Rewrite @[dependencies].snapshot@ in place, then re-parse and require the decoded pin to be the
-- one intended — the same final gate @add@ uses, so any blind spot in the text edit aborts instead of
-- landing a corrupted @katari.toml@.
rewritePin :: OutputContext -> FilePath -> ProjectConfig -> Text -> IO ()
rewritePin context configPath config target = do
  original <- TextIO.readFile configPath
  rewritten <- case rewriteSnapshot original target of
    Left editError -> dieIn "update" (renderEditError editError)
    Right text -> pure text
  case parseKatariToml configPath rewritten of
    Left projectError ->
      dieInternal "update" ("the rewritten katari.toml no longer parses: " <> renderProjectError projectError)
    Right reparsed ->
      unless (reparsed.dependencies.snapshot == Just target) $
        dieInternal "update" "the rewritten katari.toml decodes to a different snapshot pin"
  writeOrExit "update" "could not write katari.toml" (TextIO.writeFile configPath rewritten)
  progress context ("Re-pinned " <> fromMaybe "(no snapshot)" config.dependencies.snapshot <> " -> " <> target)
