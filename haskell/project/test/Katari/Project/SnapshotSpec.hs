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

sampleSnapshot :: Text
sampleSnapshot =
  Text.unlines
    [ "compiler = \"0.1.0\"",
      "",
      "[packages.list_utils]",
      "url = \"https://github.com/katari-lang/list_utils\"",
      "rev = \"v0.2.1\"",
      "sha256 = \"" <> sampleSha <> "\""
    ]

spec :: Spec
spec = do
  describe "parseSnapshot" $ do
    it "parses packages and renames sha256 to the shared sha vocabulary" $
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
                "url = \"https://github.com/katari-lang/list_utils\"",
                "rev = \"v0.2.1\"",
                "sha256 = \"abc123\""
              ]
      parseSnapshot "snapshot.toml" malformed `shouldSatisfy` either (const True) (const False)

    it "treats a missing compiler field and empty package set as valid" $
      case parseSnapshot "snapshot.toml" "" of
        Left projectError -> expectationFailure ("expected success, got " <> show projectError)
        Right snapshot -> do
          snapshot.compilerVersion `shouldBe` Nothing
          snapshot.packages `shouldBe` Map.empty

  describe "loadSnapshotFromUrl" $
    it "loads from a file:// registry root via the package-sets/<version>.toml convention" $
      withSystemTempDirectory "katari-snapshot" $ \root -> do
        createDirectoryIfMissing True (root </> "package-sets")
        TextIO.writeFile (root </> "package-sets" </> "v0.1.0.toml") sampleSnapshot
        -- file:// never touches the network, so the manager is created but unused.
        manager <- newManager defaultManagerSettings
        result <- loadSnapshotFromUrl manager (Text.pack ("file://" <> root)) (Just "v0.1.0")
        case result of
          Left projectError -> expectationFailure ("expected success, got " <> show projectError)
          Right snapshot -> Map.member "list_utils" snapshot.packages `shouldBe` True
