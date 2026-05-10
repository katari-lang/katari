-- | `katari-compiler` binary — Node CLI から spawn される compile サブルーチン。
--
-- Subcommands:
--
--   katari-compiler compile <DIR | FILE...> [--out <ir.json>] [--root <module>]
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

import Control.Monad (filterM, forM_, unless)
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
import Katari.Schema (SchemaEntry (..))
import Options.Applicative
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>), takeBaseName, takeExtension)
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
    compileOut :: OutTarget,
    compileRoot :: Maybe Text.Text
  }
  deriving (Show)

data TypecheckOpts = TypecheckOpts
  { typecheckInputs :: [FilePath],
    typecheckRoot :: Maybe Text.Text
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
    <*> optional (strOption (long "root" <> metavar "MODULE" <> help "Root module name (default: derived from inputs)"))

typecheckOptsParser :: Parser TypecheckOpts
typecheckOptsParser =
  TypecheckOpts
    <$> some (argument str (metavar "INPUT..." <> help "Source files or directories"))
    <*> optional (strOption (long "root" <> metavar "MODULE" <> help "Root module name (default: derived from inputs)"))

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
  let rootMod = resolveRoot o.compileRoot sources
  let result = compile (CompileInput {sources = sources, rootModule = rootMod})
  emitDiagnostics result.diagnostics
  if hasErrors result.diagnostics
    then exitWith (ExitFailure 1)
    else do
      let bundle = buildBundleJson result.irModule result.schemaEntries
      writeOut o.compileOut bundle

runTypecheck :: TypecheckOpts -> IO ()
runTypecheck o = do
  sources <- loadSources o.typecheckInputs
  let rootMod = resolveRoot o.typecheckRoot sources
  let result = compile (CompileInput {sources = sources, rootModule = rootMod})
  emitDiagnostics result.diagnostics
  if hasErrors result.diagnostics
    then exitWith (ExitFailure 1)
    else pure ()

-- ===========================================================================
-- Source loading
-- ===========================================================================

loadSources :: [FilePath] -> IO (Map Text.Text SourceEntry)
loadSources inputs = do
  files <- concat <$> traverse expandInput inputs
  let unique = Map.fromList [(p, ()) | p <- files]
  entries <- traverse readEntry (Map.keys unique)
  pure (Map.fromList entries)
  where
    expandInput :: FilePath -> IO [FilePath]
    expandInput p = do
      isDir <- doesDirectoryExist p
      if isDir
        then collectKtrFiles p
        else do
          isFile <- doesFileExist p
          if isFile
            then pure [p]
            else do
              hPutStrLn stderr $ "katari-compiler: input not found: " <> p
              exitWith (ExitFailure 2)

    readEntry :: FilePath -> IO (Text.Text, SourceEntry)
    readEntry p = do
      txt <- TextIO.readFile p
      let modName = Text.pack (takeBaseName p)
      pure (modName, SourceEntry {filePath = p, sourceText = txt})

collectKtrFiles :: FilePath -> IO [FilePath]
collectKtrFiles dir = do
  entries <- listDirectory dir
  let withDir = map (dir </>) entries
  files <- filterM doesFileExist withDir
  let ktrFiles = filter ((== ".ktr") . takeExtension) files
  subdirs <- filterM doesDirectoryExist withDir
  rest <- concat <$> traverse collectKtrFiles subdirs
  pure (ktrFiles <> rest)

resolveRoot :: Maybe Text.Text -> Map Text.Text SourceEntry -> Text.Text
resolveRoot (Just m) _ = m
resolveRoot Nothing sources =
  case Map.keys sources of
    [single] -> single
    -- If "main" exists, prefer it. Otherwise, fall back to the first
    -- alphabetical name (deterministic).
    keys
      | "main" `elem` keys -> "main"
      | (k : _) <- keys -> k
      | otherwise -> "main" -- empty: will error in compile

-- ===========================================================================
-- Output: { irModule, schemaBundle }
-- ===========================================================================

-- | TS-compatible SchemaBundle shape:
--   { schemaVersion: 1, agents: [{ qualifiedName, parameters, returns, description? }] }
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

-- | Translate `SchemaEntry` (Haskell) → `AgentDefinition` (TS shape).
--
--   - `name` (rendered "module.name") is split into `{ module_, name }`.
--   - `input` → `parameters`, `output` → `returns`.
--   - `requests` is dropped (TS-side AgentDefinition does not carry it).
schemaEntryToAgent :: SchemaEntry -> Value
schemaEntryToAgent e =
  object
    ( [ "qualifiedName" .= splitQualifiedName e.name,
        "parameters" .= e.input,
        "returns" .= e.output
      ]
        <> case e.description of
          Just d -> ["description" .= d]
          Nothing -> []
    )

splitQualifiedName :: Text.Text -> Value
splitQualifiedName s =
  let (modulePart, namePart) = case Text.breakOnEnd "." s of
        (modu, nm)
          | Text.null modu -> ("", nm)
          | otherwise -> (Text.dropEnd 1 modu, nm)
   in object ["module_" .= modulePart, "name" .= namePart]

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
