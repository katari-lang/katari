module Katari.Project.SnapshotSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Katari.Project.Error (ProjectError (..))
import Katari.Project.Lockfile (GitSource (..))
import Katari.Project.Snapshot
  ( Snapshot (..),
    SnapshotIndex (..),
    SnapshotIndexEntry (..),
    loadSnapshotFromUrl,
    loadSnapshotIndexFromUrl,
    newestSnapshot,
    parseSnapshot,
    parseSnapshotIndex,
  )
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

isIndexValidationError :: ProjectError -> Bool
isIndexValidationError projectError = case projectError of
  IndexValidationError _ -> True
  _ -> False

-- | A registry index written in an order no client may rely on, with two cuts from the same day
-- whose names sort the opposite way round from when they were made.
sampleIndex :: Text
sampleIndex =
  Text.unlines
    [ "version = 1",
      "",
      "[[snapshots]]",
      "name = \"snapshot-2026-07-26-bcc95cb3\"",
      "cut_time = \"2026-07-26T07:38:02Z\"",
      "katari_compiler = \"0.1.0\"",
      "",
      "[[snapshots]]",
      "name = \"snapshot-2026-07-26-a7cc1e51\"",
      "cut_time = \"2026-07-26T18:46:13Z\"",
      "katari_compiler = \"0.1.0\"",
      "",
      "[[snapshots]]",
      "name = \"snapshot-2026-07-25-df58f3a7\"",
      "cut_time = \"2026-07-25T01:52:39Z\"",
      "katari_compiler = \"0.1.0\""
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

  describe "parseSnapshotIndex" $ do
    it "parses the registry's index into ordered entries" $
      case parseSnapshotIndex "index.toml" sampleIndex of
        Left projectError -> expectationFailure ("expected success, got " <> show projectError)
        Right index -> do
          index.formatVersion `shouldBe` 1
          [entry.name | entry <- index.snapshots]
            `shouldBe` [ "snapshot-2026-07-26-bcc95cb3",
                         "snapshot-2026-07-26-a7cc1e51",
                         "snapshot-2026-07-25-df58f3a7"
                       ]

    it "rejects an unsupported index format version" $
      parseSnapshotIndex "index.toml" "version = 999\n"
        `shouldSatisfy` either isIndexValidationError (const False)

    -- Ordering compares these strings directly, which is only sound while every one of them is the
    -- same fixed-width UTC shape. An entry that strays is rejected rather than silently misordering.
    it "rejects a cut_time that is not the index's fixed UTC shape" $ do
      let loose =
            Text.unlines
              [ "version = 1",
                "[[snapshots]]",
                "name = \"snapshot-2026-07-26-a7cc1e51\"",
                "cut_time = \"2026-07-26T18:46:13.512Z\"",
                "katari_compiler = \"0.1.0\""
              ]
      parseSnapshotIndex "index.toml" loose `shouldSatisfy` either isIndexValidationError (const False)

    it "rejects a snapshot name that would escape the registry root as a path segment" $ do
      let traversal =
            Text.unlines
              [ "version = 1",
                "[[snapshots]]",
                "name = \"../../etc/passwd\"",
                "cut_time = \"2026-07-26T18:46:13Z\"",
                "katari_compiler = \"0.1.0\""
              ]
      parseSnapshotIndex "index.toml" traversal `shouldSatisfy` either isIndexValidationError (const False)

  describe "newestSnapshot" $ do
    -- The whole reason the index carries a timestamp. A snapshot's name ends in a hash of the staging
    -- file, so name order is content order: 'a7cc1e51' sorts before 'bcc95cb3' while being the newer
    -- cut, and sorting names would quietly hand back the older set.
    it "picks the latest cut even when its name sorts earliest" $
      case parseSnapshotIndex "index.toml" sampleIndex of
        Left projectError -> expectationFailure ("expected success, got " <> show projectError)
        Right index -> fmap (.name) (newestSnapshot index) `shouldBe` Just "snapshot-2026-07-26-a7cc1e51"

    it "has no answer for an empty index" $
      case parseSnapshotIndex "index.toml" "version = 1\n" of
        Left projectError -> expectationFailure ("expected success, got " <> show projectError)
        Right index -> fmap (.name) (newestSnapshot index) `shouldBe` Nothing

  describe "loadSnapshotIndexFromUrl" $ do
    it "reads package-sets/index.toml under a file:// registry root" $
      withSystemTempDirectory "katari-index" $ \root -> do
        createDirectoryIfMissing True (root </> "package-sets")
        TextIO.writeFile (root </> "package-sets" </> "index.toml") sampleIndex
        manager <- newManager defaultManagerSettings
        result <- loadSnapshotIndexFromUrl manager (Text.pack ("file://" <> root))
        case result of
          Left projectError -> expectationFailure ("expected success, got " <> show projectError)
          Right index -> fmap (.name) (newestSnapshot index) `shouldBe` Just "snapshot-2026-07-26-a7cc1e51"

    it "refuses a registry URL that names a single snapshot file (it has no index beside it)" $ do
      manager <- newManager defaultManagerSettings
      result <- loadSnapshotIndexFromUrl manager "file:///tmp/some-snapshot.toml"
      result `shouldSatisfy` either isIndexValidationError (const False)
