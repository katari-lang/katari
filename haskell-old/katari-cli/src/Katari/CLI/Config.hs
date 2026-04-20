module Katari.CLI.Config
  ( parseToml,
    loadConfig,
    resolveRuntimeUrl,
    resolveRuntimeUrlFromCwd,
  )
where

import Data.List (foldl')
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Katari.CLI.Types (ProjectConfig (..))
import System.Directory (doesFileExist)
import System.FilePath ((</>))

-- | Load project config from @katari.toml@ in the given directory.
loadConfig :: FilePath -> IO ProjectConfig
loadConfig root = do
  content <- TIO.readFile (root </> "katari.toml")
  let sections = parseToml content
      servers = fromMaybe Map.empty (Map.lookup "servers" sections)
      runtimeUrl = Map.lookup "url" =<< Map.lookup "runtime" sections
  return
    ProjectConfig
      { pcRuntimeUrl = runtimeUrl,
        pcServers = servers
      }

-- | Resolve the runtime URL: CLI flag > katari.toml > default.
resolveRuntimeUrl :: Maybe String -> ProjectConfig -> Text
resolveRuntimeUrl cliOverride config = case cliOverride of
  Just url -> T.pack url
  Nothing -> fromMaybe "http://localhost:8000" (pcRuntimeUrl config)

-- | Resolve runtime URL from CWD context (for runtime commands that
-- don't necessarily have a project directory).
resolveRuntimeUrlFromCwd :: Maybe String -> IO Text
resolveRuntimeUrlFromCwd = \case
  Just url -> return (T.pack url)
  Nothing -> do
    exists <- doesFileExist "katari.toml"
    if exists
      then do
        config <- loadConfig "."
        return (fromMaybe "http://localhost:8000" (pcRuntimeUrl config))
      else return "http://localhost:8000"

-- ---------------------------------------------------------------------------
-- Simple TOML parser (sections with string key-value pairs)
-- ---------------------------------------------------------------------------

parseToml :: Text -> Map Text (Map Text Text)
parseToml content = snd $ foldl' parseLine ("", Map.empty) (T.lines content)
  where
    parseLine (section, m) rawLine =
      let line = T.strip rawLine
       in if T.null line || T.isPrefixOf "#" line
            then (section, m)
            else
              if T.isPrefixOf "[" line
                then (T.strip (T.takeWhile (/= ']') (T.drop 1 line)), m)
                else case T.breakOn "=" line of
                  (_, rest) | T.null rest -> (section, m)
                  (key, rest) ->
                    let val = unquote (T.strip (T.drop 1 rest))
                     in (section, Map.insertWith Map.union section (Map.singleton (T.strip key) val) m)
    unquote t
      | T.length t >= 2, T.head t == '"', T.last t == '"' = T.init (T.tail t)
      | otherwise = t
