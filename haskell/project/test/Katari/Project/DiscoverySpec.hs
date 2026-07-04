module Katari.Project.DiscoverySpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text.IO qualified as TextIO
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Project.Discovery
  ( SourceEntry (..),
    SourceOverlay (..),
    emptyOverlay,
    findProjectRoot,
    scanSourcesFromDir,
  )
import System.Directory (canonicalizePath, createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

-- | Lay out a small package tree under @root@: @src/main.ktr@ and @src/foo/bar.ktr@.
writeSampleTree :: FilePath -> IO ()
writeSampleTree root = do
  createDirectoryIfMissing True (root </> "src" </> "foo")
  TextIO.writeFile (root </> "src" </> "main.ktr") "main source"
  TextIO.writeFile (root </> "src" </> "foo" </> "bar.ktr") "bar source"
  -- A non-.ktr file must be ignored by the scan.
  TextIO.writeFile (root </> "src" </> "README.md") "ignore me"

spec :: Spec
spec = do
  describe "scanSourcesFromDir" $ do
    it "derives dotted module names from the directory layout" $
      withSystemTempDirectory "katari-discovery" $ \root -> do
        writeSampleTree root
        result <- scanSourcesFromDir emptyOverlay (root </> "src")
        case result of
          Left projectError -> expectationFailure ("expected success, got " <> show projectError)
          Right sources ->
            Map.keysSet sources `shouldBe` Map.keysSet (Map.fromList [(ModuleName "main", ()), (ModuleName "foo.bar", ())])

    it "lets an overlay shadow on-disk bytes" $
      withSystemTempDirectory "katari-discovery" $ \root -> do
        writeSampleTree root
        canonicalMain <- canonicalizePath (root </> "src" </> "main.ktr")
        let overlay = SourceOverlay {files = Map.singleton canonicalMain "edited in editor"}
        result <- scanSourcesFromDir overlay (root </> "src")
        case result of
          Left projectError -> expectationFailure ("expected success, got " <> show projectError)
          Right sources ->
            fmap (.text) (Map.lookup (ModuleName "main") sources) `shouldBe` Just "edited in editor"

    it "includes an overlay-only file that was never saved" $
      withSystemTempDirectory "katari-discovery" $ \root -> do
        writeSampleTree root
        canonicalNew <- canonicalizePath (root </> "src" </> "draft.ktr")
        let overlay = SourceOverlay {files = Map.singleton canonicalNew "unsaved draft"}
        result <- scanSourcesFromDir overlay (root </> "src")
        case result of
          Left projectError -> expectationFailure ("expected success, got " <> show projectError)
          Right sources ->
            fmap (.text) (Map.lookup (ModuleName "draft") sources) `shouldBe` Just "unsaved draft"

  describe "findProjectRoot" $
    it "walks upward to the directory holding katari.toml" $
      withSystemTempDirectory "katari-discovery" $ \root -> do
        createDirectoryIfMissing True (root </> "src" </> "nested")
        TextIO.writeFile (root </> "katari.toml") "[package]\nname = \"x\""
        canonicalRoot <- canonicalizePath root
        found <- findProjectRoot (root </> "src" </> "nested")
        found `shouldBe` Just canonicalRoot
