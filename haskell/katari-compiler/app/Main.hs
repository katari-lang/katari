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

import Control.Monad (forM_, unless)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Encode.Pretty (encodePretty)
import qualified Data.ByteString.Lazy as LBS
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import qualified Data.Aeson as Aeson
import Katari.Compile (CompileInput (..), CompileResult (..), SourceEntry (..), compile)
import Katari.Diagnostic (Diagnostic, Severity (..), filterAtLeast, hasErrors)
import Katari.Diagnostic.Render (renderDiagnostic)
import Katari.IR (IRModule)
import qualified Katari.Project.Discovery as Project
import qualified Katari.Project.ModuleName as Project
import System.FilePath (takeFileName)
import Katari.Schema (SchemaEntry (..))
import Options.Applicative
import System.Directory (doesDirectoryExist, doesFileExist)
import System.Exit (ExitCode (..), exitWith)
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
  sources <- loadSources o.compileInputs
  let result = compile (CompileInput {sources = sources})
  emitDiagnostics result.diagnostics
  if hasErrors result.diagnostics
    then exitWith (ExitFailure 1)
    else do
      let bundle = buildBundleJson result.irModule result.schemaEntries
      writeOut o.compileOut bundle

runTypecheck :: TypecheckOpts -> IO ()
runTypecheck o = do
  sources <- loadSources o.typecheckInputs
  let result = compile (CompileInput {sources = sources})
  emitDiagnostics result.diagnostics
  if hasErrors result.diagnostics
    then exitWith (ExitFailure 1)
    else pure ()

-- ===========================================================================
-- Source loading (delegated to katari-project for directory scans)
-- ===========================================================================

loadSources :: [FilePath] -> IO (Map Text.Text SourceEntry)
loadSources inputs = Map.unions <$> traverse loadOne inputs
  where
    loadOne :: FilePath -> IO (Map Text.Text SourceEntry)
    loadOne p = do
      isDir <- doesDirectoryExist p
      if isDir
        then fmap toCompilerEntry <$> Project.scanSourcesFromDir p
        else do
          isFile <- doesFileExist p
          if isFile
            then do
              txt <- TextIO.readFile p
              -- Single-file CLI mode: no project context, so use just
              -- the basename as the module name.
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
