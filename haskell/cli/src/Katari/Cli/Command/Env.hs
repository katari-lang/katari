-- | @katari env get|set|unset@ — the project's key/value store, including secrets.
--
-- The read policy mirrors the runtime's: a secret's plaintext never crosses the admin API, so
-- @env get@ refuses a secret (programs read those via @env.get_secret@). On the write side the value
-- can arrive three ways, most-careful first: interactively (echo off — nothing lands in shell
-- history or the scrollback), from stdin (pipe a file in), or as a plain argument (fine for
-- non-secrets).
module Katari.Cli.Command.Env
  ( Options (..),
    optionsParser,
    run,
  )
where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Katari.Cli.Api (EnvEntry (..), getEnv, setEnv, unsetEnv)
import Katari.Cli.Common (RuntimeContext (..), dieIn, withRuntimeContext)
import Katari.Cli.Options (GlobalOptions, globalOptionsParser)
import Katari.Cli.Output (OutputContext (..), printText, progress)
import Katari.Cli.Prompt (inputLine, inputSecret)
import Options.Applicative

-- | The three item-level verbs (listing lives under @katari ls env@).
data Action
  = ActionGet GetOptions
  | ActionSet SetOptions
  | ActionUnset UnsetOptions
  deriving stock (Show)

newtype GetOptions = GetOptions {key :: Text}
  deriving stock (Show)

data SetOptions = SetOptions
  { key :: Text,
    value :: Maybe Text,
    secret :: Bool
  }
  deriving stock (Show)

newtype UnsetOptions = UnsetOptions {key :: Text}
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
              <> help "Project the entry belongs to (default: the surrounding katari.toml's [package].name)"
          )
      )
    <*> hsubparser
      ( command "get" (info (ActionGet <$> getParser) (progDesc "Print a non-secret entry's value (raw, for piping)"))
          <> command "set" (info (ActionSet <$> setParser) (progDesc "Create or overwrite an entry"))
          <> command "unset" (info (ActionUnset <$> unsetParser) (progDesc "Delete an entry"))
      )
  where
    getParser = GetOptions <$> strArgument (metavar "KEY" <> help "Entry key")
    setParser =
      SetOptions
        <$> strArgument (metavar "KEY" <> help "Entry key")
        <*> optional (strArgument (metavar "VALUE" <> help "Entry value (omit to be prompted with echo off, or to pipe it on stdin)"))
        <*> switch (long "secret" <> help "Encrypt at rest and make the value write-only over the API")
    unsetParser = UnsetOptions <$> strArgument (metavar "KEY" <> help "Entry key")

run :: Options -> IO ()
run options = do
  context <- withRuntimeContext "env" options.global options.projectName
  case options.action of
    ActionGet getOptions -> do
      entry <- getEnv context.client context.projectId getOptions.key
      if entry.isSecret
        then dieIn "env" (getOptions.key <> " is a secret; its value is write-only over the API (programs read it via env.get_secret)")
        else printText (fromMaybe "" entry.value)
    ActionSet setOptions -> do
      entryValue <- resolveSetValue context setOptions
      setEnv context.client context.projectId setOptions.key entryValue setOptions.secret
      progress context.output ("Set " <> setOptions.key <> (if setOptions.secret then " (secret)" else ""))
    ActionUnset unsetOptions -> do
      unsetEnv context.client context.projectId unsetOptions.key
      progress context.output ("Unset " <> unsetOptions.key)

-- | Where a @set@ value comes from when it is not an argument: an echo-off prompt on a terminal
-- (secrets stay out of history and scrollback), stdin otherwise (trailing newline dropped, so
-- @echo secret | katari env set KEY --secret@ does the expected thing).
resolveSetValue :: RuntimeContext -> SetOptions -> IO Text
resolveSetValue context setOptions = case setOptions.value of
  Just given -> pure given
  Nothing
    | context.output.interactive -> do
        answered <-
          if setOptions.secret
            then inputSecret context.output ("value for " <> setOptions.key <> " (echo off)")
            else inputLine context.output ("value for " <> setOptions.key)
        case answered of
          Just entryValue -> pure entryValue
          Nothing -> dieIn "env" "cancelled"
    | otherwise -> do
        piped <- TextIO.getContents
        let pipedValue = Text.dropWhileEnd (== '\n') piped
        if Text.null pipedValue
          then dieIn "env" "no VALUE given and stdin was empty"
          else pure pipedValue
