-- | TOML schema and loader for @katari.toml@.
--
-- Layout (v0.1 schema):
--
-- @
-- [package]
-- name = "hello"
-- # version     = "0.1.0"    # optional
-- # description = "..."      # optional, human-readable summary
-- # src         = "src"      # optional, default "src"
--
-- [runtime]
-- url = "http://localhost:8000"
--
-- # [sidecar]                # optional; consumed by the bundler
-- # sourceRoots = ["src"]
--
-- [dependencies]
-- # registry = "https://github.com/katari-lang/katari-registry"   # optional
-- # snapshot = "v0.1.0"                                           # optional
-- packages = []
--
-- # [overrides.my_fork]
-- # path = "../my_fork"
-- #
-- # [overrides.upstream]
-- # git = "https://..."
-- # ref = "abc1234567890abcdef1234567890abcdef12345"
-- @
--
-- Auth is intentionally NOT a TOML field — @katari.toml@ is commonly committed to VCS and the auth
-- value is a secret. CLI commands read @KATARI_API_KEY@ from the environment instead.
--
-- Parsing uses @toml-reader@: the dynamic-key @[overrides.\<name>]@ tables decode straight into a
-- 'Map', so there is no nested-table workaround. Cross-field rules (path XOR git; every override
-- names a declared dependency) are checked after decoding.
module Katari.Project.Config
  ( ProjectConfig (..),
    PackageSection (..),
    SidecarSection (..),
    RuntimeSection (..),
    DependenciesSection (..),
    OverrideSource (..),
    loadKatariToml,
    parseKatariToml,
    interpolateEnv,
    isValidPackageName,
  )
where

import Data.Map.Strict (Map)
import Data.Text (Text)
import GHC.List (List)
import Katari.Project.Error (ProjectError)

-- ===========================================================================
-- Public (validated) types
-- ===========================================================================

data ProjectConfig = ProjectConfig
  { package :: PackageSection,
    sidecar :: Maybe SidecarSection,
    runtime :: RuntimeSection,
    dependencies :: DependenciesSection,
    -- | Per-name overrides for entries in @dependencies.packages@.
    overrides :: Map Text OverrideSource
  }
  deriving (Show, Eq)

data PackageSection = PackageSection
  { name :: Text,
    version :: Maybe Text,
    -- | Free-form human-readable summary; surfaces in registry / @katari ls@ output.
    description :: Maybe Text,
    -- | Relative source dir under the project root. Defaults to @"src"@.
    src :: FilePath
  }
  deriving (Show, Eq)

newtype SidecarSection = SidecarSection
  { sourceRoots :: List FilePath
  }
  deriving (Show, Eq)

newtype RuntimeSection = RuntimeSection
  { url :: Text
  }
  deriving (Show, Eq)

-- | The @[dependencies]@ block. A name in 'packages' resolves to either a matching
-- @[overrides.\<name>]@ entry or the snapshot's pin (when 'registry' + 'snapshot' are set); a name
-- with neither resolution is an error at resolve time.
data DependenciesSection = DependenciesSection
  { -- | Base URL of the registry holding snapshot files.
    registry :: Maybe Text,
    -- | Snapshot version identifier, e.g. @"v0.1.0"@.
    snapshot :: Maybe Text,
    -- | Flat list of dependency names this project uses.
    packages :: List Text
  }
  deriving (Show, Eq)

-- | The local replacement / external source for one dependency named in 'packages'.
data OverrideSource
  = -- | @path = "..."@ — relative or absolute filesystem path.
    OverridePath FilePath
  | -- | @git = "..." ref = "..."@ — full-SHA git ref.
    OverrideGit
      { url :: Text,
        rev :: Text
      }
  deriving (Show, Eq)

-- ===========================================================================
-- Loaders
-- ===========================================================================

-- | Read @katari.toml@ from disk, interpolate @${VAR}@ env refs, parse, and validate.
loadKatariToml :: FilePath -> IO (Either ProjectError ProjectConfig)
loadKatariToml = error "TODO: Katari.Project.Config.loadKatariToml"

-- | Parse the textual contents of @katari.toml@ (already env-interpolated).
parseKatariToml :: FilePath -> Text -> Either ProjectError ProjectConfig
parseKatariToml = error "TODO: Katari.Project.Config.parseKatariToml"

-- | Expand @${VAR}@ env references (@\\${VAR}@ stays literal; unset vars become the empty string).
interpolateEnv :: Text -> IO Text
interpolateEnv = error "TODO: Katari.Project.Config.interpolateEnv"

-- | A package name is valid when it matches @[A-Za-z_][A-Za-z0-9_]*@ — i.e. it can appear as a
-- Katari identifier, since it is the literal text a consumer types after @import@.
isValidPackageName :: Text -> Bool
isValidPackageName = error "TODO: Katari.Project.Config.isValidPackageName"
