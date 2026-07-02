-- | @katari check@ — compile the project and report diagnostics, writing nothing.
--
-- Resolution is offline (disk + cache only), like @build@: a diagnostics command must be
-- deterministic and never block on the network. A project whose dependencies are not locked yet gets
-- a specific remedy instead of a bare failure.
module Katari.Cli.Command.Check
  ( Options (..),
    optionsParser,
    run,
  )
where

import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Katari.Cli.Common (assembleSourcesOrExit, compileSourcesOrExit, dieIn, resolveProjectRoot)
import Katari.Cli.Options (GlobalOptions, globalOptionsParser)
import Katari.Cli.Output (newOutputContext, progress)
import Katari.Project.Discovery (emptyOverlay)
import Katari.Project.Error (ProjectError (..), renderProjectError)
import Katari.Project.Resolve (loadProjectOffline)
import Options.Applicative

data Options = Options
  { global :: GlobalOptions,
    projectRoot :: Maybe FilePath
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

run :: Options -> IO ()
run options = do
  context <- newOutputContext options.global
  root <- resolveProjectRoot "check" options.projectRoot
  resolved <-
    loadProjectOffline emptyOverlay root >>= \case
      Left projectError -> dieIn "check" (withLockHint projectError)
      Right loaded -> pure loaded
  sources <- assembleSourcesOrExit "check" resolved
  loweredModules <- compileSourcesOrExit sources
  progress context ("OK — " <> Text.pack (show (Map.size loweredModules)) <> " module(s), no errors")
  where
    -- The common first-run stumble: dependencies declared but never resolved. Point at the fix.
    withLockHint projectError = case projectError of
      ResolveLockfileOutOfDate _ ->
        renderProjectError projectError <> " (run `katari apply` or `katari add` to write katari.lock)"
      _ -> renderProjectError projectError
