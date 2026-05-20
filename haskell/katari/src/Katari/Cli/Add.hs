-- | @katari add@ — declare a new dependency in the current
-- @katari.toml@.
--
-- v1 only writes @path = "..."@ overrides. Once the registry +
-- snapshot-fetch machinery lands, @katari add\<name>@ (no @--path@)
-- will resolve against the snapshot; @--git URL --rev SHA@ will
-- write a git override and update the lockfile.
--
-- The command rewrites @katari.toml@ in-place by:
--
--   1. Appending the new name to @[snapshot].dependencies@ — keeping
--      the array on one line for readability.
--   2. Appending a @[overrides.\<name>]@ block at end-of-file.
--
-- Comments and unrelated whitespace are preserved.
module Katari.Cli.Add
  ( Options (..),
    optionsParser,
    run,
  )
where

import Control.Monad (unless, when)
import Data.List (elemIndex)
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
  when (depName `elem` consumerCfg.snapshotSection.snapshotDependencies) $
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

-- | In-place edit: insert @depName@ into the @[snapshot].dependencies@
-- list and append a @[overrides.\<depName>]@ block. The dep list is
-- collapsed onto one line for simplicity.
rewriteToml :: Text -> Source -> Text -> Either String Text
rewriteToml depName src oldText = do
  let ls = Text.lines oldText
  ls' <- updateSnapshotDeps depName ls
  let header = ["", "[overrides." <> depName <> "]"]
      body = case src of
        SourcePath p -> ["path = \"" <> Text.pack p <> "\""]
        SourceGit url rev ->
          [ "git = \"" <> url <> "\"",
            "rev = \"" <> rev <> "\""
          ]
  Right (Text.unlines (ls' <> header <> body))

-- | Find the @[snapshot]@ section and rewrite its @dependencies@ line.
-- If the section is missing entirely, append a new one at end-of-file
-- (= same behaviour as the @katari init@ template).
updateSnapshotDeps :: Text -> [Text] -> Either String [Text]
updateSnapshotDeps depName ls =
  case elemIndex "[snapshot]" (map Text.strip ls) of
    Nothing ->
      Right
        ( ls
            <> ["", "[snapshot]", "dependencies = [" <> quoted depName <> "]"]
        )
    Just sectionIx ->
      let (before, snapRest) = splitAt sectionIx ls
          (sectionBody, after) = breakOnNextSection (drop 1 snapRest)
       in case findDepLine sectionBody of
            Just (relIx, oldDeps) ->
              let newDeps = appendToList depName oldDeps
                  updatedBody =
                    take relIx sectionBody
                      <> [newDeps]
                      <> drop (relIx + 1) sectionBody
               in Right (before <> [head snapRest] <> updatedBody <> after)
            Nothing ->
              -- The section exists but has no @dependencies@ entry yet —
              -- insert one right after the section header.
              Right
                ( before
                    <> [head snapRest, "dependencies = [" <> quoted depName <> "]"]
                    <> sectionBody
                    <> after
                )

quoted :: Text -> Text
quoted s = "\"" <> s <> "\""

-- | Look for a @dependencies = [...]@ line inside an iteration. Returns
-- the index within the supplied slice and the original line text.
findDepLine :: [Text] -> Maybe (Int, Text)
findDepLine xs =
  case [(i, l) | (i, l) <- zip [0 ..] xs, "dependencies" `Text.isPrefixOf` Text.stripStart l] of
    ((i, l) : _) -> Just (i, l)
    [] -> Nothing

-- | Take the lines until the next @[section]@ header (exclusive). The
-- remainder includes that header line.
breakOnNextSection :: [Text] -> ([Text], [Text])
breakOnNextSection = break (\l -> "[" `Text.isPrefixOf` Text.stripStart l)

-- | Append a quoted name to a TOML array string like
-- @dependencies = ["a", "b"]@. Keeps the line on a single line; if
-- the array is empty produces @["new"]@.
appendToList :: Text -> Text -> Text
appendToList newName line =
  let (prefix, arr) = Text.breakOn "[" line
   in case arr of
        "" -> line -- malformed; leave alone
        _ ->
          let inner = Text.dropEnd 1 (Text.drop 1 arr) -- drop surrounding [ ]
              trimmed = Text.strip inner
              addition = if Text.null trimmed then quoted newName else trimmed <> ", " <> quoted newName
           in prefix <> "[" <> addition <> "]"

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
