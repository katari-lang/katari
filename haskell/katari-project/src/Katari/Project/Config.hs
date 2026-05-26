-- | TOML schema and loader for @katari.toml@.
--
-- Layout (v0.1 schema):
--
-- @
-- [package]
-- name = \"hello\"
-- # version     = \"0.1.0\"    # optional
-- # description = \"...\"      # optional, human-readable summary
-- # src         = \"src\"      # optional, default \"src\"
--
-- [runtime]
-- url = \"http:\/\/localhost:8000\"
--
-- # [sidecar]                  # optional
-- # sourceRoots = [\"src\"]
--
-- [dependencies]
-- # Pin the registry + snapshot version. \`katari init\` fills these in
-- # automatically by fetching the latest snapshot at scaffold time.
-- # registry = \"https:\/\/github.com\/katari-lang\/katari-registry\"
-- # snapshot = \"v0.1.0\"
-- packages = []
--
-- # [overrides.my_fork]
-- # path = \"..\/my_fork\"
-- #
-- # [overrides.upstream]
-- # git = \"https:\/\/...\"
-- # ref = \"abc1234567890abcdef1234567890abcdef12345\"
-- @
--
-- Auth is intentionally NOT a TOML field — @katari.toml@ is commonly
-- committed to VCS, and the auth value is a secret. CLI commands read
-- @KATARI_API_KEY@ from the environment instead.
--
-- Parsing is delegated to the @tomland@ library; this module only
-- defines the codec + post-parse validation.
module Katari.Project.Config
  ( ProjectConfig (..),
    PackageSection (..),
    SidecarSection (..),
    RuntimeSection (..),
    DependenciesSection (..),
    OverrideSource (..),
    ConfigError (..),
    parseKatariToml,
    loadKatariToml,
    interpolateEnv,
  )
where

import Control.Exception (IOException, try)
import Data.Bifunctor (first)
import Data.Char (isAlpha, isAlphaNum)
import qualified Data.HashMap.Strict as HashMap
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import qualified Toml
import Toml (TomlCodec, (.=))
import qualified Toml.Type.PrefixTree as Toml
import qualified Toml.Type.Key as Toml
import qualified Toml.Type.TOML as Toml
import qualified Validation
import System.Environment (lookupEnv)

-- ===========================================================================
-- Data types (post-validation)
-- ===========================================================================

data ProjectConfig = ProjectConfig
  { packageSection :: PackageSection,
    sidecarSection :: Maybe SidecarSection,
    runtimeSection :: RuntimeSection,
    dependenciesSection :: DependenciesSection,
    -- | Per-name overrides for entries in
    -- @dependenciesSection.dependenciesPackages@.
    overrides :: Map Text OverrideSource
  }
  deriving (Show, Eq)

data PackageSection = PackageSection
  { packageName :: Text,
    packageVersion :: Maybe Text,
    -- | Free-form human-readable summary. Surfaces in registry listings
    -- and @katari ls@-style output. Optional.
    packageDescription :: Maybe Text,
    -- | Relative source dir under the project root. Defaults to @"src"@.
    packageSrc :: FilePath
  }
  deriving (Show, Eq)

newtype SidecarSection = SidecarSection
  { sidecarSourceRoots :: [FilePath]
  }
  deriving (Show, Eq)

newtype RuntimeSection = RuntimeSection
  { runtimeUrl :: Text
  }
  deriving (Show, Eq)

-- | The @[dependencies]@ block.
--
-- A package name listed in @dependenciesPackages@ resolves to either:
--
--   * a matching @[overrides.\<name>]@ entry (path or git source), or
--   * the snapshot's pin for that name (when @registry@+@snapshot@ are set).
--
-- A name with neither resolution is a validation error.
data DependenciesSection = DependenciesSection
  { -- | Base URL of the registry holding snapshot files. Combined
    -- with 'dependenciesSnapshot' to locate the snapshot TOML.
    dependenciesRegistry :: Maybe Text,
    -- | Snapshot version identifier, e.g. @"v0.1.0"@.
    dependenciesSnapshot :: Maybe Text,
    -- | Flat list of dependency names this project uses.
    dependenciesPackages :: [Text]
  }
  deriving (Show, Eq)

-- | The local replacement / external source for a single dependency
-- listed in 'dependenciesPackages'.
data OverrideSource
  = -- | @path = "..."@ — relative or absolute filesystem path.
    OverridePath FilePath
  | -- | @git = "..." ref = "..."@ — full-SHA git ref.
    OverrideGit
      { gitUrl :: Text,
        gitRev :: Text
      }
  deriving (Show, Eq)

data ConfigError
  = ConfigIOError FilePath Text
  | ConfigParseError FilePath Text
  | ConfigValidationError FilePath Text
  deriving (Show, Eq)

-- ===========================================================================
-- Raw (pre-validation) shapes — mirror the TOML 1:1
-- ===========================================================================

-- | Pre-validation shape that mirrors the TOML layout literally. Every
-- field is optional (or has tomland-handled defaults) so we can produce
-- useful error messages from a post-parse validation pass instead of
-- failing inside the codec.
data RawConfig = RawConfig
  { rawPackage :: RawPackage,
    rawSidecar :: Maybe RawSidecar,
    rawRuntime :: Maybe RawRuntime,
    rawDependencies :: Maybe RawDependencies,
    rawOverrides :: Map Text RawOverride
  }
  deriving (Show)

data RawPackage = RawPackage
  { rawPackageName :: Text,
    rawPackageVersion :: Maybe Text,
    rawPackageDescription :: Maybe Text,
    rawPackageSrc :: Maybe FilePath
  }
  deriving (Show)

newtype RawSidecar = RawSidecar
  { rawSidecarSourceRoots :: [FilePath]
  }
  deriving (Show)

newtype RawRuntime = RawRuntime
  { rawRuntimeUrl :: Maybe Text
  }
  deriving (Show)

data RawDependencies = RawDependencies
  { rawDepsRegistry :: Maybe Text,
    rawDepsSnapshot :: Maybe Text,
    rawDepsPackages :: Maybe [Text]
  }
  deriving (Show)

data RawOverride = RawOverride
  { rawOverridePath :: Maybe FilePath,
    rawOverrideGit :: Maybe Text,
    rawOverrideRef :: Maybe Text
  }
  deriving (Show)

-- ===========================================================================
-- Codecs
-- ===========================================================================

-- | Codec for everything EXCEPT [overrides.X] sub-tables.
--
-- tomland's @tableMap@ does not reliably decode nested
-- @[overrides.\<name>]@ sections (it sees the prefix entry but
-- doesn't drill into the leaf), so we read those manually via
-- 'extractOverrides' against the raw 'Toml.TOML' AST after parsing.
rawConfigCodec :: TomlCodec RawConfig
rawConfigCodec =
  RawConfig
    <$> Toml.table rawPackageCodec "package" .= (.rawPackage)
    <*> Toml.dioptional (Toml.table rawSidecarCodec "sidecar") .= (.rawSidecar)
    <*> Toml.dioptional (Toml.table rawRuntimeCodec "runtime") .= (.rawRuntime)
    <*> Toml.dioptional (Toml.table rawDependenciesCodec "dependencies") .= (.rawDependencies)
    -- Overrides are stitched in by parseKatariToml after codec decoding.
    <*> pure Map.empty .= (.rawOverrides)

rawPackageCodec :: TomlCodec RawPackage
rawPackageCodec =
  RawPackage
    <$> Toml.text "name" .= (.rawPackageName)
    <*> Toml.dioptional (Toml.text "version") .= (.rawPackageVersion)
    <*> Toml.dioptional (Toml.text "description") .= (.rawPackageDescription)
    <*> Toml.dioptional (Toml.string "src") .= (.rawPackageSrc)

rawSidecarCodec :: TomlCodec RawSidecar
rawSidecarCodec =
  RawSidecar
    <$> Toml.arrayOf Toml._String "sourceRoots" .= (.rawSidecarSourceRoots)

rawRuntimeCodec :: TomlCodec RawRuntime
rawRuntimeCodec =
  RawRuntime
    <$> Toml.dioptional (Toml.text "url") .= (.rawRuntimeUrl)

rawDependenciesCodec :: TomlCodec RawDependencies
rawDependenciesCodec =
  RawDependencies
    <$> Toml.dioptional (Toml.text "registry") .= (.rawDepsRegistry)
    <*> Toml.dioptional (Toml.text "snapshot") .= (.rawDepsSnapshot)
    <*> Toml.dioptional (Toml.arrayOf Toml._Text "packages") .= (.rawDepsPackages)

-- ===========================================================================
-- Manual extraction of [overrides.X] from the raw TOML AST.
--
-- tomland's @tableMap@ enumerates the keys under a prefix but does not
-- recurse into nested @[prefix.name]@ sub-tables — it only opens the
-- single @[prefix]@ table and decodes its scalar keys. Our schema uses
-- nested sections (more idiomatic TOML), so we walk
-- 'Toml.tomlTables' for @overrides.X@ entries manually.
-- ===========================================================================

extractOverrides :: FilePath -> Toml.TOML -> Either ConfigError (Map Text RawOverride)
extractOverrides path toml =
  case HashMap.lookup overridesPiece ((Toml.tomlTables toml)) of
    Nothing -> Right Map.empty
    Just tree -> Map.fromList <$> walk tree
  where
    overridesPiece :: Toml.Piece
    overridesPiece = Toml.Piece "overrides"

    walk :: Toml.PrefixTree Toml.TOML -> Either ConfigError [(Text, RawOverride)]
    walk = \case
      Toml.Leaf fullKey sub ->
        case dropOverridesPrefix fullKey of
          Nothing -> Right []
          Just name -> do
            ov <- decodeOverride path name sub
            Right [(name, ov)]
      Toml.Branch _ _ children ->
        concat
          <$> traverse walk (HashMap.elems (children))

    -- Strip the leading "overrides" piece from a fully-qualified key like
    -- @overrides.my_fork@ and rejoin the rest with dots. Returns 'Nothing'
    -- if the key doesn't start with @overrides.@ or has no sub-pieces.
    dropOverridesPrefix :: Toml.Key -> Maybe Text
    dropOverridesPrefix key =
      case NonEmpty.toList (Toml.unKey key) of
        Toml.Piece "overrides" : rest@(_ : _) ->
          Just (Text.intercalate "." [p | Toml.Piece p <- rest])
        _ -> Nothing

decodeOverride :: FilePath -> Text -> Toml.TOML -> Either ConfigError RawOverride
decodeOverride path name sub =
  case Validation.validationToEither (Toml.runTomlCodec rawOverrideCodec sub) of
    Left errs ->
      Left
        ( ConfigValidationError
            path
            ("[overrides." <> name <> "]: " <> Toml.prettyTomlDecodeErrors errs)
        )
    Right ov -> Right ov

rawOverrideCodec :: TomlCodec RawOverride
rawOverrideCodec =
  RawOverride
    <$> Toml.dioptional (Toml.string "path") .= (.rawOverridePath)
    <*> Toml.dioptional (Toml.text "git") .= (.rawOverrideGit)
    <*> Toml.dioptional (Toml.text "ref") .= (.rawOverrideRef)

-- ===========================================================================
-- Public loaders
-- ===========================================================================

-- | Read @katari.toml@ from disk, interpolate @${VAR}@ env refs, parse,
-- validate. IO is the file read + env lookup.
loadKatariToml :: FilePath -> IO (Either ConfigError ProjectConfig)
loadKatariToml path = do
  readResult <- try (TextIO.readFile path) :: IO (Either IOException Text)
  case readResult of
    Left e -> pure (Left (ConfigIOError path (Text.pack (show e))))
    Right raw -> do
      interpolated <- interpolateEnv raw
      pure (parseKatariToml path interpolated)

-- | Parse the textual contents of @katari.toml@ (already env-interpolated).
parseKatariToml :: FilePath -> Text -> Either ConfigError ProjectConfig
parseKatariToml path raw = do
  toml <-
    first
      (ConfigParseError path . Text.pack . show)
      (Toml.parse raw)
  rawCfg <-
    first
      (ConfigParseError path . Toml.prettyTomlDecodeErrors)
      (Validation.validationToEither (Toml.runTomlCodec rawConfigCodec toml))
  overridesMap <- extractOverrides path toml
  validateConfig path (rawCfg {rawOverrides = overridesMap})

-- ===========================================================================
-- Validation
-- ===========================================================================

validateConfig :: FilePath -> RawConfig -> Either ConfigError ProjectConfig
validateConfig path RawConfig {..} = do
  -- Package: name is mandatory (enforced by the codec); src defaults.
  let pkg =
        PackageSection
          { packageName = rawPackage.rawPackageName,
            packageVersion = rawPackage.rawPackageVersion,
            packageDescription = rawPackage.rawPackageDescription,
            packageSrc = fromMaybe "src" rawPackage.rawPackageSrc
          }
  -- Sidecar: pass through if present.
  let sidecar =
        fmap
          (\s -> SidecarSection {sidecarSourceRoots = s.rawSidecarSourceRoots})
          rawSidecar
  -- Runtime: default url.
  let runtime =
        RuntimeSection
          { runtimeUrl =
              maybe
                "http://localhost:8000"
                (fromMaybe "http://localhost:8000" . (.rawRuntimeUrl))
                rawRuntime
          }
  -- Dependencies: default to "empty" if section absent.
  let deps =
        maybe
          DependenciesSection
            { dependenciesRegistry = Nothing,
              dependenciesSnapshot = Nothing,
              dependenciesPackages = []
            }
          ( \d ->
              DependenciesSection
                { dependenciesRegistry = d.rawDepsRegistry,
                  dependenciesSnapshot = d.rawDepsSnapshot,
                  dependenciesPackages = fromMaybe [] d.rawDepsPackages
                }
          )
          rawDependencies
  -- Overrides: each must be path XOR git+ref, and its name must be in
  -- dependenciesPackages.
  overrideMap <- traverse (validateOverride path) rawOverrides
  let orphan =
        [ name
          | name <- Map.keys overrideMap,
            name `notElem` deps.dependenciesPackages
        ]
  case orphan of
    (n : _) ->
      Left
        ( ConfigValidationError
            path
            ( "[overrides."
                <> n
                <> "] is declared but does not appear in [dependencies].packages"
            )
        )
    [] -> Right ()
  Right
    ProjectConfig
      { packageSection = pkg,
        sidecarSection = sidecar,
        runtimeSection = runtime,
        dependenciesSection = deps,
        overrides = overrideMap
      }

validateOverride :: FilePath -> RawOverride -> Either ConfigError OverrideSource
validateOverride path RawOverride {..} =
  case (rawOverridePath, rawOverrideGit, rawOverrideRef) of
    (Just p, Nothing, _) | not (null p) -> Right (OverridePath p)
    (Nothing, Just u, Just r) | not (Text.null u), not (Text.null r) ->
      Right OverrideGit {gitUrl = u, gitRev = r}
    (Just _, Just _, _) ->
      Left (ConfigValidationError path "[overrides.X] must use 'path' XOR 'git', not both")
    (Nothing, Just _, Nothing) ->
      Left (ConfigValidationError path "[overrides.X] is git source but missing required 'ref'")
    _ ->
      Left
        ( ConfigValidationError
            path
            "[overrides.X] must specify either 'path = \"...\"' or 'git = \"...\" ref = \"...\"'"
        )

-- ===========================================================================
-- Env interpolation
--
-- @${VAR}@ → @lookupEnv VAR@ (empty string if unset).
-- @\\${VAR}@ → @${VAR}@ (literal, no lookup).
-- ===========================================================================

interpolateEnv :: Text -> IO Text
interpolateEnv input = Text.pack . reverse <$> go (Text.unpack input) []
  where
    go :: String -> String -> IO String
    go [] acc = pure acc
    go ('\\' : '$' : '{' : rest) acc =
      case spanName rest of
        Just (name, '}' : after) ->
          go after (reverse ("${" <> name <> "}") <> acc)
        _ -> go rest ('{' : '$' : '\\' : acc)
    go ('$' : '{' : rest) acc =
      case spanName rest of
        Just (name, '}' : after) -> do
          val <- lookupEnv name
          go after (reverse (fromMaybe "" val) <> acc)
        _ -> go rest ('{' : '$' : acc)
    go (c : rest) acc = go rest (c : acc)

    spanName :: String -> Maybe (String, String)
    spanName s = case span isVarChar s of
      ([], _) -> Nothing
      (name@(h : _), t)
        | isAlphaOrUnder h -> Just (name, t)
        | otherwise -> Nothing

    isVarChar c = isAlphaNum c || c == '_'
    isAlphaOrUnder c = isAlpha c || c == '_'
