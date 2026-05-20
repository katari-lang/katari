-- | @katari init@ — scaffold a new project.
--
-- Creates a directory @\<name>\/@ containing:
--
-- @
-- katari.toml          -- [package].name = \<name>, [compile].src = \"src\"
-- src/\<name>.ktr       -- a hello-world template defining @agent main()@
-- @
--
-- The package name must be a valid Katari identifier ([A-Za-z_][A-Za-z0-9_]*).
-- Without an argument, the name is derived from the current working
-- directory (also identifier-validated).
module Katari.Cli.Init
  ( Options (..),
    optionsParser,
    run,
  )
where

import Data.Char (isAlpha, isAlphaNum)
import Data.Maybe (fromMaybe)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Options.Applicative
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    getCurrentDirectory,
  )
import System.Exit (ExitCode (..), exitWith)
import System.FilePath (takeFileName, (</>))
import System.IO (hPutStrLn, stderr)

data Options = Options
  { -- | Optional package name. When omitted we use the basename of the
    -- current working directory and scaffold in place.
    optName :: Maybe String
  }
  deriving (Show)

optionsParser :: Parser Options
optionsParser =
  Options
    <$> optional (argument str (metavar "NAME" <> help "Package name (also the directory)"))

run :: Options -> IO ()
run opts = do
  (targetDir, packageName) <- resolveTarget opts.optName
  case validateName packageName of
    Just err -> do
      hPutStrLn stderr ("katari init: " <> err)
      exitWith (ExitFailure 2)
    Nothing -> pure ()
  createDirectoryIfMissing True (targetDir </> "src")
  writeIfAbsent (targetDir </> "katari.toml") (katariTomlTemplate packageName)
  writeIfAbsent
    (targetDir </> "src" </> packageName <> ".ktr")
    (entryKtrTemplate packageName)
  putStrLn ("Scaffolded " <> packageName <> " at " <> targetDir)

-- | When the user passes a name, scaffold into @./\<name>@. Otherwise
-- use the current working directory and derive a name from its
-- basename.
resolveTarget :: Maybe String -> IO (FilePath, String)
resolveTarget = \case
  Just name -> do
    exists <- doesDirectoryExist name
    nonEmpty <- if exists then directoryHasEntries name else pure False
    if nonEmpty
      then do
        hPutStrLn stderr ("katari init: refusing to scaffold into non-empty directory '" <> name <> "'")
        exitWith (ExitFailure 2)
      else pure (name, name)
  Nothing -> do
    cwd <- getCurrentDirectory
    pure (cwd, takeFileName cwd)

directoryHasEntries :: FilePath -> IO Bool
directoryHasEntries path = do
  -- We treat "has any file at all" as non-empty so that we don't clobber
  -- an existing project. A future flag could relax this.
  hasToml <- doesFileExist (path </> "katari.toml")
  hasSrc <- doesDirectoryExist (path </> "src")
  pure (hasToml || hasSrc)

-- | Validate that a string is a legal Katari identifier (matches the
-- check 'Katari.Project.Resolve' performs on package names).
validateName :: String -> Maybe String
validateName name
  | null name = Just "package name cannot be empty"
  | not (validHead (head name)) =
      Just "package name must start with a letter or underscore"
  | not (all validChar name) =
      Just "package name may only contain letters, digits, and underscores"
  | otherwise = Nothing
  where
    validChar c = isAlphaNum c || c == '_'
    validHead c = isAlpha c || c == '_'

-- | Write @path@ with @contents@ unless something already exists there.
-- Existing files are left alone (= partial scaffolds are idempotent).
writeIfAbsent :: FilePath -> String -> IO ()
writeIfAbsent path contents = do
  exists <- doesFileExist path
  if exists
    then hPutStrLn stderr ("katari init: skipped existing " <> path)
    else TextIO.writeFile path (Text.pack contents)

katariTomlTemplate :: String -> String
katariTomlTemplate name =
  unlines
    [ "[package]",
      "name = \"" <> name <> "\"",
      "",
      "[runtime]",
      "url = \"http://localhost:8000\"",
      "",
      "[dependencies]",
      "# registry = \"https://github.com/katari-lang/katari-registry\"",
      "# snapshot = \"v0.1.0\"",
      "packages = []",
      "",
      "# [overrides.my_fork]",
      "# path = \"../my_fork\"",
      "#",
      "# [overrides.upstream]",
      "# git = \"https://github.com/...\"",
      "# ref = \"<full 40-hex commit sha>\""
    ]

entryKtrTemplate :: String -> String
entryKtrTemplate name =
  unlines
    [ "@\"Entry point for the '" <> name <> "' package.\"",
      "agent main() -> string {",
      "  \"hello from " <> name <> "\"",
      "}"
    ]
