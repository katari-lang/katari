-- | @katari project remove|rollback@ — project-level operations on the runtime.
--
-- @remove@ deletes a project and everything under it; the one fully destructive command, so it
-- confirms interactively and non-interactive sessions must say @--force@ (a script cannot
-- "accidentally" answer yes). @rollback@ moves the live head to an earlier (or later — snapshots
-- are immutable, the head is just a pointer) snapshot; only new runs follow the moved head.
-- Listing lives under @katari ls projects@ / @katari ls snapshots@.
module Katari.Cli.Command.Project
  ( Options (..),
    optionsParser,
    run,
  )
where

import Control.Applicative ((<|>))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Katari.Cli.Api (SnapshotRow (..), deleteProject, listSnapshots, setSnapshotHead)
import Katari.Cli.Common (RuntimeContext (..), dieIn, makeRuntimeClient, renderPrefixError, requireProjectId, resolveIdPrefix, tryLoadNearestConfig, withRuntimeContext)
import Katari.Cli.Options (GlobalOptions, globalOptionsParser)
import Katari.Cli.Output (OutputContext (..), newOutputContext, progress)
import Katari.Cli.Prompt (confirm)
import Katari.Project.Config (PackageSection (..), ProjectConfig (..))
import Options.Applicative hiding ((<|>))

data Action
  = ActionRemove RemoveOptions
  | ActionRollback RollbackOptions
  deriving stock (Show)

data RemoveOptions = RemoveOptions
  { projectName :: Maybe Text,
    force :: Bool
  }
  deriving stock (Show)

data RollbackOptions = RollbackOptions
  { snapshotId :: Text,
    projectName :: Maybe Text
  }
  deriving stock (Show)

data Options = Options
  { global :: GlobalOptions,
    action :: Action
  }
  deriving stock (Show)

optionsParser :: Parser Options
optionsParser =
  Options
    <$> globalOptionsParser
    <*> hsubparser
      ( command
          "remove"
          (info (ActionRemove <$> removeParser) (progDesc "Delete a project and all of its data on the runtime"))
          <> command
            "rollback"
            (info (ActionRollback <$> rollbackParser) (progDesc "Move the live head to an existing snapshot (new runs follow it)"))
      )
  where
    removeParser =
      RemoveOptions
        <$> optional (strArgument (metavar "NAME" <> help "Project name (default: the surrounding katari.toml's [package].name)"))
        <*> switch (long "force" <> help "Skip the confirmation (required when not interactive)")
    rollbackParser =
      RollbackOptions
        <$> strArgument (metavar "SNAPSHOT" <> help "Snapshot id, or a unique prefix of one (see `katari ls snapshots`)")
        <*> optional (strOption (long "project" <> metavar "NAME" <> help "Project the snapshot belongs to (default: the surrounding katari.toml's [package].name)"))

run :: Options -> IO ()
run options = case options.action of
  ActionRemove removeOptions -> do
    output <- newOutputContext options.global
    config <- tryLoadNearestConfig "project"
    name <- case removeOptions.projectName <|> fmap (\projectConfig -> projectConfig.package.name) config of
      Just given -> pure given
      Nothing -> dieIn "project" "no NAME given and no katari.toml found in this or any parent directory"
    client <- makeRuntimeClient "project" options.global output config
    projectId <- requireProjectId "project" client name
    confirmed <-
      if removeOptions.force
        then pure True
        else
          if output.interactive
            then do
              answered <- confirm output ("delete project " <> name <> " and ALL of its runs, snapshots, env and files?") False
              pure (answered == Just True)
            else dieIn "project" "refusing to delete without confirmation; pass --force"
    if confirmed
      then do
        deleteProject client projectId
        progress output ("Deleted project " <> name)
      else dieIn "project" "cancelled"
  ActionRollback rollbackOptions -> do
    context <- withRuntimeContext "project" options.global rollbackOptions.projectName
    (_, snapshots) <- listSnapshots context.client context.projectId
    target <-
      either
        (dieIn "project" . renderPrefixError rollbackOptions.snapshotId)
        pure
        (resolveIdPrefix rollbackOptions.snapshotId (map (\row -> row.id) snapshots))
    setSnapshotHead context.client context.projectId target
    let message = fromMaybe "" (lookup target (map (\row -> (row.id, fromMaybe "" row.message)) snapshots))
    progress context.output ("Head is now " <> target <> (if message == "" then "" else " (" <> message <> ")"))
