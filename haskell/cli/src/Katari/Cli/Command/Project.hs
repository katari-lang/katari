-- | @katari project remove [NAME]@ — delete a project and everything under it on the runtime.
--
-- The one destructive command, so it confirms interactively; non-interactive sessions must say
-- @--force@ (a script cannot "accidentally" answer yes). Listing lives under @katari ls projects@.
module Katari.Cli.Command.Project
  ( Options (..),
    optionsParser,
    run,
  )
where

import Control.Applicative ((<|>))
import Data.Text (Text)
import Katari.Cli.Api (deleteProject)
import Katari.Cli.Common (dieIn, makeRuntimeClient, requireProjectId, tryLoadNearestConfig)
import Katari.Cli.Options (GlobalOptions, globalOptionsParser)
import Katari.Cli.Output (OutputContext (..), newOutputContext, progress)
import Katari.Cli.Prompt (confirm)
import Katari.Project.Config (PackageSection (..), ProjectConfig (..))
import Options.Applicative hiding ((<|>))

newtype Action = ActionRemove RemoveOptions
  deriving stock (Show)

data RemoveOptions = RemoveOptions
  { projectName :: Maybe Text,
    force :: Bool
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
      )
  where
    removeParser =
      RemoveOptions
        <$> optional (strArgument (metavar "NAME" <> help "Project name (default: the surrounding katari.toml's [package].name)"))
        <*> switch (long "force" <> help "Skip the confirmation (required when not interactive)")

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
