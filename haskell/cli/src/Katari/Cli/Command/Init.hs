-- | @katari init [NAME]@ — scaffold a new project from the embedded templates.
--
-- Idempotent by design: a file that already exists is skipped with a warning, never overwritten, so
-- re-running @init@ over a half-scaffolded (or customised) project is always safe. The package name
-- comes from the argument, an interactive prompt, or the target directory's own name — sanitised
-- into a valid Katari identifier, since it becomes the module namespace prefix.
module Katari.Cli.Command.Init
  ( Options (..),
    optionsParser,
    run,
  )
where

import Control.Monad (forM_)
import Data.Char (isAlpha, isAlphaNum, isDigit)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Katari.Cli.Common (cliVersion, dieIn, writeOrExit)
import Katari.Cli.Options (GlobalOptions, globalOptionsParser)
import Katari.Cli.Output (OutputContext (..), hint, newOutputContext, progress, warn)
import Katari.Cli.Prompt (inputLine)
import Katari.Cli.Templates (ScaffoldFile (..), interpolate, interpolateDestination, scaffoldFiles)
import Options.Applicative
import System.Directory (createDirectoryIfMissing, doesFileExist, getCurrentDirectory)
import System.FilePath (takeBaseName, takeDirectory, (</>))

data Options = Options
  { global :: GlobalOptions,
    name :: Maybe Text,
    directory :: Maybe FilePath
  }
  deriving stock (Show)

optionsParser :: Parser Options
optionsParser =
  Options
    <$> globalOptionsParser
    <*> optional (strArgument (metavar "NAME" <> help "Package name (default: the target directory's name)"))
    <*> optional
      ( strOption
          ( long "dir"
              <> metavar "DIR"
              <> help "Scaffold into DIR instead of the current directory (created if absent)"
          )
      )

run :: Options -> IO ()
run options = do
  context <- newOutputContext options.global
  targetDirectory <- maybe getCurrentDirectory pure options.directory
  packageName <- resolveName context options targetDirectory
  createDirectoryIfMissing True targetDirectory
  forM_ scaffoldFiles $ \file -> do
    -- The destination carries a @{{name}}@ placeholder too (e.g. @src/{{name}}.ktr@), so the scaffolded
    -- source module lands under the package's own namespace, not a bare @main@.
    let destination = interpolateDestination packageName file.destination
        path = targetDirectory </> destination
    exists <- doesFileExist path
    if exists
      then warn context (Text.pack destination <> " already exists; leaving it untouched")
      else writeOrExit "init" ("could not write " <> Text.pack destination) $ do
        createDirectoryIfMissing True (takeDirectory path)
        TextIO.writeFile path (interpolate packageName cliVersion file.contents)
        progress context ("  + " <> Text.pack destination)
  progress context ("Initialized " <> packageName)
  hint context ("docker compose up -d && katari apply && katari run " <> packageName <> ".main")

-- | The package name: the argument (validated), an interactive prompt defaulting to the directory
-- name, or that sanitised default directly when non-interactive.
resolveName :: OutputContext -> Options -> FilePath -> IO Text
resolveName context options targetDirectory = case options.name of
  Just given -> requireValidName given
  Nothing
    | context.interactive -> do
        answered <- inputLine context ("package name (Enter for \"" <> fallback <> "\")")
        case answered of
          Nothing -> dieIn "init" "cancelled"
          Just line
            | Text.null (Text.strip line) -> requireValidName fallback
            | otherwise -> requireValidName (Text.strip line)
    | otherwise -> requireValidName fallback
  where
    fallback = sanitizeName (Text.pack (takeBaseName targetDirectory))

requireValidName :: Text -> IO Text
requireValidName candidate
  | isValidName candidate = pure candidate
  | otherwise = dieIn "init" ("'" <> candidate <> "' is not a valid package name (want [A-Za-z_][A-Za-z0-9_]*)")

-- | A Katari package name is an identifier (it prefixes every module name).
isValidName :: Text -> Bool
isValidName candidate = case Text.uncons candidate of
  Just (first, rest) ->
    (isAlpha first || first == '_') && Text.all (\character -> isAlphaNum character || character == '_') rest
  Nothing -> False

-- | Bend a directory name toward a valid identifier: dashes and dots become underscores, anything
-- else invalid is dropped, and a leading digit gets an underscore prefix. A hopeless name (all
-- symbols) falls back to a constant rather than an empty string.
sanitizeName :: Text -> Text
sanitizeName raw =
  let swapped = Text.map (\character -> if character == '-' || character == '.' then '_' else character) raw
      kept = Text.filter (\character -> isAlphaNum character || character == '_') swapped
      prefixed = case Text.uncons kept of
        Just (first, _) | isDigit first -> "_" <> kept
        _ -> kept
   in if isValidName prefixed then prefixed else "my_project"
