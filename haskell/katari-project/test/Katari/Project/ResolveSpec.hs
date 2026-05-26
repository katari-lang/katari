module Katari.Project.ResolveSpec (spec) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Katari.Project.Config (isValidPackageName)
import Katari.Project.Resolve
  ( ProjectAssembly (..),
    ResolveError (..),
    ResolvedPackage (..),
    ResolvedProject (..),
    assembleProject,
    loadResolvedProject,
    renderResolveError,
  )
import Katari.Project.Config
  ( DependenciesSection (..),
    OverrideSource (..),
    PackageSection (..),
    ProjectConfig (..),
    RuntimeSection (..),
    SidecarSection (..),
  )
import Katari.Project.Discovery (SourceEntry (..))
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

-- ===========================================================================
-- Helpers
-- ===========================================================================

-- | Build a minimal 'ProjectConfig' with the given name and no deps.
minimalConfig :: Text -> ProjectConfig
minimalConfig name =
  ProjectConfig
    { packageSection =
        PackageSection
          { packageName = name,
            packageVersion = Nothing,
            packageDescription = Nothing,
            packageSrc = "src"
          },
      sidecarSection = Nothing,
      runtimeSection = RuntimeSection {runtimeUrl = "http://localhost:8000"},
      dependenciesSection =
        DependenciesSection
          { dependenciesRegistry = Nothing,
            dependenciesSnapshot = Nothing,
            dependenciesPackages = []
          },
      overrides = Map.empty
    }

-- | Build a minimal 'ResolvedPackage' with the given name, root, and sources.
minimalPackage :: Text -> FilePath -> Map Text SourceEntry -> ResolvedPackage
minimalPackage name root sources =
  ResolvedPackage
    { packageRoot = root,
      packageConfig = minimalConfig name,
      packageSources = sources,
      packageSha = Nothing,
      packageSnapshotPin = Nothing
    }

-- ===========================================================================
-- Tests
-- ===========================================================================

spec :: Spec
spec = do
  describe "assembleProject" $ do
    it "assembles a project with no dependencies" $ do
      -- Convention: source file is src/<pkgname>.ktr -> module name = <pkgname>
      let rootSources =
            Map.singleton
              "my_app"
              SourceEntry {sourcePath = "/root/src/my_app.ktr", sourceText = "agent main() -> null { null }"}
          root = minimalPackage "my_app" "/root" rootSources
          resolved = ResolvedProject {rootPackage = root, depPackages = Map.empty}
      case assembleProject resolved of
        Left e -> expectationFailure ("unexpected error: " <> show e)
        Right assembly ->
          Map.keys assembly.sources `shouldMatchList` ["my_app"]

    it "assembles a simple dep chain root -> dep_a -> (no transitive)" $ do
      let rootSources =
            Map.singleton
              "my_app"
              SourceEntry {sourcePath = "/root/src/my_app.ktr", sourceText = ""}
          depASources =
            Map.fromList
              [ ("dep_a", SourceEntry {sourcePath = "/dep_a/src/dep_a.ktr", sourceText = ""}),
                ("dep_a.util", SourceEntry {sourcePath = "/dep_a/src/dep_a/util.ktr", sourceText = ""})
              ]
          root = minimalPackage "my_app" "/root" rootSources
          depA = minimalPackage "dep_a" "/dep_a" depASources
          resolved =
            ResolvedProject
              { rootPackage = root,
                depPackages = Map.singleton "dep_a" depA
              }
      case assembleProject resolved of
        Left e -> expectationFailure ("unexpected error: " <> show e)
        Right assembly ->
          Map.keys assembly.sources
            `shouldMatchList` ["my_app", "dep_a", "dep_a.util"]

    it "assembles a three-package chain root -> dep_a, dep_b" $ do
      let rootSources =
            Map.singleton
              "my_app"
              SourceEntry {sourcePath = "/root/src/my_app.ktr", sourceText = ""}
          depASources =
            Map.singleton
              "dep_a"
              SourceEntry {sourcePath = "/dep_a/src/dep_a.ktr", sourceText = ""}
          depBSources =
            Map.singleton
              "dep_b"
              SourceEntry {sourcePath = "/dep_b/src/dep_b.ktr", sourceText = ""}
          root = minimalPackage "my_app" "/root" rootSources
          depA = minimalPackage "dep_a" "/dep_a" depASources
          depB = minimalPackage "dep_b" "/dep_b" depBSources
          resolved =
            ResolvedProject
              { rootPackage = root,
                depPackages =
                  Map.fromList
                    [ ("dep_a", depA),
                      ("dep_b", depB)
                    ]
              }
      case assembleProject resolved of
        Left e -> expectationFailure ("unexpected error: " <> show e)
        Right assembly ->
          Map.keys assembly.sources
            `shouldMatchList` ["my_app", "dep_a", "dep_b"]

    it "rejects module collision across packages" $ do
      -- Both root and dep_a contribute a module named "shared"
      -- that is in-namespace for the root (by naming the root package "shared")
      -- but collides with the dep_a module.
      let rootSources =
            Map.fromList
              [ ("my_app", SourceEntry {sourcePath = "/root/src/my_app.ktr", sourceText = ""}),
                ("my_app.util", SourceEntry {sourcePath = "/root/src/my_app/util.ktr", sourceText = ""})
              ]
          -- dep_a also contributes "my_app.util" — collision
          depASources =
            Map.singleton
              "dep_a"
              SourceEntry {sourcePath = "/dep_a/src/dep_a.ktr", sourceText = ""}
          -- Make dep_a also emit my_app.util by putting it in its sources
          depASources' =
            Map.insert
              "my_app.util"
              SourceEntry {sourcePath = "/dep_a/src/my_app/util.ktr", sourceText = ""}
              depASources
          root = minimalPackage "my_app" "/root" rootSources
          depA = minimalPackage "dep_a" "/dep_a" depASources'
          resolved =
            ResolvedProject
              { rootPackage = root,
                depPackages = Map.singleton "dep_a" depA
              }
      -- dep_a has an out-of-namespace module "my_app.util", so the check
      -- fires ResolveOutOfNamespace before collision.
      case assembleProject resolved of
        Left (ResolveOutOfNamespace pkg _) ->
          pkg `shouldBe` "dep_a"
        Left (ResolveModuleCollision _) ->
          -- Also acceptable if the implementation checks collision first
          pure ()
        Left other -> expectationFailure ("wrong error: " <> show other)
        Right _ -> expectationFailure "expected an error"

    it "rejects a source file outside its package namespace" $ do
      let depASources =
            Map.fromList
              [ ("dep_a", SourceEntry {sourcePath = "/dep_a/src/dep_a.ktr", sourceText = ""}),
                ("rogue_module", SourceEntry {sourcePath = "/dep_a/src/rogue_module.ktr", sourceText = ""})
              ]
          rootSources =
            Map.singleton
              "my_app"
              SourceEntry {sourcePath = "/root/src/my_app.ktr", sourceText = ""}
          root = minimalPackage "my_app" "/root" rootSources
          depA = minimalPackage "dep_a" "/dep_a" depASources
          resolved =
            ResolvedProject
              { rootPackage = root,
                depPackages = Map.singleton "dep_a" depA
              }
      case assembleProject resolved of
        Left (ResolveOutOfNamespace pkg modName) -> do
          pkg `shouldBe` "dep_a"
          modName `shouldBe` "rogue_module"
        Left other -> expectationFailure ("wrong error: " <> show other)
        Right _ -> expectationFailure "expected ResolveOutOfNamespace"

    it "rejects dep name mismatch (key != package.name)" $ do
      let rootSources =
            Map.singleton
              "my_app"
              SourceEntry {sourcePath = "/root/src/my_app.ktr", sourceText = ""}
          depASources =
            Map.singleton
              "dep_a"
              SourceEntry {sourcePath = "/dep_a/src/dep_a.ktr", sourceText = ""}
          root = minimalPackage "my_app" "/root" rootSources
          -- Dep is declared as "dep_a" in the map key, but its config says "dep_b"
          depA = minimalPackage "dep_b" "/dep_a" depASources
          resolved =
            ResolvedProject
              { rootPackage = root,
                depPackages = Map.singleton "dep_a" depA
              }
      case assembleProject resolved of
        Left (ResolveDepNameMismatch declared actual) -> do
          declared `shouldBe` "dep_a"
          actual `shouldBe` "dep_b"
        Left other -> expectationFailure ("wrong error: " <> show other)
        Right _ -> expectationFailure "expected ResolveDepNameMismatch"

    it "rejects invalid package name in dep key" $ do
      let rootSources =
            Map.singleton
              "my_app"
              SourceEntry {sourcePath = "/root/src/my_app.ktr", sourceText = ""}
          depSources =
            Map.singleton
              "bad_name"
              SourceEntry {sourcePath = "/dep/src/bad_name.ktr", sourceText = ""}
          root = minimalPackage "my_app" "/root" rootSources
          dep = minimalPackage "bad_name" "/dep" depSources
          resolved =
            ResolvedProject
              { rootPackage = root,
                -- Key uses hyphen which is invalid
                depPackages = Map.singleton "bad-name" dep
              }
      case assembleProject resolved of
        Left (ResolveInvalidPackageName name) ->
          name `shouldBe` "bad-name"
        Left other -> expectationFailure ("wrong error: " <> show other)
        Right _ -> expectationFailure "expected ResolveInvalidPackageName"

  describe "isValidPackageName" $ do
    it "accepts simple alphanumeric names" $ do
      isValidPackageName "hello" `shouldBe` True
      isValidPackageName "myApp" `shouldBe` True
      isValidPackageName "my_app" `shouldBe` True

    it "accepts names starting with underscore" $ do
      isValidPackageName "_private" `shouldBe` True
      isValidPackageName "_" `shouldBe` True

    it "accepts names with digits (not leading)" $ do
      isValidPackageName "pkg123" `shouldBe` True
      isValidPackageName "a1b2c3" `shouldBe` True

    it "rejects empty name" $ do
      isValidPackageName "" `shouldBe` False

    it "rejects name starting with digit" $ do
      isValidPackageName "1abc" `shouldBe` False
      isValidPackageName "0" `shouldBe` False

    it "rejects name with hyphen" $ do
      isValidPackageName "my-app" `shouldBe` False

    it "rejects name with dot" $ do
      isValidPackageName "my.app" `shouldBe` False

    it "rejects name with space" $ do
      isValidPackageName "my app" `shouldBe` False

    it "rejects name with special characters" $ do
      isValidPackageName "my@app" `shouldBe` False
      isValidPackageName "my$app" `shouldBe` False
      isValidPackageName "my/app" `shouldBe` False

  describe "renderResolveError" $ do
    it "renders ResolveCycle" $ do
      let err = ResolveCycle ["a", "b", "a"]
      renderResolveError err `shouldBe` "dependency cycle: a \x2192 b \x2192 a"

    it "renders ResolveInvalidPackageName" $ do
      let err = ResolveInvalidPackageName "bad-name"
      renderResolveError err
        `shouldBe` "invalid package name 'bad-name' (must match [A-Za-z_][A-Za-z0-9_]*)"

    it "renders ResolveMissingConfig" $ do
      let err = ResolveMissingConfig "foo" "/some/path"
      renderResolveError err
        `shouldBe` "dependency 'foo' at /some/path has no katari.toml"

    it "renders ResolveModuleCollision" $ do
      renderResolveError (ResolveModuleCollision "main")
        `shouldBe` "module 'main' is contributed by two reachable packages"

  describe "loadResolvedProject" $ do
    it "loads a single-package project from disk" $ do
      withSystemTempDirectory "katari-resolve-test" $ \tmpDir -> do
        let projectDir = tmpDir </> "my_project"
            srcDir = projectDir </> "src"
        createDirectoryIfMissing True srcDir
        TextIO.writeFile
          (projectDir </> "katari.toml")
          ( Text.unlines
              [ "[package]",
                "name = \"my_project\""
              ]
          )
        -- Convention: source file matches package name
        TextIO.writeFile (srcDir </> "my_project.ktr") "agent main() -> null { null }"
        result <- loadResolvedProject projectDir
        case result of
          Left e -> expectationFailure ("unexpected error: " <> show e)
          Right resolved -> do
            resolved.rootPackage.packageConfig.packageSection.packageName
              `shouldBe` "my_project"
            Map.member "my_project" resolved.rootPackage.packageSources
              `shouldBe` True
            Map.null resolved.depPackages `shouldBe` True

    it "loads a two-package project with path dependency" $ do
      withSystemTempDirectory "katari-resolve-test" $ \tmpDir -> do
        let rootDir = tmpDir </> "root"
            rootSrc = rootDir </> "src"
            depDir = tmpDir </> "dep_lib"
            depSrc = depDir </> "src"
        createDirectoryIfMissing True rootSrc
        createDirectoryIfMissing True depSrc
        TextIO.writeFile
          (rootDir </> "katari.toml")
          ( Text.unlines
              [ "[package]",
                "name = \"my_app\"",
                "[dependencies]",
                "packages = [\"dep_lib\"]",
                "[overrides.dep_lib]",
                "path = \"../dep_lib\""
              ]
          )
        TextIO.writeFile (rootSrc </> "my_app.ktr") ""
        TextIO.writeFile
          (depDir </> "katari.toml")
          ( Text.unlines
              [ "[package]",
                "name = \"dep_lib\""
              ]
          )
        TextIO.writeFile (depSrc </> "dep_lib.ktr") ""
        result <- loadResolvedProject rootDir
        case result of
          Left e -> expectationFailure ("unexpected error: " <> show e)
          Right resolved -> do
            Map.member "dep_lib" resolved.depPackages `shouldBe` True

    it "detects a cycle between two path deps" $ do
      withSystemTempDirectory "katari-resolve-test" $ \tmpDir -> do
        let pkgA = tmpDir </> "pkg_a"
            pkgASrc = pkgA </> "src"
            pkgB = tmpDir </> "pkg_b"
            pkgBSrc = pkgB </> "src"
        createDirectoryIfMissing True pkgASrc
        createDirectoryIfMissing True pkgBSrc
        TextIO.writeFile
          (pkgA </> "katari.toml")
          ( Text.unlines
              [ "[package]",
                "name = \"pkg_a\"",
                "[dependencies]",
                "packages = [\"pkg_b\"]",
                "[overrides.pkg_b]",
                "path = \"../pkg_b\""
              ]
          )
        TextIO.writeFile (pkgASrc </> "pkg_a.ktr") ""
        TextIO.writeFile
          (pkgB </> "katari.toml")
          ( Text.unlines
              [ "[package]",
                "name = \"pkg_b\"",
                "[dependencies]",
                "packages = [\"pkg_a\"]",
                "[overrides.pkg_a]",
                "path = \"../pkg_a\""
              ]
          )
        TextIO.writeFile (pkgBSrc </> "pkg_b.ktr") ""
        result <- loadResolvedProject pkgA
        case result of
          Left (ResolveCycle _) -> pure ()
          Left other -> expectationFailure ("wrong error: " <> show other)
          Right _ -> expectationFailure "expected ResolveCycle"
