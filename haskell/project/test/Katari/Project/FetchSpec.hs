module Katari.Project.FetchSpec (spec) where

import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as ByteStringLazy
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.List (List)
import Katari.Project.Cache (ensureCacheDirs, markPackageVerified, packageDir, projectCachePaths)
import Katari.Project.Error (ProjectError (..))
import Katari.Project.Fetch (ExpectedSha (..), GitRef (..), checkPinnedSha, fetchGitTarball)
import Katari.Project.Http (readBodyWithinCap)
import Network.HTTP.Client (defaultManagerSettings, newManager)
import System.Directory (createDirectoryIfMissing)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

pinnedSha :: Text
pinnedSha = Text.replicate 64 "a"

isShaMismatch :: ProjectError -> Bool
isShaMismatch projectError = case projectError of
  ResolveShaMismatch _ -> True
  _ -> False

-- | A 'Network.HTTP.Client.BodyReader' over a fixed chunk list: each read hands back the next chunk and
-- the empty string once they run out, which is the contract @http-client@'s reader has.
chunkReader :: List ByteString.ByteString -> IO (IO ByteString.ByteString)
chunkReader chunks = do
  remaining <- newIORef chunks
  pure $ atomicModifyIORef' remaining $ \case
    [] -> ([], ByteString.empty)
    (chunk : rest) -> (rest, chunk)

spec :: Spec
spec = do
  -- The guard that decides whether downloaded bytes may be written at all. It runs inside
  -- 'fetchGitTarball' before extraction, so these cases describe what a hostile registry gets.
  describe "checkPinnedSha" $ do
    it "accepts a fetched hash that matches its pin" $
      checkPinnedSha "lib" (Just "deadbeef") "deadbeef" `shouldBe` Right ()

    it "rejects a fetched hash that disagrees with its pin (tampered content)" $
      checkPinnedSha "lib" (Just "deadbeef") "0badf00d" `shouldSatisfy` either isShaMismatch (const False)

    it "accepts when there is no pin to verify against (git override, trust on first use)" $
      checkPinnedSha "lib" Nothing "anything" `shouldBe` Right ()

  describe "fetchGitTarball" $
    -- No network is reachable from this test, which is the assertion: a pinned dependency the cache
    -- vouches for must resolve without a request. The complement — that a cache directory the sentinel
    -- does NOT vouch for is not served this way — is "Katari.Project.CacheSpec".
    it "serves a verified cache entry without going to the network" $
      withSystemTempDirectory "katari-fetch" $ \root -> do
        let cache = projectCachePaths root
        ensureCacheDirs cache
        createDirectoryIfMissing True (packageDir cache "lib" pinnedSha)
        markPackageVerified cache "lib" pinnedSha
        manager <- newManager defaultManagerSettings
        result <-
          fetchGitTarball manager cache "lib" GitRef {url = "https://github.com/x/y", rev = "v1"} (PinnedSha pinnedSha)
        result `shouldBe` Right (packageDir cache "lib" pinnedSha, pinnedSha)

  -- The other half of the download guard: a body is bounded as it arrives, so a decompression bomb
  -- cannot be paid for in full before its hash is even computed.
  describe "readBodyWithinCap" $ do
    it "returns a body that stays within the cap" $ do
      reader <- chunkReader ["abc", "de"]
      result <- readBodyWithinCap 8 reader
      result `shouldBe` Right (ByteStringLazy.fromStrict "abcde")

    it "returns an empty body for a response with no content" $ do
      reader <- chunkReader []
      result <- readBodyWithinCap 8 reader
      result `shouldBe` Right ByteStringLazy.empty

    it "refuses a body that exceeds the cap" $ do
      reader <- chunkReader ["abcd", "efgh", "ijkl"]
      result <- readBodyWithinCap 8 reader
      result `shouldSatisfy` either (const True) (const False)

    -- Refusing has to happen mid-stream, not after: a cap that only reports at the end has already
    -- bought the whole download it was meant to prevent.
    it "stops reading as soon as the cap is passed" $ do
      reader <- chunkReader ["abcd", "efgh", "ijkl"]
      _ <- readBodyWithinCap 4 reader
      -- Two chunks were consumed (the second is the one that crossed the cap); the third must remain.
      reader `shouldReturn` "ijkl"
