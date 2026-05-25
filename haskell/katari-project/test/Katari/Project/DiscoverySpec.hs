module Katari.Project.DiscoverySpec (spec) where

import qualified Data.Map.Strict as Map
import Katari.Project.Config
  ( DependenciesSection (..),
    PackageSection (..),
    ProjectConfig (..),
    RuntimeSection (..),
  )
import Katari.Project.Discovery
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = do
  describe "scanSources" $ do
    it "collects .ktr files keyed by dotted relative path" $ do
      withSystemTempDirectory "katari-project-test" $ \root -> do
        let srcDir = root </> "src"
        createDirectoryIfMissing True srcDir
        createDirectoryIfMissing True (srcDir </> "sub")
        createDirectoryIfMissing True (srcDir </> "deep" </> "nested")
        writeFile (srcDir </> "main.ktr") "agent main() -> integer { 1 }\n"
        writeFile (srcDir </> "sub" </> "helper.ktr") "agent helper() -> integer { 2 }\n"
        writeFile (srcDir </> "deep" </> "nested" </> "x.ktr") "agent x() -> integer { 3 }\n"
        writeFile (srcDir </> "ignored.txt") "not a ktr"
        result <- scanSources root sampleConfig
        Map.keys result `shouldMatchList` ["main", "sub.helper", "deep.nested.x"]

  describe "findProjectRoot" $ do
    it "returns the dir containing katari.toml when given a sub-path" $ do
      withSystemTempDirectory "katari-project-test" $ \root -> do
        writeFile (root </> "katari.toml") "[package]\nname = \"x\"\n"
        let sub = root </> "src" </> "deeper"
        createDirectoryIfMissing True sub
        writeFile (sub </> "main.ktr") "agent main() -> integer { 1 }\n"
        result <- findProjectRoot (sub </> "main.ktr")
        case result of
          Just dir -> dir `shouldNotBe` ""
          Nothing -> expectationFailure "expected to find katari.toml"

    it "returns Nothing outside any project" $ do
      withSystemTempDirectory "katari-project-test" $ \root -> do
        result <- findProjectRoot root
        result `shouldBe` Nothing

sampleConfig :: ProjectConfig
sampleConfig =
  ProjectConfig
    { packageSection =
        PackageSection
          { packageName = "x",
            packageVersion = Nothing,
            packageDescription = Nothing,
            packageSrc = "src"
          },
      sidecarSection = Nothing,
      runtimeSection = RuntimeSection {runtimeUrl = "http://localhost"},
      dependenciesSection =
        DependenciesSection
          { dependenciesRegistry = Nothing,
            dependenciesSnapshot = Nothing,
            dependenciesPackages = []
          },
      overrides = Map.empty
    }
