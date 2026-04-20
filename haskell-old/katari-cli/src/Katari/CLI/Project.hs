module Katari.CLI.Project
  ( LoadError (..),
    loadProject,
    loadProjectOrDie,
    showLoadError,
  )
where

import Control.Exception (SomeException, catch)
import Control.Monad (foldM)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Katari.Lexer (LexError (..), lexFile)
import Katari.Parser (parseModule)
import Katari.Syntax (Decl (..), ImportDecl (..), Module (..))
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.Exit (exitFailure)
import System.FilePath (takeExtension, (</>))
import System.IO (hPutStrLn, stderr)

-- ---------------------------------------------------------------------------
-- Errors
-- ---------------------------------------------------------------------------

data LoadError
  = LoadManifestMissing FilePath
  | LoadSrcDirMissing FilePath
  | LoadReadError FilePath String
  | LoadLexError FilePath String
  | LoadParseError FilePath String
  | LoadCycle [Text]
  deriving (Show)

showLoadError :: LoadError -> String
showLoadError = \case
  LoadManifestMissing f -> "manifest not found: " ++ f
  LoadSrcDirMissing f -> "src directory not found: " ++ f
  LoadReadError f msg -> "read error (" ++ f ++ "): " ++ msg
  LoadLexError f msg -> "lex error (" ++ f ++ "): " ++ msg
  LoadParseError f msg -> "parse error (" ++ f ++ "): " ++ msg
  LoadCycle cyc -> "recursive imports: " ++ T.unpack (T.intercalate " -> " cyc)

-- ---------------------------------------------------------------------------
-- Project loading
-- ---------------------------------------------------------------------------

-- | Load a project rooted at the given directory. The project must contain
-- a @katari.toml@ manifest and a @src/@ directory. Every @.ktr@ file under
-- @src/@ is loaded; module names are derived from the path relative to @src/@.
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

-- | Wrapper that loads a project or single .ktr file, dying on error.
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

-- ---------------------------------------------------------------------------
-- Internals
-- ---------------------------------------------------------------------------

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
    dropLeadingSep = \case
      '/' : rest -> rest
      '\\' : rest -> rest
      s -> s
    dropTrailingSep s = reverse (dropLeadingSep (reverse s))
    dropExt s = reverse (drop 1 (dropWhile (/= '.') (reverse s)))

importedModules :: Module -> [Text]
importedModules m =
  [ T.intercalate "." (impPath imp)
    | DeclImport _ imp <- modDecls m
  ]

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
