-- | Snapshot files — the @katari-registry@'s pinned (repo, ref, sha256)
-- tuples for each package in a curated set.
--
-- This module covers two concerns:
--
--   1. Parsing a snapshot TOML file (= one of @package-sets\/\<date>.toml@).
--   2. Resolving a URL (from @[snapshot].url@) into the raw bytes
--      of the snapshot file, supporting both @file:\/\/@ and
--      @https:\/\/@ schemes plus a "URL points at the registry root,
--      version is the filename" convention.
--
-- Once the file is in memory, downstream callers (= 'Katari.Project.Resolve')
-- look up each dep name, fetch the tarball at the recorded
-- @(repo, ref)@ via 'Katari.Project.Fetch', and verify the resulting
-- @sha256@ against the snapshot's pin.
module Katari.Project.Snapshot
  ( Snapshot (..),
    SnapshotPackage (..),
    SnapshotError (..),
    parseSnapshot,
    loadSnapshotFromUrl,
  )
where

import Control.Exception (IOException, try)
import qualified Data.ByteString.Lazy as LBS
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TextIO
import Katari.Project.Config
  ( TomlBucket (..),
    TomlTable (..),
    TomlValue (..),
    parseTomlText,
  )
import Network.HTTP.Client
  ( HttpException,
    Request,
    Response,
    httpLbs,
    parseRequest,
    responseBody,
    responseStatus,
  )
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types.Status (statusCode)
import System.Directory (doesFileExist)

data Snapshot = Snapshot
  { snapshotCompilerVersion :: Maybe Text,
    snapshotPackages :: Map Text SnapshotPackage
  }
  deriving (Show, Eq)

data SnapshotPackage = SnapshotPackage
  { spRepo :: Text,
    spRef :: Text,
    spSha :: Maybe Text
  }
  deriving (Show, Eq)

data SnapshotError
  = SnapshotIOError Text Text
  | SnapshotHttpError Text Text
  | SnapshotParseError FilePath Int Text
  | SnapshotValidationError FilePath Text
  | SnapshotUnsupportedUrl Text
  deriving (Show, Eq)

-- ---------------------------------------------------------------------------
-- Parsing
-- ---------------------------------------------------------------------------

parseSnapshot :: FilePath -> Text -> Either SnapshotError Snapshot
parseSnapshot path raw = do
  table <- mapLeft (uncurry (SnapshotParseError path)) (parseTomlText raw)
  let compilerVer = case lookupTopScalar "katari_compiler" table of
        Just (TomlString s) | not (Text.null s) -> Just s
        _ -> Nothing
  pkgs <- parseSnapshotPackages path table
  Right
    Snapshot
      { snapshotCompilerVersion = compilerVer,
        snapshotPackages = pkgs
      }

parseSnapshotPackages ::
  FilePath -> TomlTable -> Either SnapshotError (Map Text SnapshotPackage)
parseSnapshotPackages path (TomlTable buckets) =
  Map.fromList <$> traverse step pkgEntries
  where
    pkgEntries =
      [ (Text.drop (Text.length prefix) sec, body)
        | (sec, body) <- Map.toList buckets,
          prefix `Text.isPrefixOf` sec
      ]
    prefix = "packages."
    step (name, BucketTable t) = do
      sp <- parseOnePackage path name t
      Right (name, sp)
    step (name, _) =
      Left
        ( SnapshotValidationError
            path
            ("[packages." <> name <> "] must be a table")
        )

parseOnePackage ::
  FilePath ->
  Text ->
  Map Text TomlValue ->
  Either SnapshotError SnapshotPackage
parseOnePackage path name t = do
  repo <- requireString path name "repo" t
  ref <- requireString path name "ref" t
  let sha = case Map.lookup "sha256" t of
        Just (TomlString s) | not (Text.null s) -> Just s
        _ -> Nothing
  Right SnapshotPackage {spRepo = repo, spRef = ref, spSha = sha}

requireString :: FilePath -> Text -> Text -> Map Text TomlValue -> Either SnapshotError Text
requireString path name key m = case Map.lookup key m of
  Just (TomlString s) | not (Text.null s) -> Right s
  _ ->
    Left
      ( SnapshotValidationError
          path
          ("[packages." <> name <> "]." <> key <> " missing or empty")
      )

-- ---------------------------------------------------------------------------
-- Fetching
-- ---------------------------------------------------------------------------

-- | Read a snapshot from a URL. Schemes:
--
--   * @file:\/\/\/abs\/path\/to\/file.toml@ — direct read from disk.
--   * @file:\/\/\/abs\/path\/to\/registry@ — registry root; @version@
--     selects @\<registry>\/package-sets\/\<version>.toml@.
--   * @https:\/\/...@ — HTTP GET (TLS via 'Network.HTTP.Client.TLS').
loadSnapshotFromUrl ::
  Text ->
  Maybe Text ->
  IO (Either SnapshotError Snapshot)
loadSnapshotFromUrl url mVersion =
  case Text.stripPrefix "file://" url of
    Just rest -> loadFromFile (Text.unpack rest) mVersion
    Nothing ->
      if "https://" `Text.isPrefixOf` url || "http://" `Text.isPrefixOf` url
        then loadFromHttp url mVersion
        else pure (Left (SnapshotUnsupportedUrl url))

loadFromFile :: FilePath -> Maybe Text -> IO (Either SnapshotError Snapshot)
loadFromFile path mVersion = do
  let target =
        if ".toml" `Text.isSuffixOf` Text.pack path
          then path
          else case mVersion of
            Just v ->
              path
                <> "/package-sets/"
                <> Text.unpack v
                <> ".toml"
            Nothing -> path
  exists <- doesFileExist target
  if not exists
    then pure (Left (SnapshotIOError (Text.pack target) "file does not exist"))
    else do
      readRes <- try (TextIO.readFile target) :: IO (Either IOException Text)
      case readRes of
        Left err ->
          pure
            ( Left
                ( SnapshotIOError
                    (Text.pack target)
                    (Text.pack (show err))
                )
            )
        Right raw -> pure (parseSnapshot target raw)

loadFromHttp :: Text -> Maybe Text -> IO (Either SnapshotError Snapshot)
loadFromHttp url mVersion = do
  let target =
        if ".toml" `Text.isSuffixOf` url
          then url
          else case mVersion of
            Just v -> url <> "/package-sets/" <> v <> ".toml"
            Nothing -> url
  manager <- newTlsManager
  reqRes <- try (parseRequest (Text.unpack target)) :: IO (Either IOException Request)
  case reqRes of
    Left err -> pure (Left (SnapshotHttpError target (Text.pack (show err))))
    Right req -> do
      respRes <-
        try (httpLbs req manager) ::
          IO (Either HttpException (Response LBS.ByteString))
      case respRes of
        Left err -> pure (Left (SnapshotHttpError target (Text.pack (show err))))
        Right resp -> do
          let status = statusCode (responseStatus resp)
              body = LBS.toStrict (responseBody resp)
          if status >= 400
            then
              pure
                ( Left
                    ( SnapshotHttpError
                        target
                        ("HTTP " <> Text.pack (show status))
                    )
                )
            else pure (parseSnapshot (Text.unpack target) (TE.decodeUtf8 body))

-- ---------------------------------------------------------------------------
-- Local helpers
-- ---------------------------------------------------------------------------

mapLeft :: (a -> c) -> Either a b -> Either c b
mapLeft f = either (Left . f) Right

lookupTopScalar :: Text -> TomlTable -> Maybe TomlValue
lookupTopScalar k (TomlTable m) = case Map.lookup k m of
  Just (BucketScalar v) -> Just v
  _ -> Nothing
