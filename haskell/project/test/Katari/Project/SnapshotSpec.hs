module Katari.Project.SnapshotSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Katari.Project.Lockfile (GitSource (..))
import Katari.Project.Snapshot (Snapshot (..), loadSnapshotFromUrl, parseSnapshot)
import Network.HTTP.Client (defaultManagerSettings, newManager)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

-- | A well-formed (64 hex char) content hash; the parser now rejects malformed ones.
sampleSha :: Text
sampleSha = Text.replicate 64 "a"

-- | A snapshot in the registry's wire format (katari-registry README): top-level @katari_compiler@,
-- per-package @repo@ / @ref@ / @sha256@, plus keys resolution does not need (@version@).
sampleSnapshot :: Text
sampleSnapshot =
  Text.unlines
    [ "katari_compiler = \"0.1.0\"",
      "",
      "[packages.list_utils]",
      "version = \"1.0.0\"",
      "repo = \"https://github.com/katari-lang/list_utils\"",
      "ref = \"v0.2.1\"",
      "sha256 = \"" <> sampleSha <> "\""
    ]

spec :: Spec
spec = do
  describe "parseSnapshot" $ do
    it "parses the registry wire format into the shared GitSource vocabulary" $
      case parseSnapshot "snapshot.toml" sampleSnapshot of
        Left projectError -> expectationFailure ("expected success, got " <> show projectError)
        Right snapshot -> do
          snapshot.compilerVersion `shouldBe` Just "0.1.0"
          Map.lookup "list_utils" snapshot.packages
            `shouldBe` Just
              GitSource
                { url = "https://github.com/katari-lang/list_utils",
                  rev = "v0.2.1",
                  sha = sampleSha
                }

    it "rejects a package whose sha256 is not 64 hex characters" $ do
      let malformed =
            Text.unlines
              [ "[packages.list_utils]",
                "repo = \"https://github.com/katari-lang/list_utils\"",
                "ref = \"v0.2.1\"",
                "sha256 = \"abc123\""
              ]
      parseSnapshot "snapshot.toml" malformed `shouldSatisfy` either (const True) (const False)

    it "treats a missing katari_compiler field and empty package set as valid" $
      case parseSnapshot "snapshot.toml" "" of
        Left projectError -> expectationFailure ("expected success, got " <> show projectError)
        Right snapshot -> do
          snapshot.compilerVersion `shouldBe` Nothing
          snapshot.packages `shouldBe` Map.empty

  describe "loadSnapshotFromUrl" $ do
    it "loads a named cut from package-sets/snapshots/<name>.toml under a file:// registry root" $
      withSystemTempDirectory "katari-snapshot" $ \root -> do
        createDirectoryIfMissing True (root </> "package-sets" </> "snapshots")
        TextIO.writeFile
          (root </> "package-sets" </> "snapshots" </> "snapshot-2026-07-01-abc123.toml")
          sampleSnapshot
        -- file:// never touches the network, so the manager is created but unused.
        manager <- newManager defaultManagerSettings
        result <-
          loadSnapshotFromUrl manager (Text.pack ("file://" <> root)) (Just "snapshot-2026-07-01-abc123")
        case result of
          Left projectError -> expectationFailure ("expected success, got " <> show projectError)
          Right snapshot -> Map.member "list_utils" snapshot.packages `shouldBe` True

    it "loads the mutable staging set from package-sets/staging.toml" $
      withSystemTempDirectory "katari-snapshot" $ \root -> do
        createDirectoryIfMissing True (root </> "package-sets")
        TextIO.writeFile (root </> "package-sets" </> "staging.toml") sampleSnapshot
        manager <- newManager defaultManagerSettings
        result <- loadSnapshotFromUrl manager (Text.pack ("file://" <> root)) (Just "staging")
        case result of
          Left projectError -> expectationFailure ("expected success, got " <> show projectError)
          Right snapshot -> Map.member "list_utils" snapshot.packages `shouldBe` True
