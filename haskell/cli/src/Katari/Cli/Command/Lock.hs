-- | @katari lock@ — reconcile @katari.lock@ with @katari.toml@, and nothing else.
--
-- Locking is its own verb because it is its own decision. Resolving the closure means going to the
-- network, reading the registry, and possibly coming back with different packages than last time;
-- that is a thing you do deliberately, look at, and then check. It used to happen inside @apply@,
-- which meant the first compile of a new closure was also its deploy — you could not re-lock in order
-- to /find out/ what broke. Now @apply@ reads what this wrote.
--
-- @add@ / @remove@ / @update@ still write the lock, because each edits the manifest and reconciling
-- in the same breath is coherent. Nothing else does: every other command reads.
module Katari.Cli.Command.Lock
  ( Options (..),
    optionsParser,
    run,
  )
where

import Katari.Cli.Common (resolveProjectRoot, writeLockOrExit)
import Katari.Cli.Options (GlobalOptions, directoryOption, globalOptionsParser)
import Katari.Cli.Output (newOutputContext)
import Network.HTTP.Client.TLS (newTlsManager)
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
    <*> directoryOption

run :: Options -> IO ()
run options = do
  context <- newOutputContext options.global
  root <- resolveProjectRoot "lock" options.projectRoot
  manager <- newTlsManager
  _ <- writeLockOrExit "lock" context manager root
  pure ()
