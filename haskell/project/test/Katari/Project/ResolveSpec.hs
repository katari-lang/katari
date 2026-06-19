module Katari.Project.ResolveSpec (spec) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.List (List)
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Project.Config
  ( DependenciesSection (..),
    PackageSection (..),
    ProjectConfig (..),
    RuntimeSection (..),
  )
import Katari.Project.Discovery (SourceEntry (..))
import Katari.Project.Error (ProjectError (..))
import Katari.Project.Lockfile (LockedSource (..), Lockfile (..), PathLock (..))
import Katari.Project.Resolve
  ( ProjectAssembly (..),
    ResolvedPackage (..),
    ResolvedProject (..),
    assembleProject,
    compileInputSources,
    lockfileFromResolved,
  )
import Test.Hspec

-- | A minimal config carrying just the package name; the assembly logic reads only @package.name@,
-- @dependencies.snapshot@, and the source map.
configNamed :: Text -> ProjectConfig
configNamed name =
  ProjectConfig
    { package = PackageSection {name = name, version = Nothing, description = Nothing, src = "src"},
      sidecar = Nothing,
      runtime = RuntimeSection {url = "http://localhost"},
      dependencies = DependenciesSection {registry = Nothing, snapshot = Nothing, packages = []},
      overrides = Map.empty
    }

sourcesFor :: List Text -> Map ModuleName SourceEntry
sourcesFor moduleNames =
  Map.fromList
    [ (ModuleName name, SourceEntry {path = Text.unpack name <> ".ktr", text = "source of " <> name})
      | name <- moduleNames
    ]

-- | A dependency package keyed by @name@, laying out @moduleNames@ as its sources with the given
-- provenance.
dependencyPackage :: Text -> List Text -> Maybe LockedSource -> ResolvedPackage
dependencyPackage name moduleNames provenance =
  ResolvedPackage
    { root = "/cache/" <> Text.unpack name,
      config = configNamed name,
      sources = sourcesFor moduleNames,
      provenance = provenance
    }

projectWith :: ResolvedPackage -> List (Text, ResolvedPackage) -> ResolvedProject
projectWith rootPackage deps =
  ResolvedProject {rootPackage = rootPackage, depPackages = Map.fromList deps}

rootPackageWith :: List Text -> ResolvedPackage
rootPackageWith moduleNames =
  ResolvedPackage
    { root = "/app",
      config = configNamed "app",
      sources = sourcesFor moduleNames,
      provenance = Nothing
    }

isModuleCollision :: ProjectError -> Bool
isModuleCollision projectError = case projectError of
  ResolveModuleCollision _ -> True
  _ -> False

isOutOfNamespace :: ProjectError -> Bool
isOutOfNamespace projectError = case projectError of
  ResolveOutOfNamespace _ -> True
  _ -> False

isNameMismatch :: ProjectError -> Bool
isNameMismatch projectError = case projectError of
  ResolveDependencyNameMismatch _ -> True
  _ -> False

isReservedName :: ProjectError -> Bool
isReservedName projectError = case projectError of
  ResolveReservedPackageName _ -> True
  _ -> False

spec :: Spec
spec = do
  describe "assembleProject" $ do
    it "unions the root and a well-namespaced dependency" $ do
      let project =
            projectWith
              (rootPackageWith ["main"])
              [("lib", dependencyPackage "lib" ["lib", "lib.util"] Nothing)]
      case assembleProject project of
        Left projectError -> expectationFailure ("expected success, got " <> show projectError)
        Right assembly ->
          Map.keysSet assembly.sources
            `shouldBe` Map.keysSet (sourcesFor ["main", "lib", "lib.util"])

    it "rejects a module outside the dependency's namespace" $ do
      let project = projectWith (rootPackageWith ["main"]) [("lib", dependencyPackage "lib" ["other"] Nothing)]
      assembleProject project `shouldSatisfy` either isOutOfNamespace (const False)

    it "rejects a dependency whose [package].name disagrees with its key" $ do
      let project = projectWith (rootPackageWith ["main"]) [("lib", dependencyPackage "different" ["lib"] Nothing)]
      assembleProject project `shouldSatisfy` either isNameMismatch (const False)

    it "rejects a module name provided by two packages" $ do
      let project = projectWith (rootPackageWith ["lib"]) [("lib", dependencyPackage "lib" ["lib"] Nothing)]
      assembleProject project `shouldSatisfy` either isModuleCollision (const False)

    it "rejects a dependency on the compiler-reserved primitive namespace" $ do
      let project = projectWith (rootPackageWith ["main"]) [("primitive", dependencyPackage "primitive" ["primitive"] Nothing)]
      assembleProject project `shouldSatisfy` either isReservedName (const False)

  describe "compileInputSources" $
    it "projects the assembly down to module -> source text" $ do
      let project = projectWith (rootPackageWith ["main"]) [("lib", dependencyPackage "lib" ["lib"] Nothing)]
      case assembleProject project of
        Left projectError -> expectationFailure ("expected success, got " <> show projectError)
        Right assembly ->
          compileInputSources assembly
            `shouldBe` Map.fromList [(ModuleName "main", "source of main"), (ModuleName "lib", "source of lib")]

  describe "lockfileFromResolved" $
    it "projects dependency provenance into the lockfile" $ do
      let provenance = LockedPath PathLock {location = "../lib"}
          project = projectWith (rootPackageWith ["main"]) [("lib", dependencyPackage "lib" ["lib"] (Just provenance))]
          lockfile = lockfileFromResolved project
      lockfile.version `shouldBe` 1
      lockfile.snapshot `shouldBe` Nothing
      Map.lookup "lib" lockfile.packages `shouldBe` Just provenance
