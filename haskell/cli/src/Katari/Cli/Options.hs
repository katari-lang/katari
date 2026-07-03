-- | The flags every subcommand shares. @optparse-applicative@'s subparsers only accept top-level
-- flags /before/ the command word, which reads unnaturally (@katari --verbose run@); embedding this
-- record in each command's own @Options@ instead lets the flags appear anywhere after the command.
module Katari.Cli.Options
  ( GlobalOptions (..),
    globalOptionsParser,
    directoryOption,
  )
where

import Data.Text (Text)
import Options.Applicative

-- | Shared switches: output verbosity, the interactivity override, and the runtime URL. @--json@ is
-- deliberately not here — it exists only on the read commands where it means something, so @--help@
-- never advertises it where it would be ignored.
data GlobalOptions = GlobalOptions
  { -- | Suppress progress lines on stderr (errors still print).
    quiet :: Bool,
    -- | Trace every runtime HTTP request/response on stderr.
    verbose :: Bool,
    -- | Never prompt, even on a terminal: incomplete input becomes a hard error. For scripts running
    -- under a pseudo-TTY, where terminal detection alone would wrongly go interactive.
    noInput :: Bool,
    -- | Runtime URL override (over @KATARI_API_URL@ and @[runtime].url@). Parsed for every command
    -- but consulted only by the networked ones.
    url :: Maybe Text
  }
  deriving stock (Show)

globalOptionsParser :: Parser GlobalOptions
globalOptionsParser =
  GlobalOptions
    <$> switch (long "quiet" <> short 'q' <> help "Suppress progress output (errors still print)")
    <*> switch (long "verbose" <> help "Trace runtime HTTP requests on stderr")
    <*> switch (long "no-input" <> help "Never prompt interactively; missing input is an error")
    <*> optional
      ( strOption
          ( long "url"
              <> metavar "URL"
              <> help "Runtime URL. Overrides KATARI_API_URL and [runtime].url from katari.toml."
          )
      )

-- | The offline commands' project-directory flag (@check@ / @build@ / @apply@ / @add@ / @remove@).
-- Deliberately distinct from the networked commands' @--project NAME@, which names a runtime project:
-- this names a filesystem directory instead. Centralised here so every offline command spells it the
-- same, keeping @--project@ a single concept across the whole CLI.
directoryOption :: Parser (Maybe FilePath)
directoryOption =
  optional
    ( strOption
        ( long "directory"
            <> short 'C'
            <> metavar "DIR"
            <> help "Project directory (the one containing katari.toml). Defaults to walking up from the current directory."
        )
    )
