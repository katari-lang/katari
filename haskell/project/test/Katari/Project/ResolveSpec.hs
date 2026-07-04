module Katari.Project.ResolveSpec (spec) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import GHC.List (List)
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Project.Config
  ( DependenciesSection (..),
    PackageSection (..),
    ProjectConfig (..),
    RuntimeSection (..),
  )
import Katari.Project.Discovery (SourceEntry (..), emptyOverlay)
import Katari.Project.Error (ProjectError (..))
import Katari.Project.Lockfile (GitSource (..), LockedSource (..), Lockfile (..), PathLock (..))
import Katari.Project.Resolve
  ( ProjectAssembly (..),
    ResolvedPackage (..),
    ResolvedProject (..),
    assembleProject,
    checkPinnedSha,
    compileInputSources,
    loadProjectOffline,
    lockfileFromResolved,
    resolveProject,
  )
import Network.HTTP.Client (defaultManagerSettings, newManager)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
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
  ResolvedProject {rootPackage = rootPackage, depPackages = Map.fromList deps, snapshotCompilerVersion = Nothing}

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

isCycle :: ProjectError -> Bool
isCycle projectError = case projectError of
  ResolveCycle _ -> True
  _ -> False

isShaMismatch :: ProjectError -> Bool
isShaMismatch projectError = case projectError of
  ResolveShaMismatch _ -> True
  _ -> False

isLockfileOutOfDate :: ProjectError -> Bool
isLockfileOutOfDate projectError = case projectError of
  ResolveLockfileOutOfDate _ -> True
  _ -> False

-- | A minimal @katari.toml@ for an on-disk fixture: a package name, its declared dependencies, and
-- path overrides for them.
projectToml :: Text -> List Text -> List (Text, Text) -> Text
projectToml name deps overrides =
  Text.unlines $
    [ "[package]",
      "name = \"" <> name <> "\"",
      "[runtime]",
      "url = \"http://localhost\"",
      "[dependencies]",
      "packages = [" <> Text.intercalate ", " [quote dep | dep <- deps] <> "]"
    ]
      <> concat [["[overrides." <> depName <> "]", "path = " <> quote path] | (depName, path) <- overrides]
  where
    quote value = "\"" <> value <> "\""

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

    it "rejects a dependency on the compiler-reserved prelude namespace" $ do
      let project = projectWith (rootPackageWith ["main"]) [("prelude", dependencyPackage "prelude" ["prelude"] Nothing)]
      assembleProject project `shouldSatisfy` either isReservedName (const False)

  describe "compileInputSources" $
    it "projects the assembly down to module -> source text" $ do
      let project = projectWith (rootPackageWith ["main"]) [("lib", dependencyPackage "lib" ["lib"] Nothing)]
      case assembleProject project of
        Left projectError -> expectationFailure ("expected success, got " <> show projectError)
        Right assembly ->
          compileInputSources assembly
            `shouldBe` Map.fromList [(ModuleName "main", "source of main"), (ModuleName "lib", "source of lib")]

  describe "lockfileFromResolved" $ do
    it "projects dependency provenance into the lockfile" $ do
      let provenance = LockedPath PathLock {location = "../lib"}
          project = projectWith (rootPackageWith ["main"]) [("lib", dependencyPackage "lib" ["lib"] (Just provenance))]
          lockfile = lockfileFromResolved project
      lockfile.version `shouldBe` 1
      lockfile.snapshot `shouldBe` Nothing
      Map.lookup "lib" lockfile.packages `shouldBe` Just provenance

    it "preserves a git pin and propagates the snapshot id" $ do
      let provenance = LockedGit GitSource {url = "https://github.com/x/y", rev = "deadbeef", sha = Text.replicate 64 "a"}
          rootConfig = (configNamed "app") {dependencies = DependenciesSection {registry = Nothing, snapshot = Just "v0.1.0", packages = ["lib"]}}
          rootPackage = ResolvedPackage {root = "/app", config = rootConfig, sources = sourcesFor ["main"], provenance = Nothing}
          project = projectWith rootPackage [("lib", dependencyPackage "lib" ["lib"] (Just provenance))]
          lockfile = lockfileFromResolved project
      lockfile.snapshot `shouldBe` Just "v0.1.0"
      Map.lookup "lib" lockfile.packages `shouldBe` Just provenance

  describe "checkPinnedSha" $ do
    it "accepts a fetched hash that matches its pin" $
      checkPinnedSha "lib" (Just "deadbeef") "deadbeef" `shouldBe` Right ()

    it "rejects a fetched hash that disagrees with its pin (tampered content)" $
      checkPinnedSha "lib" (Just "deadbeef") "0badf00d" `shouldSatisfy` either isShaMismatch (const False)

    it "accepts when there is no pin to verify against (git override, trust on first use)" $
      checkPinnedSha "lib" Nothing "anything" `shouldBe` Right ()

  describe "resolveProject" $
    it "rejects a dependency cycle" $
      withSystemTempDirectory "katari-resolve" $ \tmp -> do
        let writeProject dir name deps overrides = do
              createDirectoryIfMissing True dir
              TextIO.writeFile (dir </> "katari.toml") (projectToml name deps overrides)
        -- Resolution is root-authoritative, so the root declares and overrides every package in the
        -- a <-> b cycle; the cycle is closed by a depending on b and b back on a.
        writeProject (tmp </> "app") "app" ["a", "b"] [("a", "../a"), ("b", "../b")]
        writeProject (tmp </> "a") "a" ["b"] []
        writeProject (tmp </> "b") "b" ["a"] []
        manager <- newManager defaultManagerSettings
        result <- resolveProject manager (tmp </> "app")
        result `shouldSatisfy` either isCycle (const False)

  describe "loadProjectOffline" $
    it "reports a lock that omits a transitive dependency as out of date" $
      withSystemTempDirectory "katari-offline" $ \tmp -> do
        let writeProject dir name deps = do
              createDirectoryIfMissing True dir
              TextIO.writeFile (dir </> "katari.toml") (projectToml name deps [])
        -- The root locks its path dependency 'a' (offline load reads the lock, not overrides), but
        -- 'a' itself declares 'b', which the lock omits — so the lock is an incomplete closure.
        writeProject (tmp </> "app") "app" ["a"]
        writeProject (tmp </> "a") "a" ["b"]
        TextIO.writeFile
          (tmp </> "app" </> "katari.lock")
          (Text.unlines ["[lock]", "version = 1", "", "[packages.a]", "source = \"path\"", "path = \"../a\""])
        result <- loadProjectOffline emptyOverlay (tmp </> "app")
        result `shouldSatisfy` either isLockfileOutOfDate (const False)
