-- | Multi-package project resolution.
--
-- Given a path inside a Katari project, walk the @[dependencies.*]@
-- graph (path deps only in v1), load every reachable package, and
-- assemble a single 'Compile.CompileInput' the compiler can consume.
--
-- Module-name layout:
--
--   * Root package's modules keep their bare relative-path name.
--     @src\/main.ktr@ → module @main@; @src\/foo\/bar.ktr@ → module
--     @foo.bar@.
--   * Dependency package @P@'s modules are prefixed: dep @list-utils@
--     with @src\/main.ktr@ becomes module @list-utils.main@.
--   * Package names must be valid Katari identifiers (alphanumeric +
--     underscore) so they round-trip through Katari source as module
--     references.
--
-- Sibling imports inside a dependency keep their natural form: the
-- consumers' bare @import P@ desugars via 'Compile.packageMainModules'
-- to @P.\<main_module>@; all other references are fully qualified.
module Katari.Project.Resolve
  ( ResolvedProject (..),
    ResolvedPackage (..),
    ResolveError (..),
    ProjectAssembly (..),
    loadResolvedProject,
    assembleProject,
  )
where

import Control.Monad (foldM)
import Data.Char (isAlphaNum)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Katari.Project.Config
  ( ConfigError,
    PackageSection (..),
    PathDependency (..),
    ProjectConfig (..),
    loadKatariToml,
  )
import Katari.Project.Discovery (SourceEntry (..), configFilename, scanSources)
import System.Directory (canonicalizePath, doesFileExist)
import System.FilePath (isAbsolute, (</>))

-- ===========================================================================
-- Data
-- ===========================================================================

-- | One loaded package (its config + its on-disk module sources).
data ResolvedPackage = ResolvedPackage
  { -- | Absolute canonical path of the directory containing this
    -- package's @katari.toml@.
    packageRoot :: FilePath,
    -- | The package's parsed config.
    packageConfig :: ProjectConfig,
    -- | Module name (as written in the package's own source tree, i.e.
    -- relative to its @[compile].src@) → 'SourceEntry'.
    packageSources :: Map Text SourceEntry
  }
  deriving (Show)

-- | The full transitive closure starting from the root @katari.toml@.
data ResolvedProject = ResolvedProject
  { rootPackage :: ResolvedPackage,
    -- | Every dependency reachable from the root, keyed by package
    -- name. The root package is NOT included here.
    depPackages :: Map Text ResolvedPackage
  }
  deriving (Show)

data ResolveError
  = -- | A @katari.toml@ along the dep chain failed to load or parse.
    -- The path identifies the offending file.
    ResolveConfigError ConfigError
  | -- | The dep chain contains a cycle. The list shows the cycle path
    -- starting and ending with the same package name.
    ResolveCycle [Text]
  | -- | A path dependency points at a directory that has no
    -- @katari.toml@.
    ResolveMissingConfig Text FilePath
  | -- | Same dep name resolved to two different package roots.
    -- @v1@ rejects this conservatively rather than picking a winner.
    ResolveAmbiguousDep Text FilePath FilePath
  | -- | A package name contains a character outside of @[A-Za-z0-9_]@
    -- (= cannot appear as a Katari identifier).
    ResolveInvalidPackageName Text
  | -- | Two reachable packages contribute the same module key. This is
    -- a setup error — one of them mis-named its sources.
    ResolveModuleCollision Text
  | -- | A package's @src\/@ contains a file whose module name does not
    -- start with the package's namespace. Args: package name, offending
    -- module name.
    ResolveOutOfNamespace Text Text
  | -- | A dependency's @[package].name@ disagrees with the key it is
    -- declared under. Args: declared key, actual package name.
    ResolveDepNameMismatch Text Text
  deriving (Show)

-- ===========================================================================
-- Loading
-- ===========================================================================

-- | Load a project rooted at @rootDir@ (= the directory containing the
-- top-level @katari.toml@) and recursively follow every path dep.
--
-- The /dep key/ (= the @\<name>@ in @[dependencies.\<name>]@) must be
-- a valid Katari identifier because that is the literal text a
-- consumer types in @import \<name>@. A package's own
-- @[package].name@ is informational and may include hyphens.
loadResolvedProject :: FilePath -> IO (Either ResolveError ResolvedProject)
loadResolvedProject rootDir = do
  canonicalRoot <- canonicalizePath rootDir
  rootRes <- loadOnePackage canonicalRoot
  case rootRes of
    Left err -> pure (Left err)
    Right rootPkg -> walkDeps rootPkg

walkDeps :: ResolvedPackage -> IO (Either ResolveError ResolvedProject)
walkDeps rootPkg =
  let initialQueue =
        [ (depName, dep, rootPkg.packageRoot)
          | (depName, dep) <-
              Map.toList rootPkg.packageConfig.dependencies
        ]
   in go Set.empty Map.empty initialQueue
  where
    go _visited accDeps [] =
      pure (Right ResolvedProject {rootPackage = rootPkg, depPackages = accDeps})
    go visited accDeps ((depName, dep, parentRoot) : rest) = case validatePackageName depName of
      Just err -> pure (Left err)
      Nothing
        | Set.member depName visited ->
            case Map.lookup depName accDeps of
              Just existing -> do
                expected <- canonicalizePath (resolveDepDir parentRoot dep.depPath)
                if existing.packageRoot == expected
                  then go visited accDeps rest
                  else
                    pure
                      ( Left
                          ( ResolveAmbiguousDep
                              depName
                              existing.packageRoot
                              expected
                          )
                      )
              Nothing -> pure (Left (ResolveCycle [depName]))
        | otherwise -> do
            let depDir = resolveDepDir parentRoot dep.depPath
            canonical <- canonicalizePath depDir
            if canonical == rootPkg.packageRoot
              then pure (Left (ResolveCycle [depName, rootPkg.packageConfig.packageSection.packageName]))
              else do
                cfgExists <- doesFileExist (canonical </> configFilename)
                if not cfgExists
                  then pure (Left (ResolveMissingConfig depName canonical))
                  else do
                    pkgRes <- loadOnePackage canonical
                    case pkgRes of
                      Left err -> pure (Left err)
                      Right pkg -> do
                        let visited' = Set.insert depName visited
                            accDeps' = Map.insert depName pkg accDeps
                            transitive =
                              [ (childName, child, canonical)
                                | (childName, child) <-
                                    Map.toList pkg.packageConfig.dependencies
                              ]
                        go visited' accDeps' (transitive <> rest)

loadOnePackage :: FilePath -> IO (Either ResolveError ResolvedPackage)
loadOnePackage absRoot = do
  cfgRes <- loadKatariToml (absRoot </> configFilename)
  case cfgRes of
    Left err -> pure (Left (ResolveConfigError err))
    Right cfg -> do
      sources <- scanSources absRoot cfg
      pure
        ( Right
            ResolvedPackage
              { packageRoot = absRoot,
                packageConfig = cfg,
                packageSources = sources
              }
        )

resolveDepDir :: FilePath -> FilePath -> FilePath
resolveDepDir parentRoot depPath
  | isAbsolute depPath = depPath
  | otherwise = parentRoot </> depPath

validatePackageName :: Text -> Maybe ResolveError
validatePackageName name
  | Text.null name = Just (ResolveInvalidPackageName name)
  | Text.all validChar name && validHead (Text.head name) = Nothing
  | otherwise = Just (ResolveInvalidPackageName name)
  where
    validChar c = isAlphaNum c || c == '_'
    validHead c = not (c >= '0' && c <= '9')

-- ===========================================================================
-- Assembly
-- ===========================================================================

-- | A compiler-agnostic flattened view of a 'ResolvedProject'. Callers
-- convert this to whatever shape their compiler entry point expects.
--
-- @sources@ keys are module names verbatim — the convention is
-- enforced by 'assembleProject', so a package @P@ contributes keys
-- @P@, @P.foo@, @P.bar.baz@, etc., and never anything outside its
-- namespace.
newtype ProjectAssembly = ProjectAssembly
  { sources :: Map Text SourceEntry
  }
  deriving (Show)

-- | Flatten a 'ResolvedProject' into a 'ProjectAssembly'. Walks the
-- root + every dep, validates the source layout (each file's module
-- key starts with the package name), checks for cross-package
-- collisions, and concatenates the source maps.
--
-- Dep keys must agree with the dep's own @[package].name@ — the key
-- is what consumers type after @import@, so a mismatch would leave a
-- dep unreachable.
assembleProject :: ResolvedProject -> Either ResolveError ProjectAssembly
assembleProject rp = do
  let entries = rootEntry : Map.toList rp.depPackages
  validated <- traverse checkOne entries
  foldM mergeOne (ProjectAssembly Map.empty) validated
  where
    rootKey = rp.rootPackage.packageConfig.packageSection.packageName
    rootEntry = (rootKey, rp.rootPackage)

    checkOne :: (Text, ResolvedPackage) -> Either ResolveError (Text, ResolvedPackage)
    checkOne entry@(declaredKey, pkg) = do
      case validatePackageName declaredKey of
        Just err -> Left err
        Nothing -> Right ()
      let actualName = pkg.packageConfig.packageSection.packageName
      if declaredKey /= actualName
        then Left (ResolveDepNameMismatch declaredKey actualName)
        else case findOutOfNamespace declaredKey pkg.packageSources of
          Just bad -> Left (ResolveOutOfNamespace declaredKey bad)
          Nothing -> Right entry

    mergeOne :: ProjectAssembly -> (Text, ResolvedPackage) -> Either ResolveError ProjectAssembly
    mergeOne acc (_, pkg) =
      let new = pkg.packageSources
          collisions = Set.intersection (Map.keysSet acc.sources) (Map.keysSet new)
       in if not (Set.null collisions)
            then Left (ResolveModuleCollision (Set.findMin collisions))
            else Right (ProjectAssembly (Map.union acc.sources new))

-- | Returns the first module key in @sources@ whose path is not under
-- the package's namespace (= not equal to @pkg@ and not prefixed by
-- @pkg.@), or 'Nothing' when every entry is in-namespace.
findOutOfNamespace :: Text -> Map Text a -> Maybe Text
findOutOfNamespace pkg sources =
  let prefix = pkg <> "."
      inNamespace k = k == pkg || prefix `Text.isPrefixOf` k
   in case filter (not . inNamespace) (Map.keys sources) of
        [] -> Nothing
        (bad : _) -> Just bad
