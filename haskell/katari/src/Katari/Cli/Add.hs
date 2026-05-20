-- | @katari add@ — declare a new dependency in the current
-- @katari.toml@.
--
-- v1 writes path / git overrides only. Snapshot pins (@name = "*"@)
-- are added manually by the user. Once the registry workflow stabilises
-- we can teach @katari add NAME@ (no @--path@ / @--git@) to default to
-- a snapshot pin and update the lockfile.
--
-- The command rewrites @katari.toml@ in-place by inserting a single
-- @name = { ... }@ line under the @[dependencies]@ section (creating
-- the section if missing). Comments and unrelated whitespace are
-- preserved.
module Katari.Cli.Add
  ( Options (..),
    optionsParser,
    run,
  )
where

import Control.Monad (unless, when)
import Data.List (elemIndex)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import qualified Katari.Project.Config as Project
import qualified Katari.Project.Discovery as Project
import Options.Applicative
import System.Directory (doesDirectoryExist, doesFileExist, getCurrentDirectory)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)

-- | One @katari add@ accepts either @--path@ or @--git URL --rev SHA@.
data Source
  = SourcePath FilePath
  | SourceGit Text Text
  deriving (Show)

data Options = Options
  { optName :: String,
    optSource :: Source,
    optProjectRoot :: Maybe FilePath
  }
  deriving (Show)

optionsParser :: Parser Options
optionsParser =
  Options
    <$> argument str (metavar "NAME" <> help "Dependency name (= what consumers type after `import`)")
    <*> sourceParser
    <*> optional
      ( strOption
          ( long "project"
              <> short 'p'
              <> metavar "DIR"
              <> help "Project root (defaults to walking up from cwd)"
          )
      )

sourceParser :: Parser Source
sourceParser = (SourcePath <$> pathOpt) <|> (SourceGit <$> gitOpt <*> revOpt)
  where
    pathOpt =
      strOption
        ( long "path"
            <> metavar "PATH"
            <> help "Local path to the dependency's package root"
        )
    gitOpt =
      strOption
        ( long "git"
            <> metavar "URL"
            <> help "Git repo URL (GitHub-style; tarball is fetched from <URL>/archive/<rev>.tar.gz)"
        )
    revOpt =
      strOption
        ( long "rev"
            <> metavar "SHA"
            <> help "Git revision — must be a full commit SHA for reproducibility"
        )

run :: Options -> IO ()
run opts = do
  start <- maybe getCurrentDirectory pure opts.optProjectRoot
  mRoot <- Project.findProjectRoot start
  rootDir <- case mRoot of
    Just r -> pure r
    Nothing -> die "no katari.toml found in this or any parent directory"
  let consumerToml = rootDir </> Project.configFilename
  consumerCfg <- loadOrDie consumerToml

  validateIdentifier opts.optName
  let depName = Text.pack opts.optName

  -- Reject duplicate dep names so this command is non-destructive.
  when (Map.member depName consumerCfg.dependencies) $
    die ("dependency '" <> opts.optName <> "' already declared in " <> consumerToml)

  description <- case opts.optSource of
    SourcePath p -> do
      depCfg <- verifyDepTarget rootDir p opts.optName
      pure
        ( "path = "
            <> p
            <> ", package "
            <> Text.unpack depCfg.packageSection.packageName
        )
    SourceGit url rev -> do
      validateGitRev rev
      pure ("git = " <> Text.unpack url <> ", rev = " <> Text.unpack rev)

  oldText <- TextIO.readFile consumerToml
  newText <- case rewriteToml depName opts.optSource oldText of
    Right t -> pure t
    Left err -> die err
  TextIO.writeFile consumerToml newText

  putStrLn
    ( "Added '"
        <> opts.optName
        <> "' ("
        <> description
        <> ") to "
        <> consumerToml
    )

-- ---------------------------------------------------------------------------
-- TOML rewriting
-- ---------------------------------------------------------------------------

-- | In-place edit: insert a @name = { path = "..." }@ (or git form) line
-- under @[dependencies]@. Creates the section at end-of-file when it
-- doesn't exist yet.
rewriteToml :: Text -> Source -> Text -> Either String Text
rewriteToml depName src oldText =
  let ls = Text.lines oldText
      depLine = depName <> " = " <> inlineTable src
   in case elemIndex "[dependencies]" (map Text.strip ls) of
        Nothing ->
          Right (Text.unlines (ls <> ["", "[dependencies]", depLine]))
        Just sectionIx ->
          -- Insert as the first entry of the existing [dependencies]
          -- section so the file naturally groups deps together.
          let (before, fromSection) = splitAt (sectionIx + 1) ls
           in Right (Text.unlines (before <> [depLine] <> fromSection))

inlineTable :: Source -> Text
inlineTable = \case
  SourcePath p -> "{ path = " <> quoted (Text.pack p) <> " }"
  SourceGit url rev ->
    "{ git = " <> quoted url <> ", ref = " <> quoted rev <> " }"

quoted :: Text -> Text
quoted s = "\"" <> s <> "\""

-- ---------------------------------------------------------------------------
-- Validation helpers
-- ---------------------------------------------------------------------------

die :: String -> IO a
die msg = do
  hPutStrLn stderr ("katari add: " <> msg)
  exitWith (ExitFailure 2)

loadOrDie :: FilePath -> IO Project.ProjectConfig
loadOrDie path = do
  r <- Project.loadKatariToml path
  case r of
    Right cfg -> pure cfg
    Left err -> die (show err)

validateIdentifier :: String -> IO ()
validateIdentifier name = do
  when (null name) $ die "NAME must be non-empty"
  unless (validHead (head name)) $
    die "NAME must start with a letter or underscore"
  unless (all validChar name) $
    die "NAME may only contain letters, digits, and underscores"
  where
    validHead c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
    validChar c = validHead c || (c >= '0' && c <= '9')

validateGitRev :: Text -> IO ()
validateGitRev rev = do
  let len = Text.length rev
      isHex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
  when (len /= 40) $
    die ("--rev must be a full 40-character commit SHA; got " <> show len <> " chars")
  unless (Text.all isHex rev) $
    die "--rev must be a hex SHA (0-9, a-f)"

verifyDepTarget :: FilePath -> FilePath -> String -> IO Project.ProjectConfig
verifyDepTarget rootDir depPathRaw declaredName = do
  let absDepPath = if isAbs depPathRaw then depPathRaw else rootDir </> depPathRaw
  dirExists <- doesDirectoryExist absDepPath
  unless dirExists $ die ("path does not exist or is not a directory: " <> depPathRaw)
  let depToml = absDepPath </> Project.configFilename
  hasToml <- doesFileExist depToml
  unless hasToml $ die ("no katari.toml at " <> depToml)
  depCfg <- loadOrDie depToml
  let actualName = Text.unpack depCfg.packageSection.packageName
  unless (actualName == declaredName) $
    die
      ( "dep name mismatch: declaring '"
          <> declaredName
          <> "' but the target package is named '"
          <> actualName
          <> "' (per the [package].name in "
          <> depToml
          <> ")"
      )
  pure depCfg
  where
    isAbs ('/' : _) = True
    isAbs _ = False
