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
-- # rev = "abc1234567890abcdef1234567890abcdef12345"
-- @
--
-- Secrets are intentionally NOT TOML fields — @katari.toml@ is commonly committed to VCS. The CLI
-- reads @KATARI_API_KEY@ straight from the environment. v0.1 deliberately omits @${VAR}@ text
-- interpolation of the file: substituting into the raw byte stream before parsing is injection-prone
-- (a value with a quote or newline rewrites the document), and with auth out of the file there is no
-- remaining use for it. If a real need appears, interpolate post-decode over string values only.
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
    PathOverride (..),
    GitOverride (..),
    loadKatariToml,
    parseKatariToml,
    isValidPackageName,
  )
where

import Control.Exception (IOException, try)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import GHC.List (List)
import Katari.Project.Error
  ( FileErrorInfo (..),
    ParseErrorInfo (..),
    ProjectError (..),
    ValidationErrorInfo (..),
  )
import TOML
  ( DecodeTOML (..),
    decodeWith,
    getField,
    getFieldOpt,
    renderTOMLError,
  )

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

-- | The local replacement / external source for one dependency named in 'packages'. Each variant
-- carries its own record rather than inlining fields, so record and sum syntax do not mix.
data OverrideSource
  = OverridePath PathOverride
  | OverrideGit GitOverride
  deriving (Show, Eq)

-- | @path = "..."@ — relative or absolute filesystem path.
newtype PathOverride = PathOverride
  { path :: FilePath
  }
  deriving (Show, Eq)

-- | @git = "..." rev = "..."@ — a git repo plus the ref to fetch. The vocabulary ('url', 'rev') is
-- shared with 'Katari.Project.Fetch.GitRef', 'Katari.Project.Snapshot.SnapshotPackage', and the
-- lockfile, so the same two concepts never go by two names.
data GitOverride = GitOverride
  { url :: Text,
    -- | The git ref to fetch; must be a full 40-char commit SHA for reproducibility.
    rev :: Text
  }
  deriving (Show, Eq)

-- ===========================================================================
-- Raw (pre-validation) decode target
-- ===========================================================================

-- | The shape decoded straight from TOML, before cross-field validation. Overrides are kept in their
-- permissive @path?/git?/rev?@ form here so the "path XOR git" rule is reported as a
-- 'ConfigValidationError' (with a clear message) rather than as a raw decode failure.
data RawConfig = RawConfig
  { package :: PackageSection,
    sidecar :: Maybe SidecarSection,
    runtime :: RuntimeSection,
    dependencies :: DependenciesSection,
    overrides :: Map Text RawOverride
  }

-- | An @[overrides.\<name>]@ table with every field optional, so a malformed combination surfaces as
-- a validation error we phrase, not a generic "missing key".
data RawOverride = RawOverride
  { path :: Maybe Text,
    git :: Maybe Text,
    rev :: Maybe Text
  }

instance DecodeTOML RawConfig where
  tomlDecoder =
    RawConfig
      <$> getField "package"
      <*> getFieldOpt "sidecar"
      <*> getField "runtime"
      <*> getField "dependencies"
      <*> (fromMaybe Map.empty <$> getFieldOpt "overrides")

instance DecodeTOML PackageSection where
  tomlDecoder =
    PackageSection
      <$> getField "name"
      <*> getFieldOpt "version"
      <*> getFieldOpt "description"
      <*> (maybe "src" Text.unpack <$> getFieldOpt "src")

instance DecodeTOML SidecarSection where
  tomlDecoder = SidecarSection . map Text.unpack <$> getField "sourceRoots"

instance DecodeTOML RuntimeSection where
  tomlDecoder = RuntimeSection <$> getField "url"

instance DecodeTOML DependenciesSection where
  tomlDecoder =
    DependenciesSection
      <$> getFieldOpt "registry"
      <*> getFieldOpt "snapshot"
      <*> (fromMaybe [] <$> getFieldOpt "packages")

instance DecodeTOML RawOverride where
  tomlDecoder =
    RawOverride
      <$> getFieldOpt "path"
      <*> getFieldOpt "git"
      <*> getFieldOpt "rev"

-- ===========================================================================
-- Loaders
-- ===========================================================================

-- | Read @katari.toml@ from disk, parse, and validate.
loadKatariToml :: FilePath -> IO (Either ProjectError ProjectConfig)
loadKatariToml path = do
  contents <- try (TextIO.readFile path)
  pure $ case contents of
    Left readError -> Left (ConfigIOError FileErrorInfo {path = path, message = ioErrorMessage readError})
    Right text -> parseKatariToml path text

-- | Parse the textual contents of @katari.toml@.
parseKatariToml :: FilePath -> Text -> Either ProjectError ProjectConfig
parseKatariToml path text = case decodeWith tomlDecoder text of
  Left tomlError ->
    Left (ConfigParseError ParseErrorInfo {path = path, position = Nothing, message = renderTOMLError tomlError})
  Right rawConfig -> validateConfig path rawConfig

-- | Apply the cross-field rules a 'Decoder' cannot express: each override is path XOR git, and every
-- override names a declared dependency.
validateConfig :: FilePath -> RawConfig -> Either ProjectError ProjectConfig
validateConfig path rawConfig = do
  let declared = rawConfig.dependencies.packages
  validatedOverrides <- traverse (validateOverride path) (Map.toList rawConfig.overrides)
  mapM_ (checkOverrideTarget path declared . fst) (Map.toList rawConfig.overrides)
  pure
    ProjectConfig
      { package = rawConfig.package,
        sidecar = rawConfig.sidecar,
        runtime = rawConfig.runtime,
        dependencies = rawConfig.dependencies,
        overrides = Map.fromList validatedOverrides
      }

-- | Resolve one @[overrides.\<name>]@ entry into its 'OverrideSource', or report why it is malformed.
validateOverride :: FilePath -> (Text, RawOverride) -> Either ProjectError (Text, OverrideSource)
validateOverride path (name, rawOverride) = case (rawOverride.path, rawOverride.git) of
  (Just _, Just _) -> validationError ("override '" <> name <> "' sets both path and git; choose one")
  (Just pathValue, Nothing) -> case rawOverride.rev of
    Just _ -> validationError ("override '" <> name <> "' sets rev, which is only valid with git")
    Nothing -> Right (name, OverridePath PathOverride {path = Text.unpack pathValue})
  (Nothing, Just gitValue) -> case rawOverride.rev of
    Nothing -> validationError ("git override '" <> name <> "' requires a rev (full commit SHA)")
    Just revValue -> Right (name, OverrideGit GitOverride {url = gitValue, rev = revValue})
  (Nothing, Nothing) -> validationError ("override '" <> name <> "' must set either path or git")
  where
    validationError message =
      Left (ConfigValidationError ValidationErrorInfo {path = path, position = Nothing, message = message})

-- | An override must name a dependency that actually appears in @[dependencies].packages@; a stray
-- override is almost always a typo in the name.
checkOverrideTarget :: FilePath -> List Text -> Text -> Either ProjectError ()
checkOverrideTarget path declared name
  | name `elem` declared = Right ()
  | otherwise =
      Left
        ( ConfigValidationError
            ValidationErrorInfo
              { path = path,
                position = Nothing,
                message = "override '" <> name <> "' names no dependency in [dependencies].packages"
              }
        )

-- | A package name is valid when it matches @[A-Za-z_][A-Za-z0-9_]*@ — i.e. it can appear as a
-- Katari identifier, since it is the literal text a consumer types after @import@. (Reserved-name
-- collisions with the compiler's @primitive@ / stdlib namespace are a separate check at resolve
-- time, in 'Katari.Project.Resolve'.)
isValidPackageName :: Text -> Bool
isValidPackageName name = case Text.uncons name of
  Nothing -> False
  Just (firstChar, rest) -> isIdentifierStart firstChar && Text.all isIdentifierContinue rest
  where
    isIdentifierStart character = isAsciiLower character || isAsciiUpper character || character == '_'
    isIdentifierContinue character = isIdentifierStart character || isDigit character

-- | A short, human-readable rendering of an 'IOException' for a 'FileErrorInfo' message.
ioErrorMessage :: IOException -> Text
ioErrorMessage = Text.pack . show
