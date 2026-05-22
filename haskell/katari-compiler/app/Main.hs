-- | `katari-compiler` binary — Node CLI から spawn される compile サブルーチン。
--
-- Subcommands:
--
--   katari-compiler compile <DIR | FILE...> [--out <ir.json>]
--   katari-compiler typecheck <DIR | FILE...>
--
-- Output:
--   stdout : `{ "irModule": ..., "schemaBundle": ... }` (compile mode)
--   stderr : 色付き diagnostics
--
-- Exit codes:
--   0 = success
--   1 = compile error (one or more error-severity diagnostics)
--   2 = invalid args / IO error
module Main (main) where

import Control.Monad (forM_, unless, when)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Katari.Compile (CompileInput (..), CompileResult (..), SourceEntry (..), compile)
import Katari.Diagnostic (Diagnostic, Severity (..), filterAtLeast, hasErrors)
import Katari.Diagnostic.Render (renderDiagnostic)
import Katari.IR (IRModule)
import Katari.Project.Discovery qualified as Project
import Katari.Project.ModuleName qualified as Project
import Katari.Project.Resolve qualified as Project
import Katari.Schema (SchemaEntry (..))
import Options.Applicative
import System.Directory (doesDirectoryExist, doesFileExist)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath (takeFileName)
import System.IO (hPutStrLn, stderr)

-- ===========================================================================
-- CLI args
-- ===========================================================================

data Cmd
  = Compile CompileOpts
  | Typecheck TypecheckOpts
  deriving (Show)

data CompileOpts = CompileOpts
  { compileInputs :: [FilePath],
    compileOut :: OutTarget
  }
  deriving (Show)

newtype TypecheckOpts = TypecheckOpts
  { typecheckInputs :: [FilePath]
  }
  deriving (Show)

data OutTarget
  = OutStdout
  | OutFile FilePath
  deriving (Show)

cmdParser :: Parser Cmd
cmdParser =
  hsubparser
    ( command "compile" (info (Compile <$> compileOptsParser) (progDesc "Compile sources to IR + schema JSON"))
        <> command "typecheck" (info (Typecheck <$> typecheckOptsParser) (progDesc "Type-check sources without emitting IR"))
    )

compileOptsParser :: Parser CompileOpts
compileOptsParser =
  CompileOpts
    <$> some (argument str (metavar "INPUT..." <> help "Source files or directories"))
    <*> outTargetParser

typecheckOptsParser :: Parser TypecheckOpts
typecheckOptsParser =
  TypecheckOpts
    <$> some (argument str (metavar "INPUT..." <> help "Source files or directories"))

outTargetParser :: Parser OutTarget
outTargetParser =
  ( OutFile <$> strOption (long "out" <> short 'o' <> metavar "FILE" <> help "Output file (default: stdout)")
  )
    <|> pure OutStdout

opts :: ParserInfo Cmd
opts =
  info
    (cmdParser <**> helper)
    ( fullDesc
        <> header "katari-compiler — compile / typecheck Katari source files"
    )

-- ===========================================================================
-- Main
-- ===========================================================================

main :: IO ()
main = do
  cmd <- execParser opts
  case cmd of
    Compile o -> runCompile o
    Typecheck o -> runTypecheck o

runCompile :: CompileOpts -> IO ()
runCompile o = do
  input <- loadCompileInput o.compileInputs
  let result = compile input
  emitDiagnostics result.diagnostics
  if hasErrors result.diagnostics
    then exitWith (ExitFailure 1)
    else do
      let bundle = buildBundleJson result.irModule result.schemaEntries
      writeOut o.compileOut bundle

runTypecheck :: TypecheckOpts -> IO ()
runTypecheck o = do
  input <- loadCompileInput o.typecheckInputs
  let result = compile input
  emitDiagnostics result.diagnostics
  when (hasErrors result.diagnostics) $ exitWith (ExitFailure 1)

-- ===========================================================================
-- Source loading (delegated to katari-project for directory scans)
-- ===========================================================================
--
-- Resolution rules:
--
--   * For each input path, walk up looking for @katari.toml@. If found,
--     use 'Project.loadResolvedProject' so cross-package deps resolve.
--     The first @katari.toml@ wins; subsequent inputs that fall under
--     the same root are merged in (the workspace already covers them).
--   * Inputs with no enclosing project fall back to the legacy flat
--     scan (= single-file mode or a stand-alone @.ktr@).
loadCompileInput :: [FilePath] -> IO CompileInput
loadCompileInput inputs = do
  -- Use the first project root we find; the compile input is one
  -- single world, so we collapse everything into one assembly.
  mRoot <- firstProjectRoot inputs
  case mRoot of
    Just _root -> do
      assemblyResult <- loadFromProject inputs
      case assemblyResult of
        Left err -> do
          hPutStrLn stderr $ "katari-compiler: " <> show err
          exitWith (ExitFailure 2)
        Right input -> pure input
    Nothing -> do
      flatSources <- Map.unions <$> traverse loadFlatPath inputs
      pure CompileInput {sources = flatSources}
  where
    firstProjectRoot :: [FilePath] -> IO (Maybe FilePath)
    firstProjectRoot [] = pure Nothing
    firstProjectRoot (p : rest) = do
      r <- Project.findProjectRoot p
      case r of
        Just root -> pure (Just root)
        Nothing -> firstProjectRoot rest

    loadFromProject :: [FilePath] -> IO (Either Project.ResolveError CompileInput)
    loadFromProject (firstInput : _) = do
      mRoot <- Project.findProjectRoot firstInput
      case mRoot of
        Nothing -> pure (Left (Project.ResolveMissingConfig "" firstInput))
        Just root -> do
          rp <- Project.loadResolvedProject root
          case rp of
            Left err -> pure (Left err)
            Right resolved -> pure (toCompileInput <$> Project.assembleProject resolved)
    loadFromProject [] = pure (Right emptyCompileInput)

    emptyCompileInput :: CompileInput
    emptyCompileInput = CompileInput {sources = Map.empty}

    toCompileInput :: Project.ProjectAssembly -> CompileInput
    toCompileInput a = CompileInput {sources = Map.map toCompilerEntry a.sources}

    loadFlatPath :: FilePath -> IO (Map Text.Text SourceEntry)
    loadFlatPath p = do
      isDir <- doesDirectoryExist p
      if isDir
        then fmap toCompilerEntry <$> Project.scanSourcesFromDir p
        else do
          isFile <- doesFileExist p
          if isFile
            then do
              txt <- TextIO.readFile p
              let modName = Project.moduleNameFromRelativePath (takeFileName p)
              pure (Map.singleton modName SourceEntry {filePath = p, sourceText = txt})
            else do
              hPutStrLn stderr $ "katari-compiler: input not found: " <> p
              exitWith (ExitFailure 2)

    toCompilerEntry :: Project.SourceEntry -> SourceEntry
    toCompilerEntry e = SourceEntry {filePath = e.sourcePath, sourceText = e.sourceText}

-- ===========================================================================
-- Output: { irModule, schemaBundle }
-- ===========================================================================

-- | TS-compatible SchemaBundle shape:
--   { schemaVersion: 1, agents: [{ qualifiedName, parameters, returns, description? }] }
--
-- `qualifiedName` is the flat dotted string `"module.name"` (matching the
-- TS-side `QualifiedName = string` declaration in
-- @katari-runtime/src/ir/types.ts@).
buildBundleJson :: Maybe IRModule -> Maybe [SchemaEntry] -> Value
buildBundleJson mIr mEntries =
  object
    [ "irModule" .= maybe Null Aeson.toJSON mIr,
      "schemaBundle"
        .= object
          [ "schemaVersion" .= (1 :: Int),
            "agents" .= maybe ([] :: [Value]) (map schemaEntryToAgent) mEntries
          ]
    ]

-- | Translate `SchemaEntry` (Haskell) → `AgentDefinition` (TS shape):
-- drops the internal `requests` field, renames `input` / `output` to
-- `parameters` / `returns`, and emits `qualifiedName` as a flat dotted
-- string (already in `SchemaEntry.name`).
schemaEntryToAgent :: SchemaEntry -> Value
schemaEntryToAgent e =
  object
    ( [ "qualifiedName" .= e.name,
        "parameters" .= e.input,
        "returns" .= e.output
      ]
        <> case e.description of
          Just d -> ["description" .= d]
          Nothing -> []
    )

writeOut :: OutTarget -> Value -> IO ()
writeOut OutStdout v = LBS.putStr (encodePretty v)
writeOut (OutFile p) v = LBS.writeFile p (encodePretty v)

-- ===========================================================================
-- Diagnostics
-- ===========================================================================

emitDiagnostics :: [Diagnostic] -> IO ()
emitDiagnostics ds = do
  let visible = filterAtLeast SeverityWarning ds
  unless (null visible) $
    forM_ visible $ \d ->
      TextIO.hPutStrLn stderr (renderDiagnostic Map.empty d)
