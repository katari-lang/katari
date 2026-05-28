-- | Disk-backed compile cache at @.katari\/cache\/compile-cache.json@.
--
-- Stores per-module source hashes, IR fragments, schema entries, and
-- diagnostics. Parse / identify / typecheck run every time (they're
-- fast); lowering and schema are skipped on cache hit.
module Katari.Cli.CompileCache
  ( DiskCache (..),
    DiskModuleEntry (..),
    loadDiskCache,
    saveDiskCache,
    diskCachePath,
    toDiskCache,
    applyDiskCache,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), eitherDecodeStrict', encode, genericParseJSON, genericToJSON)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import GHC.Generics (Generic)
import Katari.AST qualified as AST
import Katari.Compile (ModuleCache (..))
import Katari.Diagnostic (Diagnostic)
import Katari.Lowering (ModuleLoweringResult (..))
import Katari.Schema (SchemaEntry)
import Katari.SourceSpan (Position (..), SourceSpan (..))
import Katari.Typechecker.Identifier (ModuleData (..))
import Katari.Typechecker.ModuleInterface (ModuleInterface (..))
import System.Directory (doesFileExist)

-- | On-disk cache for all modules.
newtype DiskCache = DiskCache
  { modules :: Map Text DiskModuleEntry
  }
  deriving (Show, Generic)

instance ToJSON DiskCache where
  toJSON = genericToJSON Aeson.defaultOptions

instance FromJSON DiskCache where
  parseJSON = genericParseJSON Aeson.defaultOptions

-- | Per-module cache entry stored on disk. Only the lowering/schema
-- outputs and diagnostics — identifier / typecheck results are
-- recomputed (they're fast and hard to serialize).
data DiskModuleEntry = DiskModuleEntry
  { sourceHash :: Int,
    loweringResult :: ModuleLoweringResult,
    schemaEntries :: [SchemaEntry],
    diagnostics :: [Diagnostic]
  }
  deriving (Show, Generic)

instance ToJSON DiskModuleEntry where
  toJSON = genericToJSON Aeson.defaultOptions

instance FromJSON DiskModuleEntry where
  parseJSON = genericParseJSON Aeson.defaultOptions

-- | Path to the compile cache file within a project.
diskCachePath :: FilePath -> FilePath
diskCachePath projectRoot = projectRoot <> "/.katari/cache/compile-cache.json"

-- | Load cached entries from disk. Returns empty on missing or
-- corrupt file.
loadDiskCache :: FilePath -> IO DiskCache
loadDiskCache projectRoot = do
  let path = diskCachePath projectRoot
  exists <- doesFileExist path
  if not exists
    then pure (DiskCache Map.empty)
    else do
      bytes <- BS.readFile path
      case eitherDecodeStrict' bytes of
        Right cache -> pure cache
        Left _ -> pure (DiskCache Map.empty)

-- | Write cache to disk.
saveDiskCache :: FilePath -> DiskCache -> IO ()
saveDiskCache projectRoot cache = do
  let path = diskCachePath projectRoot
  LBS.writeFile path (encode cache)

-- | Extract disk-cacheable data from the compiler's updated cache.
toDiskCache :: Map Text ModuleCache -> DiskCache
toDiskCache updatedCache =
  DiskCache
    { modules =
        Map.map
          ( \mc ->
              DiskModuleEntry
                { sourceHash = mc.cacheSourceHash,
                  loweringResult = mc.cacheLoweringResult,
                  schemaEntries = mc.cacheSchemaEntries,
                  diagnostics = mc.cacheDiagnostics
                }
          )
          updatedCache
    }

-- | Inject disk cache entries into the compiler's ModuleCache map.
-- Only the fields we persist are populated; the rest are left empty
-- (the compiler will re-derive them from parse/identify/typecheck).
applyDiskCache :: DiskCache -> Map Text ModuleCache
applyDiskCache (DiskCache entries) =
  Map.map toModuleCache entries
  where
    toModuleCache entry =
      ModuleCache
        { cacheSourceHash = entry.sourceHash,
          cacheImports = [],
          cacheIdentifierVariables = Map.empty,
          cacheIdentifierTypes = Map.empty,
          cacheIdentifierRequests = Map.empty,
          cacheIdentifierConstructors = Map.empty,
          cacheModuleData = ModuleData {moduleSourceSpan = emptySpan},
          cacheModuleExports = Map.empty,
          cacheModuleTopLevel = Map.empty,
          cacheInterface = ModuleInterface {exportedTypes = Map.empty},
          cacheDataAnnotations = Map.empty,
          cacheLoweringResult = entry.loweringResult,
          cacheSchemaEntries = entry.schemaEntries,
          cacheDiagnostics = entry.diagnostics
        }

    emptySpan =
      SrcSpan
        { filePath = "",
          start = Position {line = 0, column = 0},
          end = Position {line = 0, column = 0}
        }
