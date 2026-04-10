module Main where

import Control.Exception (SomeException, catch)
import Control.Monad (foldM)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Katari.Emit (emitModule)
import Katari.IR (IRModule)
import Katari.IRPrint (printIRModule)
import Katari.Lexer (LexError (..), lexFile)
import Katari.Lowering (LowerError (..), lowerModules)
import Katari.Module (GlobalEnv, buildGlobalEnv)
import Katari.Parser (parseModule)
import Katari.Schema
  ( SchemaKind (..),
    SchemaOutput (..),
    moduleSchemas,
  )
import Katari.Syntax (Decl (..), ImportDecl (..), Module (..))
import Katari.Typechecker (typecheck)
import Options.Applicative
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.Exit (exitFailure)
import System.FilePath (takeExtension, (</>))
import System.IO (hPutStrLn, stderr)

-- ---------------------------------------------------------------------------
-- CLI
-- ---------------------------------------------------------------------------

data Command
  = Compile CompileOpts
  | Dump DumpOpts
  | Schema SchemaOpts
  deriving (Show)

data CompileOpts = CompileOpts
  { coRoot :: Maybe FilePath,
    coOutput :: Maybe FilePath
  }
  deriving (Show)

newtype DumpOpts = DumpOpts
  { doRoot :: Maybe FilePath
  }
  deriving (Show)

data SchemaOpts = SchemaOpts
  { scRoot :: Maybe FilePath,
    scOutput :: Maybe FilePath,
    scModule :: Maybe Text,
    scAgent :: Maybe Text,
    scRequest :: Maybe Text
  }
  deriving (Show)

cliParser :: Parser Command
cliParser =
  subparser
    ( command "compile" (info compileParser (progDesc "Compile a Katari project to .ktri binary"))
        <> command "dump" (info dumpParser (progDesc "Dump IR of a Katari project as text"))
        <> command "schema" (info schemaParser (progDesc "Generate JSON Schema for agents/requests/types"))
    )

compileParser :: Parser Command
compileParser =
  fmap Compile $
    CompileOpts
      <$> optional (argument str (metavar "ROOT" <> help "Project root directory (default: cwd)"))
      <*> optional (option str (short 'o' <> long "output" <> metavar "OUT" <> help "Output .ktri file"))

dumpParser :: Parser Command
dumpParser =
  fmap Dump $
    DumpOpts
      <$> optional (argument str (metavar "ROOT" <> help "Project root directory (default: cwd)"))

schemaParser :: Parser Command
schemaParser =
  fmap Schema $
    SchemaOpts
      <$> optional (argument str (metavar "ROOT" <> help "Project root directory (default: cwd)"))
      <*> optional (option str (short 'o' <> long "output" <> metavar "OUT" <> help "Output JSON file (default: stdout)"))
      <*> optional (option str (long "module" <> metavar "MOD" <> help "Restrict to the given module"))
      <*> optional (option str (long "agent" <> metavar "NAME" <> help "Restrict to the given agent (local name)"))
      <*> optional (option str (long "request" <> metavar "NAME" <> help "Restrict to the given request (local name)"))

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------

main :: IO ()
main = do
  cmd <- execParser (info (cliParser <**> helper) (fullDesc <> progDesc "Katari compiler"))
  case cmd of
    Compile opts -> runCompile opts
    Dump opts -> runDump opts
    Schema opts -> runSchema opts

runCompile :: CompileOpts -> IO ()
runCompile opts = do
  let root = fromMaybe "." (coRoot opts)
      out = fromMaybe (root </> "out.ktri") (coOutput opts)
  modules <- loadProjectOrDie root
  irModule <- buildOrDie modules
  let binary = emitModule irModule
  BS.writeFile out binary
  putStrLn ("Compiled: " ++ root ++ " -> " ++ out)

runDump :: DumpOpts -> IO ()
runDump opts = do
  let root = fromMaybe "." (doRoot opts)
  modules <- loadProjectOrDie root
  irModule <- buildOrDie modules
  TIO.putStrLn (printIRModule irModule)

runSchema :: SchemaOpts -> IO ()
runSchema opts = do
  let root = fromMaybe "." (scRoot opts)
  modules <- loadProjectOrDie root
  ge <- buildGeOrDie modules
  let outputs = filterSchemas opts (moduleSchemas ge)
      jsonValue = schemasToValue outputs
      bytes = Aeson.encode jsonValue
  case scOutput opts of
    Just path -> BL.writeFile path bytes
    Nothing -> BL.putStr bytes >> putStrLn ""

-- | Build global env and typecheck modules. Returns the environment on
-- success; dies on error.
buildGeOrDie :: [Module] -> IO GlobalEnv
buildGeOrDie modules = do
  ge <- case buildGlobalEnv modules of
    Left err -> do
      hPutStrLn stderr ("Module error: " ++ show err)
      exitFailure
    Right ge -> return ge
  case typecheck ge modules of
    Left err -> do
      hPutStrLn stderr ("Type error: " ++ show err)
      exitFailure
    Right () -> return ge

-- | Build global env, typecheck, and lower a set of modules. Aborts with
-- exitFailure on any error.
buildOrDie :: [Module] -> IO IRModule
buildOrDie modules = do
  ge <- buildGeOrDie modules
  case lowerModules ge modules of
    Left (LowerError msg) -> do
      hPutStrLn stderr ("Lowering error: " ++ msg)
      exitFailure
    Right ir -> return ir

-- ---------------------------------------------------------------------------
-- Schema helpers
-- ---------------------------------------------------------------------------

-- | Apply --module / --agent / --request filters to a list of schema outputs.
filterSchemas :: SchemaOpts -> [SchemaOutput] -> [SchemaOutput]
filterSchemas opts = filter keep
  where
    keep so =
      moduleMatches (soName so)
        && kindMatches so
    moduleMatches qname = case scModule opts of
      Nothing -> True
      Just m -> m == qname || (m <> ".") `T.isPrefixOf` qname
    kindMatches so = case (scAgent opts, scRequest opts, soKind so) of
      (Nothing, Nothing, _) -> True
      (Just t, _, SKAgent) -> localNameEquals t (soName so)
      (_, Just r, SKRequest) -> localNameEquals r (soName so)
      _ -> False
    localNameEquals local qname =
      case T.breakOnEnd "." qname of
        (_, nm) | not (T.null nm) -> nm == local
        _ -> qname == local

-- | Convert a list of schema outputs into a top-level JSON array value.
schemasToValue :: [SchemaOutput] -> Value
schemasToValue outs =
  Aeson.toJSON
    [ object
        [ "name" .= soName o,
          "kind" .= kindText (soKind o),
          "schema" .= soSchema o
        ]
      | o <- outs
    ]

kindText :: SchemaKind -> Text
kindText = \case
  SKAgent -> "agent"
  SKRequest -> "request"
  SKType -> "type"

-- ---------------------------------------------------------------------------
-- Project loader
-- ---------------------------------------------------------------------------

-- | Errors that may occur while loading a project from disk.
data LoadError
  = LoadManifestMissing FilePath
  | LoadSrcDirMissing FilePath
  | LoadReadError FilePath String
  | LoadLexError FilePath String
  | LoadParseError FilePath String
  | LoadCycle [Text]
  deriving (Show)

-- | Load a project rooted at the given directory. The project must contain
-- a 'katari.toml' manifest and a 'src/' directory. Every '.ktr' file under
-- 'src/' is loaded; module names are derived from the path relative to
-- 'src/'.
--
-- The returned list is topologically sorted by import dependency so that
-- each module appears after every module it imports.
loadProject :: FilePath -> IO (Either LoadError [Module])
loadProject root = do
  let manifest = root </> "katari.toml"
      srcDir = root </> "src"
  manifestExists <- doesFileExist manifest
  if not manifestExists
    then return (Left (LoadManifestMissing manifest))
    else do
      srcExists <- doesDirectoryExist srcDir
      if not srcExists
        then return (Left (LoadSrcDirMissing srcDir))
        else do
          files <- walkKtr srcDir
          loadRes <- foldM (loadOneInto srcDir) (Right Map.empty) files
          case loadRes of
            Left e -> return (Left e)
            Right loaded -> case topoSort loaded of
              Left cyc -> return (Left (LoadCycle cyc))
              Right order -> return (Right order)

-- | Recursively walk a directory collecting all '.ktr' files. Paths are
-- returned absolute (joined onto the starting directory).
walkKtr :: FilePath -> IO [FilePath]
walkKtr dir = do
  entries <- listDirectory dir
  concat
    <$> mapM
      ( \name -> do
          let p = dir </> name
          isDir <- doesDirectoryExist p
          if isDir
            then walkKtr p
            else
              if takeExtension p == ".ktr"
                then return [p]
                else return []
      )
      entries

loadOneInto ::
  FilePath ->
  Either LoadError (Map Text Module) ->
  FilePath ->
  IO (Either LoadError (Map Text Module))
loadOneInto _srcDir (Left e) _ = return (Left e)
loadOneInto srcDir (Right loaded) fp = do
  readRes <-
    (Right <$> TIO.readFile fp) `catch` \(e :: SomeException) ->
      return (Left (LoadReadError fp (show e)))
  case readRes of
    Left e -> return (Left e)
    Right src ->
      case lexFile fp src of
        Left (LexError msg) -> return (Left (LoadLexError fp msg))
        Right toks -> do
          let mname = deriveModNameRel srcDir fp
          case parseModule fp mname toks of
            Left err -> return (Left (LoadParseError fp (show err)))
            Right m -> return (Right (Map.insert mname m loaded))

-- | Derive a module name from an absolute file path by taking the path
-- relative to the source directory and converting directory separators
-- to dots. Example: srcDir=/p/src, fp=/p/src/lib/cron.ktr -> "lib.cron".
deriveModNameRel :: FilePath -> FilePath -> Text
deriveModNameRel srcDir fp =
  let rel = stripRoot srcDir fp
      withoutExt = dropExt rel
      normalized = map (\c -> if c == '/' || c == '\\' then '.' else c) withoutExt
   in T.pack normalized
  where
    stripRoot r f =
      let rTrim = dropTrailingSep r
          rTrimLen = length rTrim
       in if take rTrimLen f == rTrim && length f > rTrimLen
            then dropLeadingSep (drop rTrimLen f)
            else f
    dropLeadingSep s = case s of
      '/' : rest -> rest
      '\\' : rest -> rest
      _ -> s
    dropTrailingSep s = reverse (dropLeadingSep (reverse s))
    dropExt s = reverse (drop 1 (dropWhile (/= '.') (reverse s)))

-- | List the module names imported by a module.
importedModules :: Module -> [Text]
importedModules m =
  [ T.intercalate "." (impPath imp)
    | DeclImport _ imp <- modDecls m
  ]

-- Topological sort over all loaded modules. Unknown imports (e.g. to the
-- built-in 'prim' module) are simply skipped during traversal. Returns a
-- cycle (list of module names in the cycle) on failure.
topoSort :: Map Text Module -> Either [Text] [Module]
topoSort loaded = do
  let go (visited, ordered, stack) name
        | name `Set.member` Set.fromList stack = Left (reverse (name : stack))
        | name `Set.member` visited = Right (visited, ordered, stack)
        | not (Map.member name loaded) = Right (visited, ordered, stack)
        | otherwise = do
            let m = loaded Map.! name
                deps = importedModules m
            (visited', ordered', _) <-
              foldM go (visited, ordered, name : stack) deps
            return (Set.insert name visited', m : ordered', stack)
  (_, ordered, _) <- foldM go (Set.empty, [], []) (Map.keys loaded)
  return (reverse ordered)

-- | Wrapper that loads a project or dies with an error message.
loadProjectOrDie :: FilePath -> IO [Module]
loadProjectOrDie root = do
  isFile <- doesFileExist root
  if isFile && takeExtension root == ".ktr"
    then loadSingleFile root
    else do
      res <- loadProject root
      case res of
        Left err -> do
          hPutStrLn stderr ("Load error: " ++ showLoadError err)
          exitFailure
        Right modules -> return modules

loadSingleFile :: FilePath -> IO [Module]
loadSingleFile fp = do
  src <- TIO.readFile fp
  case lexFile fp src of
    Left (LexError msg) -> do
      hPutStrLn stderr ("Lex error: " ++ msg)
      exitFailure
    Right toks -> do
      let mname = T.pack $ dropExt (takeFileName fp)
      case parseModule fp mname toks of
        Left err -> do
          hPutStrLn stderr ("Parse error: " ++ show err)
          exitFailure
        Right m -> return [m]
  where
    dropExt s = reverse (drop 1 (dropWhile (/= '.') (reverse s)))
    takeFileName = reverse . takeWhile (\c -> c /= '/' && c /= '\\') . reverse

showLoadError :: LoadError -> String
showLoadError = \case
  LoadManifestMissing f -> "manifest not found: " ++ f
  LoadSrcDirMissing f -> "src directory not found: " ++ f
  LoadReadError f msg -> "read error (" ++ f ++ "): " ++ msg
  LoadLexError f msg -> "lex error (" ++ f ++ "): " ++ msg
  LoadParseError f msg -> "parse error (" ++ f ++ "): " ++ msg
  LoadCycle cyc -> "recursive imports: " ++ T.unpack (T.intercalate " -> " cyc)
